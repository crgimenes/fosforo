import Darwin
import FosforoCore
import Foundation
import Testing

@testable import FosforoMosh
@testable import FosforoSSH

/// A throwaway sshd on 127.0.0.1: unprivileged, so it can only log in the
/// user running the tests, with keys made for the occasion.
final class Server {
  let dir: URL
  let port: Int
  let process = Process()
  let userKey: String
  let knownHosts: KnownHosts

  init(extra: String = "") throws {
    dir = FileManager.default.temporaryDirectory.appendingPathComponent("sshd-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for name in ["host", "user"] {
      try Server.run(
        "/usr/bin/ssh-keygen",
        ["-q", "-t", "ed25519", "-N", "", "-f", dir.appendingPathComponent(name).path])
    }
    try FileManager.default.copyItem(
      at: dir.appendingPathComponent("user.pub"), to: dir.appendingPathComponent("authorized_keys"))
    userKey = try String(contentsOf: dir.appendingPathComponent("user"), encoding: .utf8)
    knownHosts = KnownHosts(path: dir.appendingPathComponent("known_hosts").path)
    port = Int.random(in: 30000...49151)  // below the ephemeral range
    // PerSourcePenalties: the tests connect from 127.0.0.1 over and over, many
    // closing before auth, which sshd (9.8 on) punishes by refusing the source
    let config = """
      ListenAddress 127.0.0.1
      Port \(port)
      HostKey \(dir.path)/host
      AuthorizedKeysFile \(dir.path)/authorized_keys
      PidFile none
      UsePAM no
      StrictModes no
      PasswordAuthentication no
      KbdInteractiveAuthentication no
      PerSourcePenalties no
      \(extra)
      """
    try config.write(
      to: dir.appendingPathComponent("sshd_config"), atomically: true, encoding: .utf8)
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/sshd")
    process.arguments = ["-D", "-e", "-f", dir.appendingPathComponent("sshd_config").path]
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    try process.run()
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
      if (try? dial(host: "127.0.0.1", port: port, timeout: 1)).map({ close($0) }) != nil {
        return
      }
      Thread.sleep(forTimeInterval: 0.05)
    }
    throw SSHError.io("sshd did not start")
  }

  deinit {
    process.terminate()
    process.waitUntilExit()
    try? FileManager.default.removeItem(at: dir)
  }

  static func run(_ path: String, _ args: [String]) throws {
    _ = try output(path, args)
  }

  /// What the command printed, for the system's ssh-keygen as an oracle.
  static func output(_ path: String, _ args: [String]) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
  }

  func config(command: String? = nil) throws -> SSHConfig {
    var c = SSHConfig(host: "127.0.0.1", user: NSUserName(), knownHosts: knownHosts)
    c.port = port
    c.keys = [try PrivateKey.openSSH(userKey)]
    c.command = command
    return c
  }
}

private let moshServer = "/opt/homebrew/bin/mosh-server"

private func screenText(_ s: Session) -> String {
  var screen = Screen()
  s.snapshot(into: &screen)
  var text = ""
  for (i, c) in screen.cells.enumerated() {
    if i > 0 && i % screen.cols == 0 {
      text += "\n"
    }
    text.unicodeScalars.append(Unicode.Scalar(c.cp == 0 ? 32 : c.cp) ?? " ")
  }
  return text
}

private func waitScreen(_ s: Session, _ what: String, seconds: Double = 20) -> Bool {
  waitScreen(s, seconds: seconds) { $0.contains(what) }
}

private func waitScreen(_ s: Session, seconds: Double = 20, _ ok: (String) -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if ok(screenText(s)) {
      return true
    }
    Thread.sleep(forTimeInterval: 0.02)
  }
  print(screenText(s))
  return false
}

/// What rocchetto does on the device: a line typed at its prompt goes to the
/// launcher as one command, and the keys after it are the launcher's until
/// done. The screen is cleared for each command, so a wait never matches
/// the one before.
private final class Typed: Transport, @unchecked Sendable {
  private let lock = NSLock()
  private let launcher: Launcher
  private var line: [UInt8] = []
  private var running = false
  private var output: (@Sendable ([UInt8]) -> Void)?

  init(_ launcher: Launcher) {
    self.launcher = launcher
  }

  func start(
    output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void
  ) {
    lock.lock()
    self.output = output
    lock.unlock()
    output(Array("test> ".utf8))
  }

  func send(_ bytes: [UInt8]) {
    lock.lock()
    if running {
      lock.unlock()
      launcher.send(bytes)
      return
    }
    guard let cr = bytes.firstIndex(of: 0x0D) else {
      line += bytes
      lock.unlock()
      return
    }
    line += bytes[..<cr]
    // as rocchetto does: a quoted word loses its quotes ('' is an empty word)
    let words = String(decoding: line, as: UTF8.self).split(separator: " ").map { w -> String in
      let t = String(w)
      if t.count >= 2, let q = t.first, q == "'" || q == "\"", t.last == q {
        return String(t.dropFirst().dropLast())
      }
      return t
    }
    line.removeAll()
    running = true
    let out = output
    lock.unlock()
    out?(Array("\u{1b}[H\u{1b}[2J".utf8))
    launcher.command(
      words, output: { out?($0) },
      done: { [weak self] status in
        guard let self else { return }
        self.lock.lock()
        self.running = false
        self.lock.unlock()
        out?(Array("[\(status)]\r\ntest> ".utf8))
      })
    let rest = Array(bytes[(cr + 1)...])
    if !rest.isEmpty {
      launcher.send(rest)
    }
  }

  func resize(rows: Int, cols: Int) { launcher.resize(rows: rows, cols: cols) }
  func hangup() { launcher.hangup() }
  func overlay(_ screen: inout Screen) { launcher.overlay(&screen) }
  var overlayGeneration: UInt64 { launcher.overlayGeneration }
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: moshServer)))
func moshSessionOverRealServer() throws {
  let server = try Server()
  let ep = try MoshTransport.bootstrap(ssh: try server.config(), server: moshServer)
  defer {
    if let pid = ep.serverPID {
      kill(pid_t(pid), SIGTERM)
    }
  }
  #expect(ep.host == "127.0.0.1")
  let mosh = try MoshTransport(endpoint: ep, rows: 24, cols: 80)
  let s = try Session(transport: mosh, rows: 24, cols: 80, history: 0)
  s.start()
  s.send("echo mosh-$((6*7))\r")
  #expect(waitScreen(s, "mosh-42"))
  s.resize(rows: 30, cols: 100)
  s.send("stty size\r")
  #expect(waitScreen(s, "30 100"))
  s.send("printf '\\033[31mvermelho\\033[0m\\n'\r")
  #expect(waitScreen(s, "vermelho"))
  s.send("exit\r")
  let deadline = Date().addingTimeInterval(20)
  while !s.hasExited && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
  }
  #expect(s.hasExited)
}

final class Every: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  let k: Int
  init(_ k: Int) { self.k = k }
  func next() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    n += 1
    return n % k == 0
  }
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: moshServer)))
func moshSurvivesPacketLoss() throws {
  let server = try Server()
  let ep = try MoshTransport.bootstrap(ssh: try server.config(), server: moshServer)
  defer {
    if let pid = ep.serverPID {
      kill(pid_t(pid), SIGTERM)
    }
  }
  let mosh = try MoshTransport(endpoint: ep, rows: 24, cols: 80)
  let every = Every(3)
  mosh.drop = { every.next() }
  let s = try Session(transport: mosh, rows: 24, cols: 80, history: 0)
  s.start()
  s.send("seq 1 3000; echo fim-$((40+2))\r")
  #expect(waitScreen(s, "fim-42", seconds: 40))
  #expect(screenText(s).contains("2999"))
  s.send("exit\r")
  let deadline = Date().addingTimeInterval(20)
  while !s.hasExited && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
  }
  #expect(s.hasExited)
}

@Test func launcherConnectsAndComesBack() throws {
  let server = try Server()
  let launcher = testLauncher(server.dir.appendingPathComponent("device"))
  let key = try launcher.deviceKey()
  let authorized = server.dir.appendingPathComponent("authorized_keys")
  let lines = try String(contentsOf: authorized, encoding: .utf8) + key.authorizedKey + "\n"
  try lines.write(to: authorized, atomically: true, encoding: .utf8)

  let s = try Session(transport: Typed(launcher), rows: 24, cols: 100, history: 100)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "accept and remember it?"))
  s.send("yes\r")
  s.send("echo remote-$((6*7)); exit\r")
  #expect(waitScreen(s, "remote-42"))
  #expect(waitScreen(s, "[connection closed]"))
  s.send("ssh\r")
  #expect(waitScreen(s, "usage: ssh"))
  let known = try String(
    contentsOf: server.dir.appendingPathComponent("device/.ssh/known_hosts"), encoding: .utf8)
  #expect(known.contains("[127.0.0.1]:\(server.port)"))
}

@Test func launcherExplainsFailures() throws {
  let server = try Server()
  let launcher = testLauncher(server.dir.appendingPathComponent("device"))
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 100, history: 100)
  s.start()
  s.send("ssh nobody\r")
  #expect(waitScreen(s, "no user"))
  s.send("ssh -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("no\r")
  #expect(waitScreen(s, "not connecting"))
  s.send("ssh -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  #expect(waitScreen(s, "permission denied"))
  s.send("frobnicate\r")
  #expect(waitScreen(s, "unknown command"))
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: moshServer)))
func launcherSpeaksMosh() throws {
  let server = try Server()
  let launcher = testLauncher(server.dir.appendingPathComponent("device"))
  let key = try launcher.deviceKey()
  let authorized = server.dir.appendingPathComponent("authorized_keys")
  let lines = try String(contentsOf: authorized, encoding: .utf8) + key.authorizedKey + "\n"
  try lines.write(to: authorized, atomically: true, encoding: .utf8)
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 100, history: 100)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("mosh -p \(server.port) --server \(moshServer) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  #expect(waitScreen(s, "(mosh)"))
  // a line typed while the remote shell still starts (its rc files, on a busy
  // machine) may be flushed, and what it prints first need not be its prompt:
  // the echo, harmless twice, is typed again until it has run
  var ran = false
  for _ in 0..<4 where !ran {
    s.send("echo via-mosh-$((6*7))\r")
    ran = waitScreen(s, "via-mosh-42", seconds: 5)
  }
  #expect(ran)
  s.send("exit\r")
  #expect(waitScreen(s, "[connection closed]"))
}

@Test func launcherUsesSSHConfigAliases() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  let launcher = testLauncher(dir)
  let key = try launcher.deviceKey()
  let authorized = server.dir.appendingPathComponent("authorized_keys")
  try (try String(contentsOf: authorized, encoding: .utf8) + key.authorizedKey + "\n").write(
    to: authorized, atomically: true, encoding: .utf8)
  try "Host lab\n  HostName 127.0.0.1\n  User \(NSUserName())\n  Port \(server.port)\n".write(
    to: try sshDir(dir).appendingPathComponent("config"), atomically: true, encoding: .utf8)
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 100, history: 100)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh nobody-known\r")
  #expect(waitScreen(s, "no user"))
  s.send("ssh lab\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  s.send("echo alias-$((6*7)); exit\r")
  #expect(waitScreen(s, "alias-42"))
  #expect(waitScreen(s, "[connection closed]"))
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: moshServer)))
func moshFollowsANewSourcePort() throws {
  let server = try Server()
  let ep = try MoshTransport.bootstrap(ssh: try server.config(), server: moshServer)
  defer {
    if let pid = ep.serverPID {
      kill(pid_t(pid), SIGTERM)
    }
  }
  let mosh = try MoshTransport(endpoint: ep, rows: 24, cols: 80)
  let s = try Session(transport: mosh, rows: 24, cols: 80, history: 0)
  s.start()
  s.send("echo before-$((1+1))\r")
  #expect(waitScreen(s, "before-2"))
  mosh.hop()
  Thread.sleep(forTimeInterval: 0.2)
  s.send("echo after-$((2+2))\r")
  #expect(waitScreen(s, "after-4"))
  s.send("exit\r")
  let deadline = Date().addingTimeInterval(20)
  while !s.hasExited && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
  }
  #expect(s.hasExited)
}

/// Tests never touch the ~/.ssh of whoever runs them.
/// A host key that changed is refused with where the old one is; ssh-keygen
/// -R forgets it (asked first, the old file kept) and the next connection
/// asks again, as for a new host.
@Test func changedHostKeyIsRefusedAndForgotten() throws {
  let server = try Server()
  let launcher = testLauncher(server.dir.appendingPathComponent("device"))
  try authorize(server, [try launcher.deviceKey()])
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  let target = "\(NSUserName())@127.0.0.1"
  s.send("ssh -p \(server.port) \(target)\r")
  #expect(waitScreen(s, "accept and remember it?"))
  s.send("yes\r")
  s.send("exit\r")
  #expect(waitScreen(s, "[connection closed]"))
  let known = server.dir.appendingPathComponent("device/.ssh/known_hosts")
  var line = try String(contentsOf: known, encoding: .utf8)
  let i = line.index(line.endIndex, offsetBy: -10)
  line.replaceSubrange(i...i, with: line[i] == "A" ? "B" : "A")  // another key, same type
  try line.write(to: known, atomically: true, encoding: .utf8)
  s.send("ssh -p \(server.port) \(target)\r")
  #expect(waitScreen(s, "presented a different host key"))
  #expect(waitScreen(s, "known_hosts line 1"))
  s.send("ssh-keygen -R [127.0.0.1]:\(server.port)\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  #expect(waitScreen(s, "removed 1 line"))
  #expect(FileManager.default.fileExists(atPath: known.path + ".old"))
  s.send("ssh -p \(server.port) \(target)\r")
  #expect(waitScreen(s, "accept and remember it?"))
  s.send("no\r")
}

/// A connection that dies (the server's session killed, no exit status)
/// says why and offers itself again; Enter dials the same host.
@Test func lostConnectionOffersToReconnect() throws {
  let server = try Server()
  let launcher = testLauncher(server.dir.appendingPathComponent("device"))
  try authorize(server, [try launcher.deviceKey()])
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "accept and remember it?"))
  s.send("yes\r")
  s.send("echo up-$((6*7)); kill -9 $PPID\r")
  #expect(waitScreen(s, "[connection lost:"))
  #expect(waitScreen(s, "reconnect? (yes/no, Enter: yes)"))
  s.send("\r")
  s.send("echo again-$((6*7)); exit\r")
  #expect(waitScreen(s, "again-42"))
  #expect(waitScreen(s, "[connection closed]"))
}

/// ServerAliveInterval from ~/.ssh/config: a server that stops answering
/// (its session process stopped, the TCP still open) is given up on after
/// ServerAliveCountMax questions, and the reconnect offer says why.
/// A port that accepts and never says a word: a connect that would hang.
final class MutePort {
  let fd: Int32
  let port: Int
  init() throws {
    let sock = socket(AF_INET, SOCK_STREAM, 0)
    fd = sock
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bound == 0, listen(sock, 4) == 0 else { throw SSHError.io("mute port") }
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) }
    }
    port = Int(UInt16(bigEndian: addr.sin_port))
    let server = sock
    Thread {
      var clients: [Int32] = []
      while true {
        let c = accept(server, nil, nil)
        if c < 0 {
          for k in clients {
            close(k)
          }
          return
        }
        clients.append(c)  // kept open and mute
      }
    }.start()
  }
  deinit { close(fd) }
}

/// Ctrl+C while connecting drops the attempt at once: the shell gets 130
/// and nothing connects later; closing the window does the same, quietly.
@Test func interruptedConnectComesBackToTheShell() throws {
  let mute = try MutePort()
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let launcher = testLauncher(dir)
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 100, history: 100)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh -p \(mute.port) x@127.0.0.1\r")
  #expect(waitScreen(s, "connecting to 127.0.0.1"))
  Thread.sleep(forTimeInterval: 0.3)
  let began = Date()
  s.send([0x03])
  #expect(waitScreen(s, "^C", seconds: 3) && waitScreen(s, "[130]", seconds: 3))
  #expect(Date().timeIntervalSince(began) < 2)
  s.send("ssh -p \(mute.port) x@127.0.0.1\r")
  #expect(waitScreen(s, "connecting to 127.0.0.1"))
  launcher.hangup()  // the window closed: the connect in progress goes with it
  Thread.sleep(forTimeInterval: 0.5)
  #expect(launcher.label == nil)
}

/// A connect that Ctrl+C dropped may still be returning while the next
/// command runs: its late failure touches nothing of the new one, which
/// keeps its own cancel and ends once, with its own status.
@Test func aLateReturnOfACancelledConnectTouchesNothing() throws {
  let mute = try MutePort()
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let launcher = testLauncher(dir)
  let gate = DispatchSemaphore(value: 0)
  launcher.holdBeforeFailing = { gate.wait() }  // the first attempt's thread stops here
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 100, history: 100)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh -p \(mute.port) a@127.0.0.1\r")
  #expect(waitScreen(s, "connecting to 127.0.0.1"))
  Thread.sleep(forTimeInterval: 0.3)
  s.send([0x03])
  #expect(waitScreen(s, "[130]"))
  s.send("ssh -p \(mute.port) b@127.0.0.1\r")  // the next command, while the first returns
  #expect(waitScreen(s, "connecting to 127.0.0.1"))  // the test shell clears per command
  launcher.holdBeforeFailing = nil
  gate.signal()
  Thread.sleep(forTimeInterval: 0.5)
  #expect(!waitScreen(s, seconds: 0.5) { $0.contains("Broken pipe") || $0.contains("[1]") })
  s.send([0x03])  // the new command still has its own cancel
  #expect(waitScreen(s, "[130]", seconds: 3))
}

/// A datagram heard once counts once: delivered again (a replay, a
/// straggler) it does not pass as a sign of life, nor does an older one.
@Test func replayedDatagramsCountForNothing() throws {
  let keyBytes = [UInt8](repeating: 0x42, count: 16)
  let key = String(Data(keyBytes).base64EncodedString().prefix(22))
  let t = try MoshTransport(
    endpoint: MoshTransport.Endpoint(host: "127.0.0.1", port: 9, key: key, serverPID: nil),
    rows: 24, cols: 80)
  guard let ocb = OCB(key: keyBytes) else {
    Issue.record("no cipher")
    return
  }
  func datagram(seq: UInt8) -> [UInt8] {
    let nonce8: [UInt8] = [0x80, 0, 0, 0, 0, 0, 0, seq]  // from the server
    let plain = [UInt8](repeating: 0, count: 14)  // timestamps and a fragment head, nothing more
    return nonce8 + ocb.seal(plain, nonce: [0, 0, 0, 0] + nonce8)
  }
  let before = t.lastHeard
  Thread.sleep(forTimeInterval: 0.02)
  t.receive(datagram(seq: 5))
  let heard = t.lastHeard
  #expect(heard > before)
  Thread.sleep(forTimeInterval: 0.02)
  t.receive(datagram(seq: 5))  // the same one again
  #expect(t.lastHeard == heard)
  t.receive(datagram(seq: 3))  // an older one
  #expect(t.lastHeard == heard)
  Thread.sleep(forTimeInterval: 0.02)
  t.receive(datagram(seq: 6))
  #expect(t.lastHeard > heard)
}

@Test func silentServerIsGivenUpOn() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  try FileManager.default.createDirectory(
    at: dir.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
  try """
  Host lab
    HostName 127.0.0.1
    User \(NSUserName())
    Port \(server.port)
    ServerAliveInterval 1
    ServerAliveCountMax 2

  """.write(to: dir.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)
  let launcher = testLauncher(dir)
  try authorize(server, [try launcher.deviceKey()])
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh lab\r")
  #expect(waitScreen(s, "accept and remember it?"))
  s.send("yes\r")
  Thread.sleep(forTimeInterval: 3.5)  // quiet but alive: the server answers, nothing drops
  s.send("echo alive-$((6*7))\r")
  #expect(waitScreen(s, "alive-42"))
  // the session freezes for 6 s, then resumes to find the connection gone
  s.send("echo frozen-$((6*7)); (sleep 6; kill -CONT $PPID) & kill -STOP $PPID\r")
  #expect(waitScreen(s, "frozen-42"))
  #expect(waitScreen(s, "no answer from the server in 2 s", seconds: 10))
  #expect(waitScreen(s, "reconnect? (yes/no, Enter: yes)"))
  s.send("no\r")
}

/// No user@ and no User in ~/.ssh/config: the shell's user, as the local
/// login is on a computer.
@Test func sshDefaultsToTheShellsUser() throws {
  let server = try Server()
  let launcher = testLauncher(server.dir.appendingPathComponent("device"))
  try authorize(server, [try launcher.deviceKey()])
  launcher.localUser = NSUserName()
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh -p \(server.port) 127.0.0.1\r")
  #expect(waitScreen(s, "accept and remember it?"))
  s.send("yes\r")
  s.send("echo as-$(whoami); exit\r")
  #expect(waitScreen(s, "as-\(NSUserName())"))
}

/// ssh -v: every step of the connection, with the time it took.
@Test func verboseShowsTheSteps() throws {
  let server = try Server()
  let launcher = testLauncher(server.dir.appendingPathComponent("device"))
  try authorize(server, [try launcher.deviceKey()])
  let s = try Session(transport: Typed(launcher), rows: 40, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh -v -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "accept and remember it?"))
  s.send("yes\r")
  for step in [
    "keys loaded", "resolved 127.0.0.1", "key exchange done", "accepted: signing",
    "session open",
  ] {
    #expect(waitScreen(s, step))
  }
  s.send("exit\r")
  print(screenText(s))
}

/// rocchetto hands it one command, and done comes with the remote's exit status.
@Test func launcherRunsOneCommandForTheShell() throws {
  let server = try Server()
  let launcher = testLauncher(server.dir.appendingPathComponent("device"))
  try authorize(server, [try launcher.deviceKey()])
  final class Box: @unchecked Sendable {
    let lock = NSLock()
    var text = ""
    var status: Int32?
    func get<T>(_ f: (Box) -> T) -> T {
      lock.lock()
      defer { lock.unlock() }
      return f(self)
    }
  }
  let box = Box()
  func wait(_ ok: (Box) -> Bool) -> Bool {
    for _ in 0..<100 where !box.get(ok) {
      Thread.sleep(forTimeInterval: 0.1)
    }
    return box.get(ok)
  }
  launcher.command(
    ["ssh", "-p", "\(server.port)", "\(NSUserName())@127.0.0.1"],
    output: { b in box.get { $0.text += String(decoding: b, as: UTF8.self) } },
    done: { st in box.get { $0.status = st } })
  #expect(wait { $0.text.contains("accept and remember it?") })
  launcher.send(Array("yes\r".utf8))
  #expect(wait { $0.text.contains("$") || $0.text.contains("%") })
  launcher.send(Array("exit 3\r".utf8))
  #expect(wait { $0.status != nil })
  #expect(box.get { $0.status } == 3)

  box.get { $0.status = nil }
  launcher.command(["ssh"], output: { _ in }, done: { st in box.get { $0.status = st } })
  #expect(wait { $0.status != nil })
  #expect(box.get { $0.status } == 1)  // a refusal is a failure to the shell
}

private func testLauncher(_ dir: URL, vault: Vault? = nil) -> Launcher {
  Launcher(ssh: dir.appendingPathComponent(".ssh"), vault: vault)
}

private func sshDir(_ dir: URL) throws -> URL {
  let ssh = dir.appendingPathComponent(".ssh")
  try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
  return ssh
}

private func keygen(_ path: URL, _ args: [String], pass: String = "") throws -> PrivateKey {
  try Server.run("/usr/bin/ssh-keygen", ["-q", "-N", pass, "-f", path.path] + args)
  return try PrivateKey.load(
    String(contentsOf: path, encoding: .utf8), passphrase: pass.isEmpty ? nil : pass)
}

private func authorize(_ server: Server, _ keys: [PrivateKey]) throws {
  try keys.map { $0.authorizedKey + "\n" }.joined().write(
    to: server.dir.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
}

/// A locked default key is asked about only once the server says it takes
/// it, and only then is its passphrase asked for.
@Test func launcherAsksAPassphraseOnlyForTheKeyTheServerTakes() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  let ssh = try sshDir(dir)
  let taken = try keygen(
    ssh.appendingPathComponent("id_ed25519"), ["-t", "ed25519"], pass: "segredo")
  _ = try keygen(ssh.appendingPathComponent("id_ecdsa"), ["-t", "ecdsa"], pass: "outra")
  try authorize(server, [taken])

  let s = try Session(transport: Typed(testLauncher(dir)), rows: 24, cols: 100, history: 100)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  #expect(waitScreen(s, "passphrase for ~/.ssh/id_ed25519"))
  #expect(!screenText(s).contains("id_ecdsa"))  // refused by the server: never opened
  s.send("segredo\r")
  s.send("echo chave-$((6*7)); exit\r")
  #expect(waitScreen(s, "chave-42"))
  #expect(!screenText(s).contains("segredo"))
}

@Test func launcherUsesIdentityFileFromTheConfig() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  let ssh = try sshDir(dir)
  let work = try keygen(ssh.appendingPathComponent("trabalho"), ["-t", "rsa", "-m", "PEM"])
  try authorize(server, [work])
  try """
  Host lab
    HostName 127.0.0.1
    Port \(server.port)
    User \(NSUserName())
    IdentityFile ~/.ssh/trabalho
    IdentitiesOnly yes
  """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
  let s = try Session(transport: Typed(testLauncher(dir)), rows: 24, cols: 100, history: 100)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh lab\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  s.send("echo pem-$((6*7)); exit\r")
  #expect(waitScreen(s, "pem-42"))
  // IdentitiesOnly: the device key was not even made
  #expect(
    !FileManager.default.fileExists(atPath: ssh.appendingPathComponent("device_ed25519").path))
}

/// A first run: no ~/.ssh at all. `key` makes the directory (0700) and the
/// device key, and says which kind it is.
@Test func firstRunMakesSSHAndTheDeviceKey() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "fosforo-first-\(UUID().uuidString)")
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let ssh = dir.appendingPathComponent(".ssh")
  #expect(!FileManager.default.fileExists(atPath: ssh.path))
  let s = try Session(transport: Typed(testLauncher(dir)), rows: 24, cols: 100, history: 100)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("key\r")
  #expect(waitScreen(s) { $0.contains("ssh-ed25519 ") || $0.contains("ecdsa-sha2-nistp256 ") })
  let attrs = try FileManager.default.attributesOfItem(atPath: ssh.path)
  #expect((attrs[.posixPermissions] as? Int) == 0o700)
  let made = ["device_ed25519", "device_p256_se"].filter {
    FileManager.default.fileExists(atPath: ssh.appendingPathComponent($0).path)
  }
  #expect(made.count == 1)
  #expect(FileManager.default.fileExists(atPath: ssh.appendingPathComponent("device.pub").path))
}

/// ssh-keygen -t writes a pair OpenSSH itself reads back (ssh-keygen -y
/// gives the same public line), plain or under a passphrase asked twice,
/// and the new key logs in.
@Test func keygenMakesKeysOpenSSHReads() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  let ssh = dir.appendingPathComponent(".ssh")
  let s = try Session(transport: Typed(testLauncher(dir)), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh-keygen -t ed25519 -f ~/.ssh/nova -N '' -C teste\r")
  #expect(waitScreen(s, "public key has been saved in ~/.ssh/nova.pub"))
  let pub = try String(contentsOf: ssh.appendingPathComponent("nova.pub"), encoding: .utf8)
  #expect(pub.hasPrefix("ssh-ed25519 ") && pub.hasSuffix(" teste\n"))
  let seen = try Server.output(
    "/usr/bin/ssh-keygen", ["-y", "-f", ssh.appendingPathComponent("nova").path])
  #expect(seen.split(separator: " ").prefix(2) == pub.split(separator: " ").prefix(2))
  let text = try String(contentsOf: ssh.appendingPathComponent("nova"), encoding: .utf8)
  #expect(!PrivateKey.isEncrypted(text))
  #expect(
    try PrivateKey.load(text).authorizedKey
      == String(pub.split(separator: " ").prefix(2).joined(separator: " ")))
  s.send("ssh-keygen -t ed25519 -f ~/.ssh/nova -N ''\r")
  #expect(waitScreen(s, "already exists"))

  s.send("ssh-keygen -t ecdsa -b 384 -f ~/.ssh/curva\r")
  #expect(waitScreen(s, "Enter passphrase"))
  s.send("segredo\r")
  #expect(waitScreen(s, "same passphrase again"))
  s.send("outro\r")
  #expect(waitScreen(s, "do not match"))
  #expect(!FileManager.default.fileExists(atPath: ssh.appendingPathComponent("curva").path))
  s.send("ssh-keygen -t ecdsa -b 384 -f ~/.ssh/curva\r")
  #expect(waitScreen(s, "Enter passphrase"))
  s.send("segredo\r")
  #expect(waitScreen(s, "same passphrase again"))
  s.send("segredo\r")
  #expect(waitScreen(s, "saved in ~/.ssh/curva.pub"))
  let curva = try String(contentsOf: ssh.appendingPathComponent("curva"), encoding: .utf8)
  #expect(PrivateKey.isEncrypted(curva))
  let cpub = try String(contentsOf: ssh.appendingPathComponent("curva.pub"), encoding: .utf8)
  #expect(cpub.hasPrefix("ecdsa-sha2-nistp384 "))
  let cseen = try Server.output(
    "/usr/bin/ssh-keygen", ["-y", "-P", "segredo", "-f", ssh.appendingPathComponent("curva").path])
  #expect(cseen.split(separator: " ").prefix(2) == cpub.split(separator: " ").prefix(2))
  #expect(throws: SSHError.self) { try PrivateKey.load(curva, passphrase: "errada") }

  // the new key logs in: authorized on the test server, offered by IdentityFile
  try authorize(server, [try PrivateKey.load(text)])
  try """
  Host lab
    HostName 127.0.0.1
    Port \(server.port)
    User \(NSUserName())
    IdentityFile ~/.ssh/nova
    IdentitiesOnly yes
  """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
  s.send("ssh lab\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  s.send("echo nova-$((6*7)); exit\r")
  #expect(waitScreen(s, "nova-42"))
}

/// ssh -J and ProxyJump: the target is reached through a tunnel the jump
/// host opens; both host keys are asked about and remembered, the login
/// works, and mosh refuses the hop.
@Test func proxyJumpGoesThroughTheOtherHost() throws {
  let jump = try Server()
  let target = try Server()
  let dir = jump.dir.appendingPathComponent("device")
  let ssh = try sshDir(dir)
  let work = try keygen(ssh.appendingPathComponent("trabalho"), ["-t", "ed25519"])
  try authorize(jump, [work])
  try authorize(target, [work])
  try """
  Host alvo
    HostName 127.0.0.1
    Port \(target.port)
    User \(NSUserName())
    IdentityFile ~/.ssh/trabalho
    IdentitiesOnly yes
    ProxyJump salto
  Host salto alvo2
    HostName 127.0.0.1
    Port \(jump.port)
    User \(NSUserName())
    IdentityFile ~/.ssh/trabalho
    IdentitiesOnly yes
  Host alvo2
    Port \(target.port)
  """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
  let s = try Session(transport: Typed(testLauncher(dir)), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh alvo\r")
  #expect(waitScreen(s, "(the jump host)"))
  s.send("yes\r")
  #expect(waitScreen(s, "tunnel to 127.0.0.1 port \(target.port)"))
  #expect(waitScreen(s) { $0.components(separatedBy: "(yes/no)").count == 3 })  // the target's turn
  s.send("yes\r")
  s.send("echo jump-$((6*7)); exit\r")
  #expect(waitScreen(s, "jump-42"))
  let known = try String(contentsOf: ssh.appendingPathComponent("known_hosts"), encoding: .utf8)
  #expect(
    known.contains("[127.0.0.1]:\(jump.port) ") && known.contains("[127.0.0.1]:\(target.port) "))
  let atPrompt = { (text: String) in
    text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("test>")
  }
  #expect(waitScreen(s, atPrompt))  // the prompt is back before the next command
  // -J on the command line (host:port form), keys already known: no questions
  s.send("ssh -J salto:\(jump.port) alvo2\r")
  s.send("echo direto-$((1+1)); exit\r")
  #expect(waitScreen(s, "direto-2"))
  #expect(waitScreen(s, atPrompt))
  s.send("mosh -J salto alvo\r")
  #expect(waitScreen(s, "cannot go through a jump host"))
}

/// Two windows to the same host share one connection: the second asks
/// nothing and opens a session on it; closing one leaves the other; the
/// connection ends with the last.
@Test func sharedConnectionServesTwoWindows() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  let ssh = try sshDir(dir)
  let work = try keygen(ssh.appendingPathComponent("trabalho"), ["-t", "ed25519"])
  try authorize(server, [work])
  try """
  Host lab
    HostName 127.0.0.1
    Port \(server.port)
    User \(NSUserName())
    IdentityFile ~/.ssh/trabalho
    IdentitiesOnly yes
  """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
  let atPrompt = { (text: String) in
    text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("test>")
  }
  let one = try Session(transport: Typed(testLauncher(dir)), rows: 24, cols: 100, history: 100)
  let two = try Session(transport: Typed(testLauncher(dir)), rows: 24, cols: 100, history: 100)
  one.start()
  two.start()
  #expect(waitScreen(one, "test> ") && waitScreen(two, "test> "))
  one.send("ssh lab\r")
  #expect(waitScreen(one, "(yes/no)"))
  one.send("yes\r")
  one.send("echo um-$((1+1))\r")
  #expect(waitScreen(one, "um-2"))
  #expect(Launcher.sharedConnections(port: server.port) == 1)
  two.send("ssh lab\r")
  two.send("echo dois-$((1+2))\r")
  #expect(waitScreen(two, "dois-3"))
  #expect(!screenText(two).contains("(yes/no)") && !screenText(two).contains("connecting"))
  #expect(Launcher.sharedConnections(port: server.port) == 1)
  one.send("exit\r")
  #expect(waitScreen(one, atPrompt))
  two.send("echo tres-$((1+3))\r")
  #expect(waitScreen(two, "tres-4"))
  #expect(Launcher.sharedConnections(port: server.port) == 1)
  two.send("exit\r")
  #expect(waitScreen(two, atPrompt))
  #expect(waitScreen(two) { _ in Launcher.sharedConnections(port: server.port) == 0 })
}

@Test func keyFetchCopiesAKeyIntoSSH() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  let launcher = testLauncher(dir)
  try authorize(server, [try launcher.deviceKey()])
  let remote = server.dir.appendingPathComponent("remote_ed25519")
  let key = try keygen(remote, ["-t", "ed25519"])
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 120, history: 100)
  s.start()
  #expect(waitScreen(s, "test> "))
  let target = "\(NSUserName())@127.0.0.1:\(remote.path)"
  s.send("key fetch -p \(server.port) \(target) id_ed25519\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  #expect(waitScreen(s, "saved ~/.ssh/id_ed25519 and its .pub (in plain text"))
  let copied = dir.appendingPathComponent(".ssh/id_ed25519")
  #expect(
    try PrivateKey.load(String(contentsOf: copied, encoding: .utf8)).authorizedKey
      == key.authorizedKey)
  #expect(FileManager.default.fileExists(atPath: copied.path + ".pub"))
  let mode =
    try FileManager.default.attributesOfItem(atPath: copied.path)[.posixPermissions] as? Int
  #expect(mode == 0o600)
  s.send("key fetch -p \(server.port) \(target) id_ed25519\r")
  #expect(waitScreen(s, "exists: give the copy another name"))
  s.send("key fetch -p \(server.port) \(NSUserName())@127.0.0.1:/etc/hosts h\r")
  #expect(waitScreen(s, "is not a private key"))
  #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent(".ssh/h").path))
}

@Test func protectedKeysLogInAndComeBack() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  let ssh = try sshDir(dir)
  let vault = Vault(file: dir.appendingPathComponent("vault"), secureEnclave: false)
  let path = ssh.appendingPathComponent("id_ed25519")
  let key = try keygen(path, ["-t", "ed25519"])
  let original = try String(contentsOf: path, encoding: .utf8)
  try authorize(server, [key])
  let s = try Session(
    transport: Typed(testLauncher(dir, vault: vault)), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("key list\r")
  #expect(waitScreen(s, "plain text"))
  s.send("key protect id_ed25519\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("no\r")
  #expect(waitScreen(s, "nothing changed"))
  #expect(try String(contentsOf: path, encoding: .utf8) == original)
  s.send("key protect id_ed25519\r")
  #expect(waitScreen(s, "If fosforo is deleted"))
  s.send("yes\r")
  #expect(waitScreen(s, "protected ~/.ssh/id_ed25519"))
  let sealed = try String(contentsOf: path, encoding: .utf8)
  #expect(Vault.isProtected(sealed) && !sealed.contains("OPENSSH PRIVATE KEY"))
  #expect(sealed.contains("key unprotect id_ed25519"))  // the file says how to get it back
  s.send("key list\r")
  #expect(waitScreen(s, "protected"))
  s.send("ssh -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  s.send("echo cofre-$((6*7)); exit\r")
  #expect(waitScreen(s, "cofre-42"))
  #expect(waitScreen(s, "[connection closed]"))
  #expect(!screenText(s).contains("plain text on this device"))
  s.send("key unprotect id_ed25519\r")
  #expect(waitScreen(s, "back in plain text? (yes/no)"))
  s.send("yes\r")
  #expect(waitScreen(s, "is in plain text again"))
  #expect(try String(contentsOf: path, encoding: .utf8) == original)
  // used in plain text now: said once
  s.send("ssh -p \(server.port) \(NSUserName())@127.0.0.1\r")
  s.send("echo de-novo; exit\r")
  #expect(waitScreen(s, "de-novo"))
  #expect(screenText(s).contains("`key protect id_ed25519` keeps it encrypted here"))
}

/// A protected key the server refuses is never opened: here it was sealed
/// by another vault, and opening it would fail loudly.
@Test func refusedProtectedKeysStayClosed() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  let ssh = try sshDir(dir)
  let foreign = Vault(file: dir.appendingPathComponent("foreign"), secureEnclave: false)
  let path = ssh.appendingPathComponent("id_ed25519")
  let key = try keygen(path, ["-t", "ed25519"])
  try foreign.protect(
    String(contentsOf: path, encoding: .utf8), publicKey: key.authorizedKey, note: "x"
  ).write(to: path, atomically: true, encoding: .utf8)
  let launcher = testLauncher(
    dir, vault: Vault(file: dir.appendingPathComponent("v"), secureEnclave: false))
  try authorize(server, [try launcher.deviceKey()])
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  s.send("echo fechada; exit\r")
  #expect(waitScreen(s, "fechada"))
  #expect(!screenText(s).contains("another device"))
}

@Test func remoteQuoting() {
  #expect(Launcher.quote("~/.ssh/id") == "\"$HOME\"/'.ssh/id'")
  #expect(Launcher.quote("/a b/it's") == "'/a b/it'\\''s'")
}

final class Flag: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false
  var value: Bool {
    get {
      lock.lock()
      defer { lock.unlock() }
      return on
    }
    set {
      lock.lock()
      on = newValue
      lock.unlock()
    }
  }
}

private func settle(_ mosh: MoshTransport, seconds: Double = 10) -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if !mosh.predictionPending {
      return true
    }
    Thread.sleep(forTimeInterval: 0.02)
  }
  return false
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: moshServer)))
func moshPredictsTypingButNotPasswords() throws {
  let server = try Server()
  let ep = try MoshTransport.bootstrap(ssh: try server.config(), server: moshServer)
  defer {
    if let pid = ep.serverPID {
      kill(pid_t(pid), SIGTERM)
    }
  }
  let mosh = try MoshTransport(endpoint: ep, rows: 24, cols: 80)
  mosh.predictor.mode = .always
  let deaf = Flag()
  mosh.drop = { deaf.value }
  let s = try Session(transport: mosh, rows: 24, cols: 80, history: 0)
  s.start()
  s.send("PS1='$ '; clear\r")
  #expect(waitScreen(s, "$ "))
  Thread.sleep(forTimeInterval: 0.5)
  s.send("e")  // confirms the epoch once echoed
  #expect(settle(mosh))
  deaf.value = true  // the server's answers are lost: only the guess can show
  s.send("c")
  s.send("h")
  s.send("o")
  #expect(waitScreen(s, "$ echo", seconds: 2))
  deaf.value = false
  #expect(settle(mosh))
  s.send(" pre-$((6*7))\r")
  #expect(waitScreen(s, "pre-42"))

  s.send("read -s p; echo got-$p\r")
  Thread.sleep(forTimeInterval: 0.5)
  s.send("x")  // tentative after Return; no echo comes, so it is dropped
  #expect(settle(mosh))
  deaf.value = true
  for ch in "segredo" {
    s.send(String(ch))
  }
  Thread.sleep(forTimeInterval: 0.3)
  #expect(!screenText(s).contains("egredo"))
  deaf.value = false
  s.send("\r")
  #expect(waitScreen(s, "got-xsegredo"))
  s.send("exit\r")
}

/// ssh-copy-id against a sshd whose sessions get a scratch HOME: the
/// command must never touch the real ~/.ssh of whoever runs the tests.
@Test func sshCopyIDAddsTheKeyOnce() throws {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(
    "home-" + UUID().uuidString)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  let server = try Server(
    extra: "ForceCommand HOME=\(home.path) /bin/sh -c \"$SSH_ORIGINAL_COMMAND\"")
  // first, prove the scratch HOME holds; stop here if it does not
  let probe = SSHClient(config: try server.config(command: "echo casa=$HOME"))
  let seen = Flag()
  let path = home.path
  probe.onData = {
    if String(decoding: $0, as: UTF8.self).contains("casa=\(path)") { seen.value = true }
  }
  try probe.connect()
  probe.start()
  let deadline = Date().addingTimeInterval(10)
  while !seen.value && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
  }
  try #require(seen.value)
  let dir = server.dir.appendingPathComponent("device")
  let ssh = try sshDir(dir)
  let launcher = testLauncher(dir)
  try authorize(server, [try launcher.deviceKey()])
  let other = try keygen(ssh.appendingPathComponent("trabalho"), ["-t", "ecdsa"])
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh-copy-id -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  #expect(waitScreen(s, "added fosforo"))  // this device's key by default
  s.send("ssh-copy-id -i ~/.ssh/trabalho -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "added \(NSUserName())@"))  // -i's comment, not the line above
  let authorized = try String(
    contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8)
  #expect(authorized.contains(other.authorizedKey))
  s.send("ssh-copy-id -i ~/.ssh/trabalho -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "was already in"))
  #expect(
    try String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8)
      .components(separatedBy: "\n").filter { $0.contains(other.authorizedKey) }.count == 1)
  // no keys at all: this server takes no password, so it says no
  s.send("ssh-copy-id -o PubkeyAuthentication=no -p \(server.port) \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "permission denied"))
}

@Test func keyPasteSavesTheClipboardKey() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let scratch = try sshDir(dir.appendingPathComponent("scratch"))
  let key = try keygen(scratch.appendingPathComponent("k"), ["-t", "ed25519"])
  let text = try String(contentsOf: scratch.appendingPathComponent("k"), encoding: .utf8)
  let launcher = testLauncher(dir)
  var board: String? = "not a key"
  launcher.clipboard = { board }
  let s = try Session(transport: Typed(launcher), rows: 24, cols: 120, history: 100)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("key paste id_ed25519\r")
  #expect(waitScreen(s, "holds no private key"))
  board = text
  s.send("key paste id_ed25519\r")
  #expect(waitScreen(s, "saved ~/.ssh/id_ed25519 (in plain text)"))
  let saved = try String(contentsOf: dir.appendingPathComponent(".ssh/id_ed25519"), encoding: .utf8)
  #expect(try PrivateKey.load(saved).authorizedKey == key.authorizedKey)
  s.send("key paste id_ed25519\r")
  #expect(waitScreen(s, "exists: paste it under another name"))
}

/// localhost is ::1 and 127.0.0.1; the server listens only on the second.
/// The attempts race, so the refused one costs nothing.
@Test func dialRacesTheAddresses() throws {
  let server = try Server()
  let launcher = testLauncher(server.dir.appendingPathComponent("device"))
  try authorize(server, [try launcher.deviceKey()])
  let s = try Session(transport: Typed(launcher), rows: 40, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  let start = Date()
  s.send("ssh -p \(server.port) \(NSUserName())@localhost\r")
  #expect(waitScreen(s, "accept and remember it?"))
  #expect(Date().timeIntervalSince(start) < 2)
  s.send("no\r")
}

/// ssh -N -L from the line and LocalForward from the config: both ports
/// reach the server's sshd while the command runs, Ctrl+C ends it and the
/// ports with it; what is not here is said.
@Test func forwardsFromTheLineAndTheConfig() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  let ssh = try sshDir(dir)
  let work = try keygen(ssh.appendingPathComponent("trabalho"), ["-t", "ed25519"])
  try authorize(server, [work])
  let free = {  // nothing on it now, and below the ephemeral range (49152 up)
    for _ in 0..<100 {
      let port = Int.random(in: 20000...29999)
      if let fd = try? listenTCP(host: "127.0.0.1", port: port) {
        close(fd)
        return port
      }
    }
    throw SSHError.io("no free port")
  }
  let p1 = try free()
  let p2 = try free()
  try """
  Host fw
    HostName 127.0.0.1
    Port \(server.port)
    User \(NSUserName())
    IdentityFile ~/.ssh/trabalho
    IdentitiesOnly yes
    LocalForward \(p2) 127.0.0.1:\(server.port)
  """.write(to: ssh.appendingPathComponent("config"), atomically: true, encoding: .utf8)
  let s = try Session(transport: Typed(testLauncher(dir)), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send("ssh -N -L \(p1):127.0.0.1:\(server.port) fw\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  #expect(waitScreen(s, "forwarding \(p1), \(p2) (Ctrl-C ends it)"))
  for port in [p1, p2] {
    let fd = try dial(host: "127.0.0.1", port: port, timeout: 5)
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fd, &buf, buf.count)
    #expect(n > 8 && String(decoding: buf[0..<max(0, n)], as: UTF8.self).hasPrefix("SSH-2.0-"))
    close(fd)
  }
  s.send("\u{3}")
  #expect(waitScreen(s, "[connection closed]"))
  var closed = false
  for _ in 0..<100 where !closed {
    if let fd = try? dial(host: "127.0.0.1", port: p1, timeout: 1) {
      close(fd)
      Thread.sleep(forTimeInterval: 0.05)
    } else {
      closed = true
    }
  }
  #expect(closed)  // the port went with the connection
  s.send("ssh -D x fw\r")
  #expect(waitScreen(s, "-D x: not [bind_address:]port"))
  s.send("mosh -L 1:h:2 fw\r")
  #expect(waitScreen(s, "mosh carries no forwards"))
  s.send("ssh -L 8080:web fw\r")
  #expect(waitScreen(s, "not [bind_address:]port:host:hostport"))
}

/// -o, -i and -l from the line, with nothing for the host in the config:
/// as ssh_config lines that come first; an option not read here is said.
@Test func sshOptionsFromTheLine() throws {
  let server = try Server()
  let dir = server.dir.appendingPathComponent("device")
  let ssh = try sshDir(dir)
  let work = try keygen(ssh.appendingPathComponent("trabalho"), ["-t", "ed25519"])
  try authorize(server, [work])
  let s = try Session(transport: Typed(testLauncher(dir)), rows: 24, cols: 120, history: 200)
  s.start()
  #expect(waitScreen(s, "test> "))
  s.send(
    "ssh -o Port=\(server.port) -o IdentityFile=~/.ssh/trabalho -o IdentitiesOnly=yes"
      + " -l \(NSUserName()) 127.0.0.1\r")
  #expect(waitScreen(s, "(yes/no)"))
  s.send("yes\r")
  s.send("echo opt-$((2+2)); exit\r")
  #expect(waitScreen(s, "opt-4"))
  #expect(waitScreen(s) { $0.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("test>") })
  s.send(
    "ssh -i ~/.ssh/trabalho -oPort=\(server.port) -o UseKeychain=yes \(NSUserName())@127.0.0.1\r")
  #expect(waitScreen(s, "warning: -o usekeychain: not read here"))
  s.send("echo via-i; exit\r")
  #expect(waitScreen(s, "via-i"))
}
