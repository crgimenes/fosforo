import CryptoKit
import FosforoCore
import FosforoSSH
import Foundation

/// The app's commands on iPad and iPhone (ssh, mosh, key, ssh-copy-id,
/// ssh-keygen): rocchetto hands each one here (command) and waits for it.
public final class Launcher: Transport, @unchecked Sendable {
  private let lock = NSLock()
  private var output: (@Sendable ([UInt8]) -> Void)?
  private var line: [Character] = []
  private var rows = 24
  private var cols = 80
  private var remote: Transport?
  private var connecting = false
  private var typeahead: [UInt8] = []  // typed while connecting, for the remote side
  private var cancelConnect: (() -> Void)?  // stops the client connecting now
  private var cancelled = false  // Ctrl+C took this command back
  private var closed = false  // the window went: nothing may attach any more
  /// Which command this is; a connect thread that returns after Ctrl+C and
  /// a new command carries the number it started with and finds it stale.
  private var attempt = 0
  /// Tests only: runs on a connect thread before it reports a failure.
  var holdBeforeFailing: (@Sendable () -> Void)?
  private var question: Question?

  /// A yes/no or a password the next line answers.
  private enum Question {
    case hostKey(Target, jump: Bool)  // the key asked about is the jump host's
    case password(Target)
    case passphrase(Target, String)  // the path of the key file it unlocks
    case confirm(() -> Void)  // yes runs it
    case newPassphrase(Keygen, first: String?)  // ssh-keygen -t: asked, then asked again
    case reconnect(Target)  // the connection was lost: yes (or just Enter) dials again
  }

  /// A key being made by ssh-keygen -t.
  private struct Keygen {
    var type: String
    var bits: Int
    var file: URL
    var comment: String
  }

  /// Where a connection goes: SSH alone, SSH to start mosh-server, or SSH
  /// to bring a key file back.
  private struct Target {
    var ssh: SSHConfig
    var mosh: String?  // the mosh-server command, when this is mosh
    var identities: [URL] = []  // key files to offer, in order
    var identitiesOnly = false  // no device key after them
    var fetch: (path: String, name: String)?
    var copyID: String?  // the authorized_keys line ssh-copy-id installs
    var noKeys = false  // -o PubkeyAuthentication=no: straight to the password
    var jumpSpec: [String]?  // -J or ProxyJump as ssh arguments ([-p port] [user@]host), one hop
    var jump: SSHConfig?  // the hop, keys loaded, ready to tunnel to ssh.host
    var jumpAccepted = false  // the hop's unknown host key was taken
  }

  /// Where keys, config and known_hosts live, as ~/.ssh on a computer: the
  /// app's own (iPad, iPhone; the Mac is only a terminal, its ssh the system's).
  private let ssh: URL
  private let home: URL  // what ~ means in IdentityFile and in messages

  /// Keeps key files encrypted for this device (key protect).
  private let vault: Vault?

  /// The app's vault on iOS: one per process, so a session's confirmation
  /// serves every window.
  public static let deviceVault: Vault? = {
    #if os(iOS)
      let support =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSTemporaryDirectory())
      return Vault(file: support.appendingPathComponent("fosforo/vault_p256_se"))
    #else
      return nil
    #endif
  }()

  /// vault nil: the device's.
  public init(ssh: URL, vault: Vault? = nil) {
    self.vault = vault ?? Launcher.deviceVault
    self.ssh = ssh
    home = ssh.deletingLastPathComponent()
  }

  /// ~/.ssh/id_rsa rather than the full path of the app's container.
  private func shown(_ url: URL) -> String {
    let h = home.path
    return url.path.hasPrefix(h + "/") ? "~" + url.path.dropFirst(h.count) : url.path
  }

  private func expand(_ path: String) -> URL {
    if path == "~" || path.hasPrefix("~/") {
      return home.appendingPathComponent(String(path.dropFirst(2)))
    }
    return path.hasPrefix("/") ? URL(fileURLWithPath: path) : ssh.appendingPathComponent(path)
  }

  /// Never on its own: rocchetto starts it with a command, which brings the
  /// output along.
  public func start(
    output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void
  ) {}

  private func say(_ s: String) {
    lock.lock()
    let out = output
    lock.unlock()
    out?(Array(s.utf8))
  }

  /// The command is over: the shell gets its status.
  private func finish() {
    lock.lock()
    let d = done
    done = nil
    let st = status
    status = 0
    lock.unlock()
    d?(st)
  }

  private var done: (@Sendable (Int32) -> Void)?
  private var status: Int32 = 0  // the command's exit status, for done

  private func fail(_ message: String, status: Int32 = 1) {
    lock.lock()
    self.status = status
    lock.unlock()
    say(message + "\r\n")
  }

  /// One command for the shell: the terminal is this launcher's until done
  /// comes with the status.
  public func command(
    _ words: [String], output: @escaping @Sendable ([UInt8]) -> Void,
    done: @escaping @Sendable (Int32) -> Void
  ) {
    lock.lock()
    self.output = output
    self.done = done
    cancelled = false
    attempt += 1
    lock.unlock()
    run(words)
  }

  /// What command takes.
  public static let shellCommands = ["ssh", "mosh", "key", "ssh-copy-id", "ssh-keygen"]

  public func send(_ bytes: [UInt8]) {
    lock.lock()
    if let r = remote {
      lock.unlock()
      r.send(bytes)
      return
    }
    if connecting {
      if bytes == [0x03] {
        lock.unlock()
        interrupt()
        return
      }
      typeahead += bytes
      lock.unlock()
      return
    }
    lock.unlock()
    if bytes.first == 0x1B {
      return  // arrows and function keys mean nothing to a question
    }
    for ch in String(decoding: bytes, as: UTF8.self) {
      key(ch)
    }
  }

  /// What ssh offers when the host names no IdentityFile, as OpenSSH does.
  private static let defaultIdentities = ["id_rsa", "id_ecdsa", "id_ed25519"]

  private var secret: Bool {
    switch question {
    case .password, .passphrase, .newPassphrase:
      return true
    default:
      return false
    }
  }

  private func key(_ ch: Character) {
    switch ch {
    case "\r", "\n":
      say("\r\n")
      let text = String(line)
      line.removeAll()
      guard let q = question else { return }
      question = nil
      answer(q, text)
    case "\u{7f}", "\u{8}":
      if !line.isEmpty {
        line.removeLast()
        if !secret {
          say("\u{8} \u{8}")
        }
      }
    case "\u{3}":
      line.removeAll()
      question = nil
      lock.lock()
      status = 130
      lock.unlock()
      say("^C\r\n")
      finish()
    case "\u{15}":
      say(String(repeating: "\u{8} \u{8}", count: secret ? 0 : line.count))
      line.removeAll()
    default:
      guard let a = ch.unicodeScalars.first, a.value >= 0x20, line.count < 1024 else { return }
      line.append(ch)
      if !secret {
        say(String(ch))
      }
    }
  }

  private func run(_ words: [String]) {
    switch words.first {
    case nil:
      finish()
    case "ssh-copy-id":
      do {
        connect(try copyIDTarget(Array(words.dropFirst())))
      } catch {
        fail("\(error)")
        finish()
      }
    case "key" where words.count == 3 && words[1] == "paste":
      do {
        try paste(words[2])
      } catch {
        fail("\(error)")
      }
      finish()
    case "key" where words.count == 2 && words[1] == "list":
      listKeys()
      finish()
    case "key" where words.count == 3 && (words[1] == "protect" || words[1] == "unprotect"):
      do {
        try (words[1] == "protect" ? protect : unprotect)(words[2])
      } catch {
        fail("\(error)")
        finish()
      }
    case "key" where words.count > 1 && words[1] == "fetch":
      do {
        connect(try fetchTarget(Array(words.dropFirst(2))))
      } catch {
        fail("\(error)")
        finish()
      }
    case "key":
      do {
        let line = try deviceKey().authorizedKey + " fosforo"
        try (line + "\n").write(
          to: deviceDirectory.appendingPathComponent("device.pub"), atomically: true,
          encoding: .utf8)
        say(line + "\r\n(\(deviceKeyKind); add this line to ~/.ssh/authorized_keys)\r\n")
      } catch {
        fail("\(error)")
      }
      finish()
    case "ssh-keygen":
      if words.dropFirst().first == "-t" {
        keygen(Array(words.dropFirst()))
      } else {
        forget(Array(words.dropFirst()))
      }
    case "ssh", "mosh":
      do {
        connect(try parse(Array(words.dropFirst()), mosh: words[0] == "mosh"))
      } catch {
        fail("\(error)")
        finish()
      }
    default:
      fail("\(words[0]): unknown command", status: 127)
      finish()
    }
  }

  /// [user@]host, where host may be an alias from ssh_config in the
  /// config directory; -p on the command line beats the file.
  private func parse(_ args: [String], mosh asked: Bool) throws -> Target {
    var mosh = asked
    var port: Int?
    var target: String?
    var server = "mosh-server"
    var verbose = false
    var jump: String?
    var local: [String] = []
    var remote: [String] = []
    var dynamic: [String] = []
    var options: [String] = []  // -o, as ssh_config lines
    var identities: [String] = []  // -i, before the config's
    var login: String?  // -l
    var agent = false
    var noSession = false
    var i = 0
    while i < args.count {
      // flags alone or together (-v, -A, -N, -AN)
      if args[i].count > 1, args[i].hasPrefix("-"),
        args[i].dropFirst().allSatisfy({ "vAN".contains($0) })
      {
        for f in args[i].dropFirst() {
          switch f {
          case "v": verbose = true
          case "A": agent = true
          default: noSession = true
          }
        }
        i += 1
        continue
      }
      // -o Key=value (or -oKey=value), -i file, -l user
      if args[i].hasPrefix("-o") || args[i] == "-i" || args[i] == "-l" {
        let attached = args[i].hasPrefix("-o") ? String(args[i].dropFirst(2)) : ""
        guard !attached.isEmpty || i + 1 < args.count else {
          throw SSHError.io("ssh: \(args[i]) needs a value")
        }
        let value = attached.isEmpty ? args[i + 1] : attached
        switch args[i] {
        case "-i": identities.append(value)
        case "-l": login = value
        default:
          options.append(
            value.replacingOccurrences(of: "=", with: " ", options: [], range: value.range(of: "="))
          )
        }
        i += attached.isEmpty ? 2 : 1
        continue
      }
      if args[i].hasPrefix("-D") {
        let attached = String(args[i].dropFirst(2))
        let spec = attached.isEmpty && i + 1 < args.count ? args[i + 1] : attached
        guard SSHConfig.Forward.parseDynamic(spec) != nil else {
          throw SSHError.io("ssh: -D \(spec): not [bind_address:]port")
        }
        dynamic.append(spec)
        i += attached.isEmpty ? 2 : 1
        continue
      }
      // -L spec and -R spec, or -Lspec
      if args[i].hasPrefix("-L") || args[i].hasPrefix("-R") {
        let attached = String(args[i].dropFirst(2))
        let spec = attached.isEmpty && i + 1 < args.count ? args[i + 1] : attached
        guard SSHConfig.Forward.parse(spec) != nil else {
          throw SSHError.io(
            "ssh: \(args[i].prefix(2)) \(spec): not [bind_address:]port:host:hostport")
        }
        if args[i].hasPrefix("-L") {
          local.append(spec)
        } else {
          remote.append(spec)
        }
        i += attached.isEmpty ? 2 : 1
        continue
      }
      if args[i] == "-J", i + 1 < args.count, !args[i + 1].isEmpty {
        jump = args[i + 1]
        i += 2
        continue
      }
      if args[i] == "-p", i + 1 < args.count, let p = Int(args[i + 1]), (1...65535).contains(p) {
        port = p
        i += 2
        continue
      }
      if mosh, args[i] == "--server", i + 1 < args.count {
        server = args[i + 1]
        i += 2
        continue
      }
      target = args[i]
      i += 1
    }
    let usage = SSHError.io(
      mosh
        ? "usage: mosh [-v] [-p port] [user@]host"
        : "usage: ssh [-vAN] [-p port] [-l user] [-i file] [-o option=value]"
          + " [-J [user@]jump[:port]] [-L [bind:]port:host:hostport]"
          + " [-R [bind:]port:host:hostport] [-D [bind:]port] [user@]host")
    guard let t = target, !t.isEmpty, !t.hasSuffix("@"), !t.hasPrefix("@") else {
      throw usage
    }
    if mosh && jump != nil {
      throw SSHError.io("mosh cannot go through a jump host: its UDP goes straight to the host")
    }
    if mosh && (agent || noSession || !local.isEmpty || !remote.isEmpty || !dynamic.isEmpty) {
      throw SSHError.io("mosh carries no forwards: ssh -L, -R, -D and -A do")
    }
    var user: String?
    var name = t
    if let at = t.firstIndex(of: "@") {
      user = String(t[..<at])
      name = String(t[t.index(after: at)...])
    }
    // -o lines go first, before any Host: they apply to every host, and
    // the first value found wins, as on a computer
    let file =
      (try? String(contentsOf: ssh.appendingPathComponent("config"), encoding: .utf8)) ?? ""
    for o in options {
      let key = o.split(separator: " ").first.map { $0.lowercased() } ?? ""
      if !Launcher.optionsRead.contains(key) {
        say("warning: -o \(key): not read here\r\n")
      }
    }
    let alias = SSHHosts(options.joined(separator: "\n") + "\n" + file)[name]
    // Mosh yes: ssh to that host is mosh, unless something only ssh carries
    // is asked for, on the line or in the config (a jump, forwards, the agent)
    if !mosh, alias?.mosh == true, jump == nil, alias?.proxyJump == nil, !agent, !noSession,
      local.isEmpty, remote.isEmpty, dynamic.isEmpty, alias?.localForwards.isEmpty != false,
      alias?.remoteForwards.isEmpty != false, alias?.dynamicForwards.isEmpty != false,
      alias?.forwardAgent != true
    {
      mosh = true
    }
    if mosh, server == "mosh-server", let s = alias?.moshServer {
      server = s
    }
    // as on a computer: no user@ and no User, the one at the keyboard
    guard let who = user ?? login ?? alias?.user ?? localUser else {
      throw SSHError.io("\(name): no user (use user@\(name), or User in ~/.ssh/config)")
    }
    var c = SSHConfig(host: alias?.hostName ?? name, user: who, knownHosts: knownHosts)
    c.port = port ?? alias?.port ?? 22
    c.acceptNewHostKeys = false
    c.environment = ["LANG": "en_US.UTF-8"]
    c.aliveInterval = TimeInterval(max(0, alias?.aliveInterval ?? 0))
    c.aliveCountMax = max(1, alias?.aliveCountMax ?? 3)
    if verbose {
      c.trace = { [weak self] in self?.say("debug: \($0)\r\n") }
    }
    if !mosh {
      // the line's forwards and the config's add up, as in OpenSSH
      c.localForwards = (local + (alias?.localForwards ?? [])).compactMap(SSHConfig.Forward.parse)
      c.remoteForwards = (remote + (alias?.remoteForwards ?? [])).compactMap(
        SSHConfig.Forward.parse)
      c.dynamicForwards = (dynamic + (alias?.dynamicForwards ?? []))
        .compactMap(SSHConfig.Forward.parseDynamic)
      c.forwardAgent = agent || alias?.forwardAgent == true
      c.noSession = noSession
      c.warn = { [weak self] in self?.say("warning: \($0)\r\n") }
    }
    let files = identities + (alias?.identityFiles ?? [])
    var hop: [String]?
    if let h = jump ?? (mosh ? nil : alias?.proxyJump) {
      hop = [h]
      if let colon = h.lastIndex(of: ":") {  // [user@]host:port, as -J spells it
        hop = ["-p", String(h[h.index(after: colon)...]), String(h[..<colon])]
      }
    }
    let noKeys = options.contains {
      let kv = $0.lowercased()
      return kv == "pubkeyauthentication no" || kv == "preferredauthentications password"
    }
    return Target(
      ssh: c, mosh: mosh ? server : nil,
      identities: files.isEmpty
        ? Launcher.defaultIdentities.map { ssh.appendingPathComponent($0) } : files.map(expand),
      identitiesOnly: alias?.identitiesOnly ?? false, noKeys: noKeys, jumpSpec: hop)
  }

  /// The ssh_config keys -o can set here (SSHHosts reads them); the two
  /// that skip the keys go straight to the password.
  static let optionsRead: Set<String> = [
    "hostname", "user", "port", "identityfile", "identitiesonly", "proxyjump",
    "serveraliveinterval", "serveralivecountmax", "localforward", "remoteforward",
    "dynamicforward", "forwardagent", "pubkeyauthentication", "preferredauthentications",
    "mosh", "moshserver",
  ]

  private var knownHosts: KnownHosts {
    KnownHosts(path: ssh.appendingPathComponent("known_hosts").path)
  }

  /// key fetch [-p port] [user@]host:path [name]: the key at path on that
  /// host, and its .pub when there is one, into ~/.ssh under name (the
  /// file's own by default). An existing key is never overwritten.
  private func fetchTarget(_ args: [String]) throws -> Target {
    let usage = SSHError.io("usage: key fetch [-p port] [user@]host:path [name]")
    var rest = args
    var portArgs: [String] = []
    if rest.count >= 2 && rest[0] == "-p" {
      portArgs = Array(rest[0..<2])
      rest.removeFirst(2)
    }
    guard (1...2).contains(rest.count), let colon = rest[0].firstIndex(of: ":") else { throw usage }
    let host = String(rest[0][..<colon])
    let path = String(rest[0][rest[0].index(after: colon)...])
    let name = rest.count == 2 ? rest[1] : URL(fileURLWithPath: path).lastPathComponent
    guard !host.isEmpty, !path.isEmpty, !name.isEmpty, !name.contains("/") else { throw usage }
    guard !FileManager.default.fileExists(atPath: ssh.appendingPathComponent(name).path) else {
      throw SSHError.io(
        "~/.ssh/\(name) exists: give the copy another name (key fetch \(rest[0]) NAME)")
    }
    var t = try parse(portArgs + [host], mosh: false)
    t.fetch = (path, name)
    // the file and its .pub, split by a NUL no key file has
    t.ssh.command =
      "cat -- \(Launcher.quote(path)) && printf '\\000' && cat -- \(Launcher.quote(path + ".pub")) 2>/dev/null"
    return t
  }

  /// ssh-copy-id [-i key] [-p port] [-o opt=value]... [user@]host, as
  /// OpenSSH's: the public key (this device's, or -i's) appended to the
  /// host's ~/.ssh/authorized_keys unless it is there already.
  /// -o PreferredAuthentications=password or PubkeyAuthentication=no
  /// skip the keys and go to the password.
  private func copyIDTarget(_ args: [String]) throws -> Target {
    let usage = SSHError.io("usage: ssh-copy-id [-i key] [-p port] [-o opt=value] [user@]host")
    var identity: String?
    var noKeys = false
    var rest: [String] = []
    var i = 0
    while i < args.count {
      switch args[i] {
      case "-i", "-o", "-p":
        guard i + 1 < args.count else { throw usage }
        let v = args[i + 1]
        if args[i] == "-i" {
          identity = v
        } else if args[i] == "-o" {
          let kv = v.lowercased().split(separator: "=", maxSplits: 1).map(String.init)
          if kv == ["preferredauthentications", "password"]
            || kv == ["pubkeyauthentication", "no"]
          {
            noKeys = true
          }
        } else {
          rest += ["-p", v]
        }
        i += 2
      default:
        rest.append(args[i])
        i += 1
      }
    }
    guard rest.count == 1 || (rest.count == 3 && rest[0] == "-p") else { throw usage }
    var line = try deviceKey().authorizedKey + " fosforo"
    if let identity {
      line = try publicKey(of: expand(identity))
    }
    var t = try parse(rest, mosh: false)
    t.noKeys = noKeys
    t.copyID = line
    let key = Launcher.quote(line)
    t.ssh.command =
      "umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && "
      + "if grep -qxF \(key) ~/.ssh/authorized_keys; then exit 10; fi; "
      + "printf '%s\\n' \(key) >> ~/.ssh/authorized_keys"
    return t
  }

  /// The authorized_keys line for a key file (private, protected or .pub).
  private func publicKey(of url: URL) throws -> String {
    var path = url.path
    if path.hasSuffix(".pub") {
      path.removeLast(4)
    }
    let pubFile = URL(fileURLWithPath: path + ".pub")
    if let pub = try? String(contentsOf: pubFile, encoding: .utf8),
      let line = pub.split(separator: "\n").first,
      line.hasPrefix("ssh-") || line.hasPrefix("ecdsa-")
    {
      return String(line)
    }
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
      throw SSHError.io("\(shown(URL(fileURLWithPath: path))): no such key")
    }
    if let line = Vault.publicLine(text) {
      return line
    }
    return try publicLine(text, URL(fileURLWithPath: path))
  }

  /// key paste NAME: the clipboard's private key into ~/.ssh/NAME, never
  /// over an existing file.
  private func paste(_ name: String) throws {
    guard !name.contains("/"), !name.isEmpty else { throw SSHError.io("key paste: a file name") }
    let dest = ssh.appendingPathComponent(name)
    guard !FileManager.default.fileExists(atPath: dest.path) else {
      throw SSHError.io("\(shown(dest)) exists: paste it under another name")
    }
    guard let text = clipboard?(), PrivateKey.isPrivateKey(text) else {
      throw SSHError.io("key paste: the clipboard holds no private key")
    }
    try makeDirectory(ssh)
    try save(Data(text.utf8), to: dest)
    let state = PrivateKey.isEncrypted(text) ? "with its passphrase" : "in plain text"
    say("saved \(shown(dest)) (\(state)); `key protect \(name)` keeps it encrypted here\r\n")
  }

  /// The shell's user (init.filo's User, or the device's): ssh's default,
  /// as the local login is on a computer.
  public var localUser: String?

  /// What the app's clipboard holds; set by the app (UIKit lives there).
  public var clipboard: (() -> String?)?

  /// A path for the remote shell: ~ stays home, the rest is quoted.
  static func quote(_ path: String) -> String {
    var p = path
    var prefix = ""
    if p.hasPrefix("~/") {
      prefix = "\"$HOME\"/"
      p.removeFirst(2)
    }
    return prefix + "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  /// This device's key, made on first use: in the Secure Enclave when the
  /// hardware has one (the key never leaves it; the file holds an opaque
  /// blob only this device can use), ed25519 in a 0600 file otherwise. A key
  /// already made is kept, whatever kind: servers already trust it.
  func deviceKey() throws -> PrivateKey {
    let ed = deviceDirectory.appendingPathComponent("device_ed25519")
    let se = deviceDirectory.appendingPathComponent("device_p256_se")
    if let seed = try? Data(contentsOf: ed), seed.count == 32 {
      return .ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: seed))
    }
    if let blob = try? Data(contentsOf: se) {
      return .secureEnclave(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob))
    }
    try makeDirectory(deviceDirectory)
    if SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
      try save(key.dataRepresentation, to: se)
      return .secureEnclave(key)
    }
    let key = Curve25519.Signing.PrivateKey()
    try save(key.rawRepresentation, to: ed)
    return .ed25519(key)
  }

  private var deviceDirectory: URL { ssh }

  /// Where the device key lives, for the `key` command.
  var deviceKeyKind: String {
    FileManager.default.fileExists(
      atPath: deviceDirectory.appendingPathComponent("device_p256_se").path)
      ? "Secure Enclave" : "file"
  }

  /// .ssh as ssh wants it (0700) and, on iOS, out of the device's backups:
  /// the keys stay on this device.
  private func makeDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(
      at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    #if os(iOS)
      var u = url
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try u.setResourceValues(values)
    #endif
  }

  private func save(_ data: Data, to url: URL) throws {
    #if os(iOS)
      let options: Data.WritingOptions = [.atomic, .completeFileProtection]
    #else
      let options: Data.WritingOptions = [.atomic]  // no data protection classes on macOS
    #endif
    try data.write(to: url, options: options)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }

  private func answer(_ q: Question, _ text: String) {
    switch q {
    case .hostKey(var t, let jump):
      guard text.lowercased() == "yes" else {
        say("not connecting\r\n")
        finish()
        return
      }
      if jump {
        t.jumpAccepted = true
      } else {
        t.ssh.acceptNewHostKeys = true
      }
      connect(t)
    case .password(var t):
      t.ssh.password = text
      t.ssh.keys = []
      connect(t)
    case .passphrase(let t, let file):
      lock.lock()
      passphrases[file] = text  // empty: skip this key from now on
      lock.unlock()
      connect(t)
    case .reconnect(let t):
      guard text.isEmpty || text.lowercased() == "yes" else {
        finish()
        return
      }
      connect(t)
    case .confirm(let action):
      guard text.lowercased() == "yes" else {
        say("nothing changed\r\n")
        finish()
        return
      }
      action()
    case .newPassphrase(let job, let first):
      guard let first else {
        lock.lock()
        question = .newPassphrase(job, first: text)
        lock.unlock()
        say("Enter same passphrase again: ")
        return
      }
      guard first == text else {
        fail("passphrases do not match; nothing saved")
        finish()
        return
      }
      write(job, passphrase: text)
      finish()
    }
  }

  static let keygenUsage =
    "usage: ssh-keygen -t ed25519|ecdsa [-b 256|384|521] [-f file] [-N passphrase] [-C comment]"

  /// ssh-keygen -t: a new key pair in ~/.ssh, as on a computer; the
  /// passphrase is asked twice when -N does not give it.
  private func keygen(_ args: [String]) {
    var type: String?
    var bits = 256
    var file: String?
    var passphrase: String?
    var comment: String?
    var i = 0
    while i < args.count {
      let flag = args[i]
      guard i + 1 < args.count else {
        fail(Launcher.keygenUsage)
        finish()
        return
      }
      let value = args[i + 1]
      switch flag {
      case "-t": type = value
      case "-b": bits = Int(value) ?? 0
      case "-f": file = value
      case "-N": passphrase = value
      case "-C": comment = value
      default:
        fail(Launcher.keygenUsage)
        finish()
        return
      }
      i += 2
    }
    guard let type, type == "ed25519" || type == "ecdsa" else {
      fail(Launcher.keygenUsage)
      finish()
      return
    }
    if type == "ecdsa" && ![256, 384, 521].contains(bits) {
      fail("ssh-keygen: ecdsa keys take 256, 384 or 521 bits")
      finish()
      return
    }
    let url = expand(file ?? "~/.ssh/id_\(type)")
    if FileManager.default.fileExists(atPath: url.path) {
      fail("\(shown(url)) already exists; nothing saved")
      finish()
      return
    }
    let who = "\(localUser ?? NSUserName())@\(ProcessInfo.processInfo.hostName)"
    let job = Keygen(type: type, bits: bits, file: url, comment: comment ?? who)
    if let passphrase {
      write(job, passphrase: passphrase)
      finish()
      return
    }
    lock.lock()
    question = .newPassphrase(job, first: nil)
    lock.unlock()
    say("Enter passphrase (empty for no passphrase): ")
  }

  private func write(_ job: Keygen, passphrase: String) {
    do {
      let made = try PrivateKey.generate(
        type: job.type, bits: job.bits, comment: job.comment, passphrase: passphrase)
      try makeDirectory(job.file.deletingLastPathComponent())
      try save(Data(made.file.utf8), to: job.file)
      try save(Data(made.pub.utf8), to: URL(fileURLWithPath: job.file.path + ".pub"))
      say(
        "Your identification has been saved in \(shown(job.file))\r\n"
          + "Your public key has been saved in \(shown(job.file)).pub\r\n"
          + made.pub.trimmingCharacters(in: .newlines) + "\r\n")
    } catch {
      fail("ssh-keygen: \(error)")
    }
  }

  private var passphrases: [String: String] = [:]  // key file path → passphrase, memory only

  /// The keys of a target, opened as far as they can be without asking:
  /// a locked key is offered by its public half and asks for its
  /// passphrase only when the server takes it. A locked PEM key with no
  /// .pub has no public half to offer: it is returned to be asked first.
  private func keys(_ t: Target) -> (keys: [PrivateKey], askFirst: URL?) {
    var out: [PrivateKey] = []
    for url in t.identities {
      guard let text = try? String(contentsOf: url, encoding: .utf8),
        PrivateKey.isPrivateKey(text) || Vault.isProtected(text)
      else {
        continue  // a default identity that is not there is the usual case
      }
      lock.lock()
      let pass = passphrases[url.path]
      lock.unlock()
      if pass == "" {
        continue  // skipped with an empty answer
      }
      let pub = try? String(contentsOfFile: url.path + ".pub", encoding: .utf8)
      do {
        if Vault.isProtected(text) {
          guard let vault, let line = Vault.publicLine(text) else {
            throw SSHError.auth("protected for another device; no vault here")
          }
          out.append(
            try PrivateKey.protected(publicLine: line, name: url.path, passphrase: pass) {
              try vault.open(text)
            })
        } else {
          let key = try PrivateKey.deferred(text, pub: pub, name: url.path, passphrase: pass)
          out.append(vault == nil ? key : key.onSign { [weak self] in self?.warnPlain(url) })
        }
      } catch SSHError.locked {
        return (out, url)
      } catch {
        say("\(shown(url)): \(error)\r\n")
        lock.lock()
        passphrases[url.path] = nil  // wrong: ask again
        lock.unlock()
        return (out, url)
      }
    }
    if !t.identitiesOnly, let device = try? deviceKey() {
      out.append(device)
    }
    return (out, nil)
  }

  private var warned: Set<String> = []

  /// Once a session, when a key in plain text is the one used.
  private func warnPlain(_ url: URL) {
    lock.lock()
    let first = warned.insert(url.path).inserted
    lock.unlock()
    if first {
      let name = url.lastPathComponent
      say(
        "note: \(shown(url)) is in plain text on this device; "
          + "`key protect \(name)` keeps it encrypted here\r\n")
    }
  }

  private func keyFiles() -> [URL] { Launcher.keyFiles(in: ssh) }

  private static func keyFiles(in ssh: URL) -> [URL] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: ssh.path)) ?? []
    return names.sorted().map { ssh.appendingPathComponent($0) }.filter { url in
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
      return PrivateKey.isPrivateKey(text) || Vault.isProtected(text)
    }
  }

  /// A private key in ~/.ssh as `key list` shows it.
  public struct KeyInfo: Sendable, Equatable {
    public var name: String
    public var type: String  // "ssh-ed25519"; "?" when the public half is not at hand
    public var state: String  // "protected", "passphrase" or "plain text"
    public var publicLine: String?
  }

  public static func keys(in ssh: URL) -> [KeyInfo] {
    keyFiles(in: ssh).compactMap { url in
      guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
      var pub =
        Vault.publicLine(text) ?? (try? String(contentsOfFile: url.path + ".pub", encoding: .utf8))
      if pub == nil, let k = try? PrivateKey.deferred(text, pub: nil, name: "", passphrase: nil) {
        pub = k.authorizedKey
      }
      let state =
        Vault.isProtected(text)
        ? "protected" : PrivateKey.isEncrypted(text) ? "passphrase" : "plain text"
      return KeyInfo(
        name: url.lastPathComponent,
        type: pub?.split(separator: " ").first.map(String.init) ?? "?", state: state,
        publicLine: pub?.trimmingCharacters(in: .whitespacesAndNewlines))
    }
  }

  private func listKeys() {
    let keys = Launcher.keys(in: ssh)
    if keys.isEmpty {
      say("no keys in ~/.ssh (key fetch brings one; key shows this device's)\r\n")
    }
    let width = (keys.map { $0.name.count }.max() ?? 0) + 2
    for k in keys {
      let short = k.type.replacingOccurrences(of: "ecdsa-sha2-", with: "")  // fits a phone
      say(
        k.name.padding(toLength: width, withPad: " ", startingAt: 0)
          + short.padding(toLength: 13, withPad: " ", startingAt: 0) + k.state + "\r\n")
    }
  }

  /// The public line for a key file about to be protected: from the key
  /// itself, its OpenSSH container, or its .pub.
  private func publicLine(_ text: String, _ url: URL) throws -> String {
    if !PrivateKey.isEncrypted(text) {
      return try PrivateKey.load(text).authorizedKey
    }
    let pub = try? String(contentsOfFile: url.path + ".pub", encoding: .utf8)
    do {
      return try PrivateKey.deferred(text, pub: pub, name: url.path, passphrase: nil).authorizedKey
    } catch {
      throw SSHError.io("\(shown(url)): a PEM key with a passphrase needs its .pub beside it")
    }
  }

  private func protect(_ name: String) throws {
    guard let vault else { throw SSHError.io("key protect: only on iPad and iPhone") }
    let url = ssh.appendingPathComponent(name)
    guard let text = try? String(contentsOf: url, encoding: .utf8), PrivateKey.isPrivateKey(text)
    else {
      throw SSHError.io("\(shown(url)): not a private key in plain form")
    }
    let line = try publicLine(text, url)
    lock.lock()
    question = .confirm { [weak self] in
      guard let self else { return }
      do {
        let note =
          "encrypted by fosforo for this device's Secure Enclave; it cannot be opened "
          + "elsewhere. In fosforo, key unprotect \(name) writes the original back."
        let sealed = try vault.protect(text, publicKey: line, note: note)
        try self.save(Data(sealed.utf8), to: url)
        self.say("protected \(self.shown(url))\r\n")
        if vault.withoutPresence {
          self.say(
            "this device has no passcode: the key is bound to it, but nothing asks for you\r\n")
        }
      } catch {
        self.fail("\(error)")
      }
      self.finish()
    }
    lock.unlock()
    say(
      "protect \(shown(url))? It is encrypted in place for this device only;\r\n"
        + "`key unprotect \(name)` restores it. If fosforo is deleted, the protected\r\n"
        + "file cannot be opened: keep the original elsewhere if you may need it.\r\n"
        + "(yes/no) ")
  }

  /// ssh-keygen -R host: the host's lines in known_hosts go, asked first;
  /// the file as it was stays in known_hosts.old, as OpenSSH leaves it.
  private func forget(_ args: [String]) {
    guard args.count == 2, args[0] == "-R" else {
      fail(
        "usage: ssh-keygen -R host (or [host]:port); "
          + Launcher.keygenUsage.dropFirst("usage: ".count))
      finish()
      return
    }
    var host = args[1]
    var port = 22
    if host.hasPrefix("["), let end = host.firstIndex(of: "]") {
      port = Int(host[host.index(after: end)...].dropFirst()) ?? 22
      host = String(host[host.index(after: host.startIndex)..<end])
    }
    let kh = knownHosts
    let name = KnownHosts.name(host: host, port: port)
    let shownPath = shown(URL(fileURLWithPath: kh.path))
    lock.lock()
    question = .confirm { [weak self] in
      guard let self else { return }
      do {
        let n = try kh.remove(host: host, port: port)
        if n == 0 {
          self.fail("\(name) is not in \(shownPath)")
        } else {
          self.say("removed \(n) line\(n == 1 ? "" : "s"); the old file is \(shownPath).old\r\n")
        }
      } catch {
        self.fail("\(error)")
      }
      self.finish()
    }
    lock.unlock()
    say("forget the host key of \(name) in \(shownPath)? (yes/no) ")
  }

  private func unprotect(_ name: String) throws {
    guard let vault else { throw SSHError.io("key unprotect: only on iPad and iPhone") }
    let url = ssh.appendingPathComponent(name)
    guard let text = try? String(contentsOf: url, encoding: .utf8), Vault.isProtected(text) else {
      throw SSHError.io("\(shown(url)): not a protected key")
    }
    lock.lock()
    question = .confirm { [weak self] in
      guard let self else { return }
      // off the main thread: opening may wait for Face ID
      Thread.detachNewThread { [self] in
        do {
          let original = try vault.open(text)
          try self.save(Data(original.utf8), to: url)
          self.say("\(self.shown(url)) is in plain text again\r\n")
        } catch {
          self.fail("\(error)")
        }
        self.finish()
      }
    }
    lock.unlock()
    say("write \(shown(url)) back in plain text? (yes/no) ")
  }

  private func askPassphrase(_ t: Target, _ path: String) {
    lock.lock()
    question = .passphrase(t, path)
    connecting = false
    typeahead.removeAll()
    lock.unlock()
    say("passphrase for \(shown(URL(fileURLWithPath: path))) (empty to skip): ")
  }

  /// Set while the hop of a ProxyJump is being made: its failure, not the
  /// target's, is what failed() then reports.
  private var viaJump = false

  // MARK: - shared connections (ControlMaster)

  /// Live connections by user@host:port, shared by every launcher in the
  /// process: a second ssh to the same host opens a session on the one
  /// there is, with no TCP, key exchange or authentication again. The
  /// connection ends with its last session, as OpenSSH without
  /// ControlPersist; a connection lost takes every window on it.
  private static let mastersLock = NSLock()
  nonisolated(unsafe) private static var masters: [String: SSHClient] = [:]  // under mastersLock

  private static func key(_ c: SSHConfig) -> String { "\(c.user)@\(c.host):\(c.port)" }

  static func master(for c: SSHConfig) -> SSHClient? {
    mastersLock.lock()
    defer { mastersLock.unlock() }
    let k = key(c)
    if let m = masters[k], m.alive {
      return m
    }
    masters[k] = nil
    return nil
  }

  private static func remember(_ client: SSHClient, for c: SSHConfig) {
    mastersLock.lock()
    masters[key(c)] = client
    mastersLock.unlock()
  }

  /// Connections alive and shared right now.
  public static var sharedConnections: Int {
    mastersLock.lock()
    defer { mastersLock.unlock() }
    return masters.values.filter(\.alive).count
  }

  /// Those to one port: tests run side by side, each with its own server.
  static func sharedConnections(port: Int) -> Int {
    mastersLock.lock()
    defer { mastersLock.unlock() }
    return masters.filter { $0.key.hasSuffix(":\(port)") && $0.value.alive }.count
  }

  /// A plain ssh: the kind a shared connection serves. Forwards and the
  /// agent belong to a connection: one that asks for them gets its own.
  private func plain(_ t: Target) -> Bool {
    t.mosh == nil && t.fetch == nil && t.copyID == nil && t.jump == nil && t.jumpSpec == nil
      && t.ssh.localForwards.isEmpty && t.ssh.remoteForwards.isEmpty
      && t.ssh.dynamicForwards.isEmpty
      && !t.ssh.forwardAgent
      && !t.ssh.noSession
  }

  private func connect(_ target: Target) {
    var t = target
    if let spec = t.jumpSpec {
      do {
        var hop = try parse(spec, mosh: false)
        // a hop only carries the tunnel to the target (OpenSSH's ssh -W)
        hop.ssh.localForwards = []
        hop.ssh.remoteForwards = []
        hop.ssh.dynamicForwards = []
        hop.ssh.forwardAgent = false
        hop.ssh.noSession = false
        let found = keys(hop)
        if let file = found.askFirst {
          askPassphrase(t, file.path)
          return
        }
        hop.ssh.keys = found.keys
        hop.ssh.acceptNewHostKeys = t.jumpAccepted
        hop.ssh.trace = t.ssh.trace
        hop.ssh.tunnel = SSHConfig.Tunnel(host: t.ssh.host, port: t.ssh.port)
        t.jump = hop.ssh
      } catch {
        fail("\(spec.last ?? "jump"): \(error)")
        finish()
        return
      }
    }
    // a shared connection is authenticated already: no keys to load; a
    // password answer means the keys were not taken
    let shared = plain(t) && Launcher.master(for: t.ssh) != nil
    if t.ssh.password == nil && !t.noKeys && !shared {
      let loading = Date()
      let found = keys(t)
      t.ssh.trace?(
        "\(found.keys.count) keys loaded in \(Int(Date().timeIntervalSince(loading) * 1000)) ms")
      if let file = found.askFirst {
        askPassphrase(t, file.path)
        return
      }
      t.ssh.keys = found.keys
    }
    lock.lock()
    t.ssh.rows = rows
    t.ssh.cols = cols
    connecting = true
    let mine = attempt
    lock.unlock()
    if !shared {
      say("connecting to \(t.ssh.host)\(t.mosh == nil ? "" : " (mosh)")…\r\n")
    }
    let job = t
    Thread.detachNewThread { [self] in
      do {
        if let session = try open(job, mine) {
          attach(session, job, mine)
        } else {
          lock.lock()
          let still = current(mine)
          if still {
            connecting = false
            typeahead.removeAll()
          }
          lock.unlock()
          if still {
            finish()
          }
        }
      } catch let e as SSHError {
        holdBeforeFailing?()
        failed(job, e, mine)
      } catch {
        holdBeforeFailing?()
        failed(job, .io("\(error)"), mine)
      }
    }
  }

  /// Whether `mine` is still the command running, and it is still wanted:
  /// a connect thread that outlived its command touches nothing. Under the
  /// lock.
  private func current(_ mine: Int) -> Bool {
    attempt == mine && !cancelled && !closed
  }

  /// say() for an attempt: silent once the command is over.
  private func tell(_ mine: Int, _ s: String) {
    lock.lock()
    let ok = current(mine)
    lock.unlock()
    if ok {
      say(s)
    }
  }

  /// The session to attach, or nil when the job was done here (a fetch,
  /// a copied id).
  private func open(_ t: Target, _ mine: Int) throws -> Transport? {
    if let f = t.fetch {
      try fetch(t, path: f.path, name: f.name, mine)
      return nil
    }
    if let line = t.copyID {
      let (status, _) = try execute(t, mine)
      let fields = line.split(separator: " ")
      let what = fields.count > 2 ? fields[2...].joined(separator: " ") : String(fields[0])
      switch status {
      case 0: tell(mine, "added \(what) to \(t.ssh.user)@\(t.ssh.host):~/.ssh/authorized_keys\r\n")
      case 10: tell(mine, "\(what) was already in \(t.ssh.host)'s authorized_keys\r\n")
      default: tell(mine, "ssh-copy-id: the host answered with status \(status)\r\n")
      }
      return nil
    }
    if let server = t.mosh {
      let ep = try MoshTransport.bootstrap(ssh: t.ssh, server: server) { [self] in
        try pending($0, mine)
      }
      return try MoshTransport(endpoint: ep, rows: t.ssh.rows, cols: t.ssh.cols)
    }
    if plain(t), let master = Launcher.master(for: t.ssh) {
      t.ssh.trace?("session on the connection already made to \(t.ssh.host)")
      do {
        let ch = try master.openSession(
          rows: t.ssh.rows, cols: t.ssh.cols, environment: t.ssh.environment)
        return SSHTransport(channel: ch, client: master)
      } catch let e as SSHError {
        throw SSHError.io("the shared connection to \(t.ssh.host) ended (\(e)); try again")
      }
    }
    let client = SSHClient(config: t.ssh)
    client.onBanner = { [weak self] text in
      self?.tell(mine, text.replacingOccurrences(of: "\n", with: "\r\n"))
    }
    try connected(client, t, mine)
    if t.ssh.noSession {
      let ports = (t.ssh.localForwards + t.ssh.remoteForwards + t.ssh.dynamicForwards)
        .map { String($0.bindPort) }
      tell(mine, "forwarding \(ports.joined(separator: ", ")) (Ctrl-C ends it)\r\n")
      return ForwardTransport(client: client)
    }
    if plain(t) {
      Launcher.remember(client, for: t.ssh)
    }
    return SSHTransport(client: client)
  }

  /// connect() for the target: straight, or through the jump host first,
  /// whose tunnel to the target is then the connection.
  private func connected(_ client: SSHClient, _ t: Target, _ mine: Int) throws {
    guard let jump = t.jump else {
      try pending(client, mine)
      try client.connect()
      return
    }
    let hop = SSHClient(config: jump)
    hop.onBanner = { [weak self] text in
      self?.tell(mine, text.replacingOccurrences(of: "\n", with: "\r\n"))
    }
    let fd: Int32
    lock.lock()
    viaJump = true
    lock.unlock()
    do {
      try pending(hop, mine)
      try hop.connect()
      tell(mine, "through \(jump.host): tunnel to \(t.ssh.host) port \(t.ssh.port)\r\n")
      fd = try hop.tunnelSocket()
    } catch {
      hop.close()
      throw error  // viaJump stays set for failed() to read
    }
    lock.lock()
    viaJump = false
    lock.unlock()
    do {
      try pending(client, mine)
      try client.connect(over: fd)
    } catch {
      Darwin.close(fd)  // ends the hop's pump, which closes its channel
      throw error
    }
  }

  /// Runs the target's command and waits: its exit status and output.
  private func execute(_ t: Target, _ mine: Int) throws -> (Int32, [UInt8]) {
    let client = SSHClient(config: t.ssh)
    let box = Collector()
    client.onData = { box.append($0) }
    client.onClose = { status, _ in box.finish(status) }
    try connected(client, t, mine)
    client.start()
    guard box.wait(seconds: t.ssh.timeout * 4) else {
      client.close()
      throw SSHError.io("\(t.ssh.host) did not finish")
    }
    return (box.status ?? -1, box.data)
  }

  private func fetch(_ t: Target, path: String, name: String, _ mine: Int) throws {
    let (status, data) = try execute(t, mine)
    let parts = data.split(separator: 0, maxSplits: 1, omittingEmptySubsequences: false)
    let key = String(decoding: parts[0], as: UTF8.self)
    guard status == 0, PrivateKey.isPrivateKey(key) else {
      throw SSHError.io("key fetch: \(path) on \(t.ssh.host) is not a private key we read")
    }
    try makeDirectory(ssh)
    let dest = ssh.appendingPathComponent(name)
    try save(Data(parts[0]), to: dest)
    var also = ""
    if parts.count == 2, String(decoding: parts[1], as: UTF8.self).hasPrefix("ssh-") {
      try Data(parts[1]).write(to: URL(fileURLWithPath: dest.path + ".pub"), options: .atomic)
      also = " and its .pub"
    }
    let locked = PrivateKey.isEncrypted(key) ? "with its passphrase" : "in plain text, as it was"
    tell(mine, "saved \(shown(dest))\(also) (\(locked))\r\n")
  }

  /// What a fetch brings back: the remote command's output and status.
  /// The question is set before typing is let through again (both under
  /// the lock): the next line the user enters is its answer.
  private func failed(_ t: Target, _ e: SSHError, _ mine: Int) {
    lock.lock()
    let still = current(mine)
    if still {
      cancelConnect = nil
    }
    lock.unlock()
    if !still {
      return  // interrupt() answered the shell already, or another command is on
    }
    if case .locked(let path) = e {
      askPassphrase(t, path)
      return
    }
    let c = t.ssh
    lock.lock()
    let viaJump = viaJump
    self.viaJump = false
    lock.unlock()
    var ask: Question?
    var text = "\(e)\r\n"
    switch e {
    case .hostKeyChanged(let name, let fp, let file, let line):
      let quoted = name.hasPrefix("[") ? "'\(name)'" : name  // brackets are a glob to a shell
      text =
        "WARNING: \(name) presented a different host key: \(fp)\r\n"
        + "The one on record is at \(shown(URL(fileURLWithPath: file))) line \(line).\r\n"
        + "Someone may be in the middle, or the host was reinstalled.\r\n"
        + "If the change is expected: ssh-keygen -R \(quoted), then connect again.\r\n"
    case .hostKey(let msg) where msg.hasPrefix("unknown host"):
      ask = .hostKey(t, jump: viaJump)
      text = "\(msg)\(viaJump ? " (the jump host)" : "")\r\naccept and remember it? (yes/no) "
    case .auth(let msg) where viaJump:
      text = "\(t.jump?.host ?? "jump host"): \(msg) (the jump host takes keys only)\r\n"
    case .auth(let msg)
    where c.password == nil
      && (msg.contains("password") || msg.contains("keyboard-interactive")):
      ask = .password(t)
      text = "\(c.user)@\(c.host)'s password: "
    default:
      break
    }
    lock.lock()
    question = ask
    connecting = false
    typeahead.removeAll()  // it was meant for a session that never opened
    lock.unlock()
    say(text)
    if ask == nil {
      lock.lock()
      status = 1
      lock.unlock()
      finish()
    }
  }

  /// A shell exiting ends it; a lost connection (network, server gone)
  /// says why and offers the same connection again.
  private var remoteLabel: String?

  /// The connection the terminal is on, for the status bar.
  public var label: String? {
    lock.lock()
    defer { lock.unlock() }
    return remote == nil ? nil : remoteLabel
  }

  private func attach(_ remote: Transport, _ t: Target, _ mine: Int) {
    lock.lock()
    if !current(mine) {  // it connected after Ctrl+C, the window closing or another command
      lock.unlock()
      remote.hangup()
      return
    }
    cancelConnect = nil
    let out = output
    self.remote = remote
    remoteLabel = "\(t.mosh == nil ? "ssh" : "mosh") \(t.ssh.user)@\(t.ssh.host)"
    connecting = false
    let early = typeahead
    typeahead.removeAll()
    lock.unlock()
    remote.start(
      output: { bytes in out?(bytes) },
      exit: { [weak self] st in
        guard let self else { return }
        let lost = (remote as? SSHTransport)?.failure ?? (remote as? ForwardTransport)?.failure
        self.lock.lock()
        self.remote = nil
        self.status = st
        if lost != nil {
          self.question = .reconnect(t)
        }
        self.lock.unlock()
        if let lost {
          self.say(
            "\r\n\u{1b}[1m[connection lost: \(lost)]\u{1b}[0m\r\nreconnect? (yes/no, Enter: yes) ")
          return
        }
        self.say("\r\n[connection closed]\r\n")
        self.finish()
      })
    if !early.isEmpty {
      remote.send(early)
    }
  }

  public func resize(rows: Int, cols: Int) {
    lock.lock()
    self.rows = rows
    self.cols = cols
    let r = remote
    lock.unlock()
    r?.resize(rows: rows, cols: cols)
  }

  /// The window closed: the connection goes, and so does one still being
  /// made; a late success finds no one to attach to.
  public func hangup() {
    lock.lock()
    closed = true
    let r = remote
    let c = cancelConnect
    cancelConnect = nil
    lock.unlock()
    c?()
    r?.hangup()
  }

  /// Ctrl+C while connecting: the attempt is dropped at once and the shell
  /// gets 130, as when ssh is interrupted.
  private func interrupt() {
    lock.lock()
    cancelled = true
    connecting = false
    typeahead.removeAll()
    status = 130
    let c = cancelConnect
    cancelConnect = nil
    lock.unlock()
    c?()
    say("^C\r\n")
    finish()
  }

  /// The client a connect goes through, so interrupt() and hangup() can
  /// stop it; refused when they already happened.
  private func pending(_ client: SSHClient, _ mine: Int) throws {
    lock.lock()
    defer { lock.unlock() }
    guard current(mine) else { throw SSHError.io("cancelled") }
    cancelConnect = { client.cancel() }
  }

  public func overlay(_ screen: inout Screen) {
    lock.lock()
    let r = remote
    lock.unlock()
    r?.overlay(&screen)
  }

  public var overlayGeneration: UInt64 {
    lock.lock()
    let r = remote
    lock.unlock()
    return r?.overlayGeneration ?? 0
  }
}
