import CryptoKit
import FosforoCore
import Foundation
import Testing

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
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    try p.run()
    p.waitUntilExit()
  }

  func config(command: String? = nil) throws -> SSHConfig {
    var c = SSHConfig(host: "127.0.0.1", user: NSUserName(), knownHosts: knownHosts)
    c.port = port
    c.keys = [try PrivateKey.openSSH(userKey)]
    c.command = command
    return c
  }
}

/// Collects a session's output until it closes.
final class Collector: @unchecked Sendable {
  private let lock = NSLock()
  private var data: [UInt8] = []
  private var closed = false
  private(set) var status: Int32?
  private(set) var error: SSHError?

  func attach(_ c: SSHClient) {
    c.onData = { bytes in
      self.lock.lock()
      self.data += bytes
      self.lock.unlock()
    }
    c.onClose = { status, error in
      self.lock.lock()
      self.status = status
      self.error = error
      self.closed = true
      self.lock.unlock()
    }
  }

  func attach(_ ch: SSHChannel) {
    ch.onData = { bytes in
      self.lock.lock()
      self.data += bytes
      self.lock.unlock()
    }
    ch.onClose = { status, error in
      self.lock.lock()
      self.status = status
      self.error = error
      self.closed = true
      self.lock.unlock()
    }
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self)
  }

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return data.count
  }

  func wait(until: () -> Bool = { false }, seconds: Double = 20) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      lock.lock()
      let done = closed
      lock.unlock()
      if done || until() {
        return true
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return false
  }
}

private func session(_ server: Server, command: String?) throws -> (SSHClient, Collector) {
  let c = SSHClient(config: try server.config(command: command))
  let out = Collector()
  out.attach(c)
  try c.connect()
  c.start()
  return (c, out)
}

@Test func execReturnsOutputAndExitStatus() throws {
  let server = try Server()
  let (_, out) = try session(server, command: "echo ok; printf '%s' \"$TERM\"; exit 7")
  #expect(out.wait())
  #expect(out.text.contains("ok"))
  #expect(out.text.contains("xterm-256color"))
  #expect(out.status == 7)
}

/// ControlMaster's ground: a second session on the connection already
/// made, each with its own output, exit and window; the connection stays
/// while one is open and ends with the last.
@Test func sessionsShareOneConnection() throws {
  let server = try Server()
  let (client, first) = try session(server, command: nil)
  #expect(client.channelCount == 1 && client.alive)
  let second = try client.openSession(rows: 10, cols: 40, command: "echo dois; stty size; exit 3")
  let out2 = Collector()
  out2.attach(second)
  second.start()
  #expect(out2.wait())
  #expect(out2.text.contains("dois") && out2.text.contains("10 40") && out2.status == 3)
  #expect(client.channelCount == 1 && client.alive)  // the first is still there
  client.send(Array("echo um; exit\n".utf8))
  #expect(first.wait())
  #expect(first.text.contains("um") && first.status == 0)
  #expect(Collector().wait(until: { client.channelCount == 0 && !client.alive }, seconds: 5))
  #expect(throws: SSHError.self) { try client.openSession(rows: 2, cols: 2) }  // over
}

/// A tunnel beside a session: the direct-tcpip channel to the server's
/// own port reads its banner through the socket.
@Test func aTunnelOpensBesideASession() throws {
  let server = try Server()
  let (client, out) = try session(server, command: nil)
  let tunnel = try client.openTunnel(host: "127.0.0.1", port: server.port)
  let fd = try tunnel.socket()
  var buf = [UInt8](repeating: 0, count: 64)
  let n = read(fd, &buf, buf.count)
  #expect(n > 8 && String(decoding: buf[0..<max(0, n)], as: UTF8.self).hasPrefix("SSH-2.0-"))
  close(fd)  // ends the pump, which closes the channel
  #expect(Collector().wait(until: { client.channelCount == 1 }, seconds: 5))
  client.send(Array("exit\n".utf8))
  #expect(out.wait() && out.status == 0)
}

@Test func interactiveShellSeesResize() throws {
  let server = try Server()
  let (c, out) = try session(server, command: nil)
  c.resize(rows: 33, cols: 101)
  c.send(Array("stty size; exit\n".utf8))
  #expect(out.wait())
  #expect(out.text.contains("33 101"))
}

@Test func bulkOutputSurvivesWindowsAndRekey() throws {
  let server = try Server(extra: "RekeyLimit 1M")
  let (client, out) = try session(
    server, command: "head -c 6000000 /dev/zero | LC_ALL=C tr '\\000' a")
  #expect(out.wait(seconds: 60))
  #expect(out.error == nil)
  #expect(client.exchanges > 1, "the server never rekeyed")
  let got = out.text.filter { $0 == "a" }.count
  #expect(got == 6_000_000, "got \(got) of \(out.count) bytes: \(out.text.prefix(80))")
}

/// FOSFORO_BENCH=1 swift test -c release --filter sshThroughput: 100 MB
/// from the loopback sshd through our client (AES-GCM, one rekey), what a
/// `cat` of a big file over ssh costs on this machine.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FOSFORO_BENCH"] == "1"))
func sshThroughput() throws {
  let server = try Server(extra: "RekeyLimit 64M")
  let t = Date()
  let (_, out) = try session(server, command: "head -c 100000000 /dev/zero")
  #expect(out.wait(seconds: 120))
  let seconds = Date().timeIntervalSince(t)
  print(
    "ssh: \(out.count / 1_000_000) MB in \(String(format: "%.2f", seconds)) s = "
      + "\(String(format: "%.0f", Double(out.count) / 1e6 / seconds)) MB/s")
}

@Test func hostKeyIsTrustedOnFirstUseAndPinned() throws {
  let server = try Server()
  let (_, first) = try session(server, command: "true")
  #expect(first.wait())
  let text = try String(contentsOfFile: server.knownHosts.path, encoding: .utf8)
  #expect(text.hasPrefix("[127.0.0.1]:\(server.port) ssh-ed25519 "))
  let (_, again) = try session(server, command: "true")
  #expect(again.wait())
  #expect(again.status == 0)

  let other = PrivateKey.ed25519(.init())
  try "[127.0.0.1]:\(server.port) \(other.authorizedKey)\n".write(
    toFile: server.knownHosts.path, atomically: true, encoding: .utf8)
  #expect(throws: SSHError.self) { try SSHClient(config: try server.config()).connect() }

  var strict = try server.config()
  strict.knownHosts = KnownHosts(path: server.dir.appendingPathComponent("empty").path)
  strict.acceptNewHostKeys = false
  #expect(throws: SSHError.self) { try SSHClient(config: strict).connect() }
}

@Test func aWrongKeyIsRefused() throws {
  let server = try Server()
  var cfg = try server.config()
  cfg.keys = [PrivateKey.ed25519(.init())]
  do {
    try SSHClient(config: cfg).connect()
    Issue.record("connected with a key the server does not know")
  } catch let e as SSHError {
    guard case .auth(let msg) = e else {
      Issue.record("wrong error: \(e)")
      return
    }
    #expect(msg.contains("publickey"))
  }
}

@Test func privateKeyFormats() throws {
  #expect(throws: SSHError.self) { try PrivateKey.openSSH("not a key") }
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let path = dir.appendingPathComponent("k").path
  try Server.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "secret", "-f", path])
  let locked = try String(contentsOfFile: path, encoding: .utf8)
  #expect(PrivateKey.isEncrypted(locked))
  #expect(throws: SSHError.self) { try PrivateKey.openSSH(locked) }
  #expect(throws: SSHError.self) { try PrivateKey.openSSH(locked, passphrase: "wrong") }
  let opened = try PrivateKey.openSSH(locked, passphrase: "secret")
  let lockedPub = try String(contentsOfFile: path + ".pub", encoding: .utf8)
  #expect(lockedPub.hasPrefix(opened.authorizedKey))
  try Server.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "", "-f", path + "2"])
  let key = try PrivateKey.openSSH(try String(contentsOfFile: path + "2", encoding: .utf8))
  let pub = try String(contentsOfFile: path + "2.pub", encoding: .utf8)
  #expect(pub.hasPrefix(key.authorizedKey))
}

@Test func wireRoundTrip() throws {
  var w = SSHWriter()
  w.u32(0xDEAD_BEEF)
  w.string("fosforo")
  w.nameList(["a", "b"])
  w.mpint([0x00, 0x80, 0x01])
  w.bool(true)
  var r = SSHReader(w.bytes)
  #expect(try r.u32() == 0xDEAD_BEEF)
  #expect(try r.text() == "fosforo")
  #expect(try r.nameList() == ["a", "b"])
  #expect(try r.string() == [0x00, 0x80, 0x01])
  #expect(try r.bool())
  #expect(throws: SSHError.self) { try r.byte() }
  var bad = SSHReader([0, 0, 0, 9, 1])
  #expect(throws: SSHError.self) { try bad.string() }
}

@Test func sshFeedsATerminalSession() throws {
  let server = try Server()
  let client = SSHClient(config: try server.config())
  try client.connect()
  let s = try Session(transport: SSHTransport(client: client), rows: 10, cols: 40, history: 10)
  s.start()
  s.resize(rows: 12, cols: 50)
  s.send("printf '\\033[32mverde\\033[0m\\n'; stty size; exit 3\n")
  let deadline = Date().addingTimeInterval(20)
  while !s.hasExited && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.02)
  }
  var screen = Screen()
  s.snapshot(into: &screen)
  var text = ""
  var green = false
  for c in screen.cells {
    text.unicodeScalars.append(Unicode.Scalar(c.cp == 0 ? 32 : c.cp) ?? " ")
    if c.cp == UInt32(("v" as Unicode.Scalar).value) && c.fg == (1 << 24 | 2) {
      green = true
    }
  }
  #expect(s.hasExited)
  #expect(text.contains("12 50"))
  #expect(green)
}

@Test func ecdsaKeysAuthenticate() throws {
  let server = try Server()
  let soft = PrivateKey.p256(.init())
  var keys = [soft]
  if SecureEnclave.isAvailable {
    keys.append(.secureEnclave(try SecureEnclave.P256.Signing.PrivateKey()))
  }
  let authorized = server.dir.appendingPathComponent("authorized_keys")
  for key in keys {
    try (key.authorizedKey + "\n").write(to: authorized, atomically: true, encoding: .utf8)
    var cfg = try server.config(command: "echo ecdsa-ok")
    cfg.keys = [key]
    let c = SSHClient(config: cfg)
    let out = Collector()
    out.attach(c)
    try c.connect()
    c.start()
    #expect(out.wait())
    #expect(out.text.contains("ecdsa-ok"))
  }
}

@Test(arguments: ["curve25519-sha256", "mlkem768x25519-sha256"])
func keyExchangeAlgorithms(kex: String) throws {
  if kex.hasPrefix("mlkem"), #unavailable(macOS 26) {
    return
  }
  let server = try Server(extra: "KexAlgorithms \(kex)\nRekeyLimit 256K")
  let c = SSHClient(
    config: try server.config(command: "head -c 700000 /dev/zero | LC_ALL=C tr '\\000' k"))
  let out = Collector()
  out.attach(c)
  try c.connect()
  c.start()
  #expect(out.wait(seconds: 60))
  #expect(c.negotiatedKex == kex)
  #expect(c.exchanges > 1)
  #expect(out.text.filter { $0 == "k" }.count == 700_000)
}

/// A port that accepts, says `greeting` if any, and nothing more.
private final class QuietPort {
  let fd: Int32
  let port: Int
  init(greeting: String?) throws {
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
    guard bound == 0, listen(sock, 4) == 0 else { throw SSHError.io("quiet port") }
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
        if let g = greeting {
          _ = Array(g.utf8).withUnsafeBytes { write(c, $0.baseAddress, $0.count) }
        }
        clients.append(c)  // kept open and mute
      }
    }.start()
  }
  deinit { close(fd) }
}

/// The timeout covers the whole negotiation, not only TCP: a server that
/// accepts and says nothing, or greets and then nothing, is given up on in
/// time; and close() or cancel() from elsewhere ends a connect at once.
@Test func connectGivesUpOnAQuietServerInTime() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let known = KnownHosts(path: dir.appendingPathComponent("known_hosts").path)
  for greeting in [nil, "SSH-2.0-quiet\r\n"] {
    let quiet = try QuietPort(greeting: greeting)
    var c = SSHConfig(host: "127.0.0.1", user: "x", knownHosts: known)
    c.port = quiet.port
    c.timeout = 0.3
    let began = Date()
    #expect(throws: SSHError.self) { try SSHClient(config: c).connect() }
    #expect(Date().timeIntervalSince(began) < 1.5, "\(greeting ?? "mute")")
    c.timeout = 10
    for stop in [SSHClient.close, SSHClient.cancel] {
      let client = SSHClient(config: c)
      Thread {
        Thread.sleep(forTimeInterval: 0.2)
        stop(client)()
      }.start()
      let t0 = Date()
      #expect(throws: SSHError.self) { try client.connect() }
      #expect(Date().timeIntervalSince(t0) < 2)
    }
  }
}

/// A known_hosts with hashed names (HashKnownHosts, what many servers'
/// files carry) matches like a plain one: the right key is known, a
/// different one under that hashed name is a change, not a stranger.
@Test func hashedKnownHostsMatch() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let file = dir.appendingPathComponent("known_hosts")
  func ed25519Blob() -> [UInt8] {
    var w = SSHWriter()
    w.string("ssh-ed25519")
    w.string(Array(Curve25519.Signing.PrivateKey().publicKey.rawRepresentation))
    return w.bytes
  }
  let blob = ed25519Blob()
  let other = ed25519Blob()
  let plain = KnownHosts(path: file.path)
  try plain.add(host: "lab.example", port: 2222, blob: blob)
  try plain.add(host: "box", port: 22, blob: blob)
  // OpenSSH hashes the file in place: an implementation we did not write
  let keygen = Process()
  keygen.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
  keygen.arguments = ["-H", "-f", file.path]
  keygen.standardOutput = FileHandle.nullDevice
  keygen.standardError = FileHandle.nullDevice
  try keygen.run()
  keygen.waitUntilExit()
  let text = try String(contentsOf: file, encoding: .utf8)
  #expect(keygen.terminationStatus == 0 && text.hasPrefix("|1|") && !text.contains("lab.example"))
  let hashed = KnownHosts(path: file.path)
  #expect(hashed.check(host: "lab.example", port: 2222, blob: blob) == .known)
  #expect(hashed.check(host: "box", port: 22, blob: blob) == .known)
  #expect(hashed.check(host: "lab.example", port: 22, blob: blob) == .unknown)  // another name
  #expect(hashed.check(host: "elsewhere", port: 22, blob: blob) == .unknown)
  if case .changed = hashed.check(host: "box", port: 22, blob: other) {
  } else {
    Issue.record("a different key under a hashed name must be a change")
  }
}

@Test func sshConfigAliases() {
  let h = SSHHosts(
    """
    # comment
    Host prod web
      HostName server.example.com
      User deploy
      Port 2222
    Host prod
      User other   # first value wins
    Host *.internal
      User nobody
    Host=bare
    HostName=10.0.0.1
    """)
  #expect(h["prod"] == SSHHosts.Entry(hostName: "server.example.com", user: "deploy", port: 2222))
  #expect(h["web"]?.port == 2222)
  #expect(h["bare"]?.hostName == "10.0.0.1")
  #expect(h["db.internal"]?.user == "nobody")
  #expect(h["missing"] == nil)
}

@Test func sshConfigIdentityFilesAddUp() {
  let h = SSHHosts(
    """
    Host lab
      IdentityFile ~/.ssh/lab
      IdentitiesOnly yes
    Host *
      IdentityFile ~/.ssh/id_rsa
    """)
  #expect(h["lab"]?.identityFiles == ["~/.ssh/lab", "~/.ssh/id_rsa"])
  #expect(h["lab"]?.identitiesOnly == true)
  #expect(h["other"]?.identitiesOnly == false)
}

/// Lines before the first Host apply to every host, and come first; as for
/// the other scalars, the first IdentitiesOnly wins, even when it says no.
@Test func sshConfigGlobalsAndIdentitiesOnlyFirst() {
  let h = SSHHosts(
    """
    ServerAliveInterval 5
    User global
    IdentityFile ~/.ssh/global
    Host target
      User target
      IdentitiesOnly yes
      Port 2022
    Host loose
      IdentitiesOnly no
    Host *
      IdentitiesOnly no
      ServerAliveInterval 60
      Port 22
    """)
  #expect(h["target"]?.aliveInterval == 5)
  #expect(h["target"]?.user == "global")
  #expect(h["target"]?.port == 2022)
  #expect(h["target"]?.identitiesOnly == true)
  #expect(h["target"]?.identityFiles == ["~/.ssh/global"])
  #expect(h["loose"]?.identitiesOnly == false)
  #expect(h["elsewhere"]?.user == "global")
  #expect(h["elsewhere"]?.port == 22)
  #expect(h["elsewhere"]?.aliveInterval == 5)
  #expect(h["elsewhere"]?.identitiesOnly == false)
  let yesLast = SSHHosts("Host a\n  IdentitiesOnly no\nHost *\n  IdentitiesOnly yes\n")
  #expect(yesLast["a"]?.identitiesOnly == false)
  #expect(yesLast["b"]?.identitiesOnly == true)
  let onlyGlobal = SSHHosts("Port 2200\n")
  #expect(onlyGlobal["any"]?.port == 2200)
  #expect(SSHHosts("# nothing\n")["any"] == nil)
}

/// A key the server refuses is never opened: its passphrase is not needed.
@Test func lockedKeysAreAskedAboutBeforeOpening() throws {
  let server = try Server()
  let refused = server.dir.appendingPathComponent("refused")
  try Server.run("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-N", "x", "-f", refused.path])
  let locked = try PrivateKey.deferred(
    String(contentsOf: refused, encoding: .utf8), pub: nil, name: "refused", passphrase: nil)
  var cfg = try server.config(command: "echo ok-sem-senha")
  cfg.keys = [locked] + cfg.keys
  let client = SSHClient(config: cfg)
  let out = Collector()
  out.attach(client)
  try client.connect()
  client.start()
  #expect(out.wait())
  #expect(out.text.contains("ok-sem-senha"))
  // and one the server takes says which file needs the passphrase
  try (locked.authorizedKey + "\n").write(
    to: server.dir.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
  var only = try server.config(command: "true")
  only.keys = [locked]
  #expect(throws: SSHError.locked("refused")) { try SSHClient(config: only).connect() }
}

@Test func sshConfigPatterns() {
  let h = SSHHosts(
    """
    Host lab?
      HostName %h.lab.example.com
    Host *.corp !bastion.corp
      User corp
      Port 2200
    Match host foo
      User matched
    Host *
      User default
      Port 22
    """)
  #expect(h["lab1"] == SSHHosts.Entry(hostName: "lab1.lab.example.com", user: "default", port: 22))
  #expect(h["lab12"]?.hostName == nil)
  #expect(h["WEB.corp"] == SSHHosts.Entry(hostName: nil, user: "corp", port: 2200))
  #expect(h["bastion.corp"]?.user == "default")
  #expect(h["foo"]?.user == "default")
  #expect(SSHHosts.glob(Array("a*b*c"), Array("aXbYbZc")))
  #expect(!SSHHosts.glob(Array("a*b"), Array("aXbc")))
}

/// Keys as ssh-keygen and openssl write them, locked and not, of every
/// type and format we sign with: each must load, match its public key and
/// log in.
@Test func keyFilesFromSSHKeygen() throws {
  let server = try Server()
  let cases: [(name: String, keygen: [String], pass: String)] = [
    ("ed25519", ["-t", "ed25519"], ""), ("ed25519-locked", ["-t", "ed25519"], "abc"),
    ("p256", ["-t", "ecdsa", "-b", "256"], ""),
    ("p256-locked", ["-t", "ecdsa", "-b", "256"], "abc"),
    ("p384", ["-t", "ecdsa", "-b", "384"], ""), ("p521", ["-t", "ecdsa", "-b", "521"], ""),
    ("rsa", ["-t", "rsa"], ""), ("rsa-locked", ["-t", "rsa"], "abc"),
    ("rsa-pem", ["-t", "rsa", "-m", "PEM"], ""),
  ]
  for c in cases {
    let path = server.dir.appendingPathComponent("k-\(c.name)").path
    try Server.run("/usr/bin/ssh-keygen", ["-q", "-N", c.pass, "-f", path] + c.keygen)
    try login(server, path: path, pass: c.pass, label: c.name)
  }
  // PEM with a passphrase: OpenSSL's traditional encryption (ssh-keygen no
  // longer writes it), AES as recent tools did and 3DES as old ones did
  for (cipher, header) in [("-aes128", "AES-128-CBC"), ("-des3", "DES-EDE3-CBC")] {
    let path = server.dir.appendingPathComponent("k-rsa\(cipher)").path
    try Server.run(
      "/usr/bin/openssl",
      ["genrsa", cipher, "-passout", "pass:abc", "-out", path, "2048"])
    // ssh-keygen refuses a key others can read, as openssl leaves it
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    let pub = Process()
    pub.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
    pub.arguments = ["-y", "-P", "abc", "-f", path]
    let pipe = Pipe()
    pub.standardOutput = pipe
    try pub.run()
    pub.waitUntilExit()
    try pipe.fileHandleForReading.readDataToEndOfFile().write(
      to: URL(fileURLWithPath: path + ".pub"))
    #expect(try String(contentsOfFile: path, encoding: .utf8).contains(header))
    try login(server, path: path, pass: "abc", label: header)
  }
}

@Test func pemWithTheWrongPassphraseSaysSo() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  let path = dir.appendingPathComponent("k").path
  try Server.run(
    "/usr/bin/openssl", ["genrsa", "-aes128", "-passout", "pass:abc", "-out", path, "2048"])
  let text = try String(contentsOfFile: path, encoding: .utf8)
  for wrong in ["abd", "x", "abcabc", "senha", "123"] {
    #expect(throws: SSHError.auth("wrong passphrase")) {
      try PrivateKey.load(text, passphrase: wrong)
    }
  }
  #expect(throws: SSHError.auth("passphrase needed")) { try PrivateKey.load(text) }
}

/// The keys of whoever runs this, when FOSFORO_REAL_KEYS=1: every private
/// key in ~/.ssh without a passphrase must load and match its .pub. Nothing
/// of the keys is printed, only the file names that fail.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FOSFORO_REAL_KEYS"] == "1"))
func realKeysLoad() throws {
  let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh")
  var checked = 0
  for f in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
    let url = dir.appendingPathComponent(f)
    guard let text = try? String(contentsOf: url, encoding: .utf8), PrivateKey.isPrivateKey(text),
      !PrivateKey.isEncrypted(text),
      let pub = try? String(contentsOf: url.appendingPathExtension("pub"), encoding: .utf8)
    else {
      continue
    }
    let key = try? PrivateKey.load(text)
    #expect(key.map { pub.hasPrefix($0.authorizedKey) } == true, "\(f)")
    checked += 1
  }
  print("realKeysLoad: \(checked) keys checked")
  #expect(checked > 0)
}

private func login(_ server: Server, path: String, pass: String, label: String) throws {
  let text = try String(contentsOfFile: path, encoding: .utf8)
  #expect(PrivateKey.isEncrypted(text) == !pass.isEmpty, "\(label)")
  let key = try PrivateKey.load(text, passphrase: pass.isEmpty ? nil : pass)
  let pub = try String(contentsOfFile: path + ".pub", encoding: .utf8)
  #expect(pub.hasPrefix(key.authorizedKey), "\(label)")
  try (key.authorizedKey + "\n").write(
    to: server.dir.appendingPathComponent("authorized_keys"), atomically: true, encoding: .utf8)
  var cfg = try server.config(command: "echo key-ok")
  cfg.keys = [key]
  let client = SSHClient(config: cfg)
  let out = Collector()
  out.attach(client)
  try client.connect()
  client.start()
  #expect(out.wait())
  #expect(out.text.contains("key-ok"), "\(label)")
}

@Test func bigModMatchesSmallNumbers() {
  #expect(bigMod([0x01, 0x00, 0x01], [0x07]) == [UInt8(65537 % 7)])
  #expect(bigMod([0x12, 0x34, 0x56, 0x78], [0x01, 0x00]) == [0x78])
  #expect(bigMod([0x05], [0x09]) == [0x05])
  #expect(minusOne([0x01, 0x00]) == [0x00, 0xFF])
}

@Test func bcryptPBKDFKnownAnswer() {
  // golang.org/x/crypto bcrypt_pbkdf test vector
  let key = BcryptPBKDF.derive(
    password: Array("password".utf8), salt: Array("salt".utf8), rounds: 4, length: 32)
  let hex = key.map { String(format: "%02x", $0) }.joined()
  #expect(hex == "5bbf0cc293587f1c3635555c27796598d47e579071bf427e9d8fbe842aba34d9")
}

private func infoRequest(_ prompts: [(String, Bool)]) -> [UInt8] {
  var w = SSHWriter(message: 60)
  w.string("")
  w.string("")
  w.string("")
  w.u32(UInt32(prompts.count))
  for (p, echo) in prompts {
    w.string(p)
    w.byte(echo ? 1 : 0)
  }
  return w.bytes
}

@Test func keyboardInteractiveAnswersThePasswordPromptOnce() throws {
  var answered = false
  let out = try keyboardInteractiveResponse(
    infoRequest([("Username: ", true), ("Password: ", false)]), password: "pw",
    answered: &answered)
  var r = SSHReader(out)
  #expect(try r.byte() == 61)
  #expect(try r.u32() == 2)
  #expect(try r.text() == "")
  #expect(try r.text() == "pw")
  #expect(answered)
  let done = try keyboardInteractiveResponse(infoRequest([]), password: "pw", answered: &answered)
  #expect(done == [61, 0, 0, 0, 0])
  #expect(throws: SSHError.self) {
    try keyboardInteractiveResponse(
      infoRequest([("Verification code: ", false)]), password: "pw", answered: &answered)
  }
}

@Test func vaultSealsForItsOwnKeyOnly() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let vault = Vault(file: dir.appendingPathComponent("a"), secureEnclave: false)
  let original = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
  let sealed = try vault.protect(original, publicKey: "ssh-ed25519 AAAAB3 x", note: "teste")
  #expect(Vault.isProtected(sealed))
  #expect(Vault.publicLine(sealed) == "ssh-ed25519 AAAAB3 x")
  #expect(!sealed.contains("AAAA\n"))
  #expect(try vault.open(sealed) == original)
  let other = Vault(file: dir.appendingPathComponent("b"), secureEnclave: false)
  #expect(throws: SSHError.self) { try other.open(sealed) }
  var bytes = Array(sealed)
  let i = bytes.count - 60
  bytes[i] = bytes[i] == "A" ? "B" : "A"
  #expect(throws: SSHError.self) { try vault.open(String(bytes)) }
}

/// A connection to a forward here whose reads give up after 5 s: a forward
/// that drops the connection fails the test instead of holding it.
private func dialBounded(_ port: Int) throws -> Int32 {
  let fd = try dial(host: "127.0.0.1", port: port, timeout: 5)
  var tv = timeval(tv_sec: 5, tv_usec: 0)
  setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
  return fd
}

/// A port nothing listens on now, below the ephemeral range (49152 up): one
/// the system hands out could go to the next outgoing connection, the
/// client's own to sshd among them, before the test binds it. Tried by
/// binding, since tests run side by side.
private func freePort() -> Int {
  for _ in 0..<100 {
    let port = Int.random(in: 20000...29999)
    if let fd = try? listenTCP(host: "127.0.0.1", port: port) {
      close(fd)
      return port
    }
  }
  return 0
}

@Test func forwardSpecsReadAsSshTakesThem() {
  typealias F = SSHConfig.Forward
  #expect(F.parse("8080:web:80") == F(bindPort: 8080, host: "web", port: 80))
  #expect(F.parse("*:8080:web:80") == F(bindHost: "", bindPort: 8080, host: "web", port: 80))
  #expect(F.parse("0.0.0.0:2:[::1]:3") == F(bindHost: "0.0.0.0", bindPort: 2, host: "::1", port: 3))
  #expect(F.parse("[::1]:8080:h:80") == F(bindHost: "::1", bindPort: 8080, host: "h", port: 80))
  #expect(F.parse("8080:web") == nil && F.parse("x:web:80") == nil && F.parse("1:h:70000") == nil)
}

/// -L with -N: a port here reaches the server's own sshd; the connection
/// carries it with no session, and the port goes with the connection.
@Test func localForwardReachesTheServerSide() throws {
  let server = try Server()
  var c = try server.config()
  let port = freePort()
  c.localForwards = [SSHConfig.Forward(bindPort: port, host: "127.0.0.1", port: server.port)]
  c.noSession = true
  let client = SSHClient(config: c)
  try client.connect()
  #expect(client.alive && client.channelCount == 0)
  // one after the other: the channel of each ends while the next is already
  // accepted, which may be given the fd number the last one had
  for _ in 0..<20 {
    let fd = try dialBounded(port)
    var buf = [UInt8](repeating: 0, count: 64)
    let n = read(fd, &buf, buf.count)
    #expect(n > 8 && String(decoding: buf[0..<max(0, n)], as: UTF8.self).hasPrefix("SSH-2.0-"))
    close(fd)
  }
  client.disconnect()
  #expect(Collector().wait(until: { !client.alive }, seconds: 5))
  #expect(
    Collector().wait(
      until: { (try? dial(host: "127.0.0.1", port: port, timeout: 1)) == nil }, seconds: 5))
}

/// -R: a port on the server comes back to a listener here.
@Test func remoteForwardComesBack() throws {
  let server = try Server()
  let here = try listenTCP(host: "127.0.0.1", port: freePort())
  var addr = sockaddr_in()
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafeMutablePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(here, $0, &len) }
  }
  let local = Int(UInt16(bigEndian: addr.sin_port))
  Thread.detachNewThread {
    let conn = accept(here, nil, nil)
    let hello = Array("hello from here\n".utf8)
    _ = write(conn, hello, hello.count)
    close(conn)
    close(here)
  }
  let remote = freePort()
  var c = try server.config(command: "nc 127.0.0.1 \(remote)")
  c.remoteForwards = [SSHConfig.Forward(bindPort: remote, host: "127.0.0.1", port: local)]
  let client = SSHClient(config: c)
  let out = Collector()
  out.attach(client)
  try client.connect()
  client.start()
  #expect(out.wait())
  #expect(out.text.contains("hello from here"))
}

/// -A: the server's ssh-add lists the key, and a signature it asks the
/// forwarded agent for checks out against the key's public half.
@Test func agentSignsForTheServer() throws {
  let server = try Server()
  let d = server.dir.path
  var c = try server.config(
    command: "cd \(d) && export HOME=\(d) && ssh-add -L && printf hi > msg"
      + " && ssh-keygen -Y sign -f user.pub -n test msg"
      + " && ssh-keygen -Y check-novalidate -n test -f user.pub -s msg.sig < msg")
  c.forwardAgent = true
  let client = SSHClient(config: c)
  let out = Collector()
  out.attach(client)
  try client.connect()
  client.start()
  #expect(out.wait())
  let pub = try String(contentsOf: server.dir.appendingPathComponent("user.pub"), encoding: .utf8)
  let blob = pub.split(separator: " ")[1]
  #expect(out.text.contains(blob), "\(out.text)")
  #expect(out.text.contains("Good \"test\" signature"), "\(out.text)")
  #expect(out.status == 0)
}

/// Without -A the server's agent channel is refused: ssh-add finds none.
@Test func noAgentWithoutAsking() throws {
  let server = try Server()
  let (_, out) = try session(server, command: "ssh-add -L; echo st=$?")
  #expect(out.wait())
  #expect(out.text.contains("st=2"), "\(out.text)")  // no agent to talk to
}

@Test func dynamicSpecsReadAsSshTakesThem() {
  typealias F = SSHConfig.Forward
  #expect(F.parseDynamic("1080") == F(bindPort: 1080, host: "", port: 0))
  #expect(F.parseDynamic("*:1080") == F(bindHost: "", bindPort: 1080, host: "", port: 0))
  #expect(F.parseDynamic("[::1]:1080") == F(bindHost: "::1", bindPort: 1080, host: "", port: 0))
  #expect(F.parseDynamic("x") == nil && F.parseDynamic("0") == nil)
}

/// -D: a SOCKS proxy here. A SOCKS 5 client by address and by name, a
/// SOCKS 4 one, each reaching the server's sshd; a port nothing listens
/// on is answered with a refusal.
@Test func dynamicForwardIsASocksProxy() throws {
  let server = try Server()
  var c = try server.config()
  let port = freePort()
  c.dynamicForwards = [SSHConfig.Forward(bindPort: port, host: "", port: 0)]
  c.noSession = true
  let client = SSHClient(config: c)
  try client.connect()
  defer { client.disconnect() }
  let sp = [UInt8(server.port >> 8), UInt8(server.port & 0xFF)]
  func banner(_ hello: [UInt8], _ reply: Int) throws -> (ok: [UInt8], text: String) {
    let fd = try dialBounded(port)
    defer { close(fd) }
    _ = hello.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    var answer = [UInt8](repeating: 0, count: reply)
    var got = 0
    while got < reply {
      let n = answer[got...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if n <= 0 { break }
      got += n
    }
    var buf = [UInt8](repeating: 0, count: 64)
    let n = answer.count == got && (answer[1] == 0 || answer[1] == 0x5A) ? read(fd, &buf, 64) : 0
    return (answer, String(decoding: buf[0..<max(0, n)], as: UTF8.self))
  }
  // SOCKS 5: the greeting answer and the request answer come together here
  let v5 = try banner([5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1] + sp, 12)
  #expect(v5.ok[0...1] == [5, 0] && v5.ok[2...3] == [5, 0] && v5.text.hasPrefix("SSH-2.0-"))
  let name = Array("localhost".utf8)
  let byName = try banner([5, 1, 0, 5, 1, 0, 3, UInt8(name.count)] + name + sp, 12)
  #expect(byName.ok[2...3] == [5, 0] && byName.text.hasPrefix("SSH-2.0-"))
  let v4 = try banner([4, 1] + sp + [127, 0, 0, 1, 0], 8)
  #expect(v4.ok[0...1] == [0, 0x5A] && v4.text.hasPrefix("SSH-2.0-"))
  let closed = freePort()
  let no = try banner(
    [5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1, UInt8(closed >> 8), UInt8(closed & 0xFF)], 12)
  #expect(no.ok[2] == 5 && no.ok[3] != 0)
}
