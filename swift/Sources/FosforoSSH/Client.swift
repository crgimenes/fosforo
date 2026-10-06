import CryptoKit
import Foundation

public struct SSHConfig: Sendable {
  public var host: String
  public var port = 22
  public var user: String
  public var keys: [PrivateKey] = []
  public var password: String?
  public var term = "xterm-256color"
  public var cols = 80
  public var rows = 24
  /// nil opens a login shell; otherwise the command runs instead.
  public var command: String?
  public var environment: [String: String] = [:]
  public var knownHosts: KnownHosts
  /// Trust on first use. An unknown key is refused when false; a changed
  /// key is always refused.
  public var acceptNewHostKeys = true
  public var timeout: TimeInterval = 15
  /// ServerAliveInterval: seconds of silence before asking the server if
  /// it is there; 0 never asks. ServerAliveCountMax questions unanswered
  /// and the connection is taken for dead.
  public var aliveInterval: TimeInterval = 0
  public var aliveCountMax = 3
  /// ssh -v: each step of connect, as it happens.
  public var trace: (@Sendable (String) -> Void)?
  /// Instead of a session: a direct-tcpip channel to this host and port
  /// (how ssh -J reaches the target through the jump host); the channel's
  /// bytes are then the connection, see tunnelSocket().
  public var tunnel: Tunnel?
  /// -L: ports here that reach host:port from the server's side.
  public var localForwards: [Forward] = []
  /// -R: ports on the server that reach host:port from this side.
  public var remoteForwards: [Forward] = []
  /// -D: ports here that are a SOCKS proxy through the server (host and
  /// port unused: each connection names its own).
  public var dynamicForwards: [Forward] = []
  /// -A: the server may ask this side to sign with keys (the agent's
  /// protocol); a key never leaves the device.
  public var forwardAgent = false
  /// -N: no session; the connection carries the forwards until it is closed.
  public var noSession = false
  /// A forward that could not be made, or a connection through one that
  /// failed: said, and the connection goes on (as OpenSSH warns).
  public var warn: (@Sendable (String) -> Void)?

  /// A forwarded port: connections to bindHost:bindPort on one side go to
  /// host:port from the other. bindHost "" is every interface.
  public struct Forward: Sendable, Equatable {
    public var bindHost: String
    public var bindPort: Int
    public var host: String
    public var port: Int

    public init(bindHost: String = "127.0.0.1", bindPort: Int, host: String, port: Int) {
      self.bindHost = bindHost
      self.bindPort = bindPort
      self.host = host
      self.port = port
    }

    /// [bind_address:]port:host:hostport as ssh -L and -R take it; an IPv6
    /// address in brackets. A bind address of * or nothing is every
    /// interface; none at all, the loopback.
    public static func parse(_ spec: String) -> Forward? {
      var parts: [String] = []
      var cur = ""
      var bracket = false
      for c in spec {
        if c == "[" {
          bracket = true
        } else if c == "]" {
          bracket = false
        } else if c == ":" && !bracket {
          parts.append(cur)
          cur = ""
        } else {
          cur.append(c)
        }
      }
      parts.append(cur)
      guard parts.count == 3 || parts.count == 4 else { return nil }
      let bind = parts.count == 4 ? (parts[0] == "*" ? "" : parts[0]) : "127.0.0.1"
      let rest = parts.suffix(3).map { $0 }
      guard let bp = Int(rest[0]), (1...65535).contains(bp), let hp = Int(rest[2]),
        (1...65535).contains(hp), !rest[1].isEmpty
      else { return nil }
      return Forward(bindHost: bind, bindPort: bp, host: rest[1], port: hp)
    }

    /// [bind_address:]port as ssh -D takes it.
    public static func parseDynamic(_ spec: String) -> Forward? {
      var bind = "127.0.0.1"
      var port = spec
      if let colon = spec.lastIndex(of: ":") {
        bind = String(spec[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        bind = bind == "*" ? "" : bind
        port = String(spec[spec.index(after: colon)...])
      }
      guard let p = Int(port), (1...65535).contains(p) else { return nil }
      return Forward(bindHost: bind, bindPort: p, host: "", port: 0)
    }
  }

  public struct Tunnel: Sendable {
    public var host: String
    public var port: Int
    public init(host: String, port: Int) {
      self.host = host
      self.port = port
    }
  }

  public init(host: String, user: String, knownHosts: KnownHosts) {
    self.host = host
    self.user = user
    self.knownHosts = knownHosts
  }
}

/// One SSH connection with one interactive session channel. connect()
/// blocks (run it off the main thread); start() then reads on a thread of
/// its own and reports through the callbacks.
public final class SSHClient: @unchecked Sendable {
  static let version = "SSH-2.0-fosforo_0.1"
  static let window: UInt32 = 2 * 1024 * 1024
  static let maxPacket: UInt32 = 32768

  let config: SSHConfig
  private var io: PacketIO?
  fileprivate let lock = NSLock()  // packet writes, the channels and the state below
  private var serverVersion = ""
  private var sessionID: [UInt8] = []
  private var hostKey: [UInt8] = []
  private var strict = false
  fileprivate var kexActive = false
  fileprivate var channels: [UInt32: SSHChannel] = [:]
  private var nextID: UInt32 = 0
  private var main: SSHChannel?  // the first channel: what the client's own callbacks speak for
  private var cancelled = false  // cancel() or close() before the session was open
  fileprivate var failed: SSHError?  // the connection is over, for this reason
  private var ended = false  // the last channel closed: the connection was shut by us
  private var heard = Date()  // the last packet from the server
  private var unanswered = 0
  private var silent: SSHError?  // why the keepalive gave up
  /// The server's numeric address as connected (Mosh sends its UDP there).
  public private(set) var peerAddress: String?
  private(set) var exchanges = 0  // key exchanges done, the first included
  private var listeners: [Int32] = []  // -L sockets, closed with the connection
  private var globalAsks: [GlobalAsk?] = []  // replies come in order; nil: one nobody waits for
  /// Once the connection is over (a -N connection has no channel to say it).
  public var onEnd: (@Sendable (SSHError?) -> Void)?
  private(set) var negotiatedKex = ""

  /// Output of the remote side (stdout and stderr), on the reader thread.
  public var onData: (@Sendable ([UInt8]) -> Void)?
  /// Once, on the reader thread: the exit status when the remote side
  /// reported one, and the error when the connection broke instead.
  public var onClose: (@Sendable (Int32?, SSHError?) -> Void)?
  /// The server's EOF on the channel: a tunnel's far end hung up, nothing
  /// more will come (the close follows once we close too).
  var onEOF: (@Sendable () -> Void)?
  /// Pre-authentication banner text, when the server sends one.
  public var onBanner: (@Sendable (String) -> Void)?

  public init(config: SSHConfig) {
    self.config = config
  }

  private var conn: PacketIO {
    get throws {
      guard let io else { throw SSHError.io("not connected") }
      return io
    }
  }

  fileprivate func writeLocked(_ payload: [UInt8]) throws {
    try conn.writePacket(payload)
  }

  private func write(_ payload: [UInt8]) throws {
    lock.lock()
    defer { lock.unlock() }
    try writeLocked(payload)
  }

  // MARK: - connect

  private let began = Date()

  private func note(_ s: String) {
    config.trace?("\(Int(Date().timeIntervalSince(began) * 1000)) ms: \(s)")
  }

  /// Under config.timeout as a whole, TCP to the open session; cancel() or
  /// close() from another thread makes it throw at once.
  public func connect() throws {
    let fd = try dial(
      host: config.host, port: config.port, timeout: config.timeout,
      trace: config.trace == nil ? nil : { [self] in note($0) },
      cancelled: { [self] in
        lock.lock()
        defer { lock.unlock() }
        return cancelled
      })
    try connect(over: fd)
  }

  /// The protocol over a connection already made: the end of another
  /// client's tunnel (ProxyJump), or any socket to the host.
  public func connect(over fd: Int32) throws {
    let io = PacketIO(fd: fd)
    io.deadline = Date().addingTimeInterval(config.timeout)  // the negotiation, not only TCP
    lock.lock()
    self.io = io
    let dropped = cancelled
    lock.unlock()
    if dropped {
      io.shutdown()
      throw SSHError.io("cancelled")
    }
    peerAddress = config.tunnel == nil ? numericPeer(fd) : nil
    note("connected to \(peerAddress ?? config.host) port \(config.port)")
    try conn.writeAll(Array((SSHClient.version + "\r\n").utf8))
    serverVersion = try conn.readVersion()
    note("server \(serverVersion)")
    guard serverVersion.hasPrefix("SSH-2.0-") || serverVersion.hasPrefix("SSH-1.99-") else {
      throw SSHError.unsupported("protocol \(serverVersion)")
    }
    try keyExchange(serverKexinit: nil)
    note("key exchange done (\(negotiatedKex))")
    try authenticate()
    note("authenticated as \(config.user)")
    // from here the reader owns the socket: channels open through it
    let reader = Thread { [self] in run() }
    reader.name = "fosforo.ssh.reader"
    reader.start()
    if config.aliveInterval > 0 {
      let k = Thread { [self] in keepalive() }
      k.name = "fosforo.ssh.keepalive"
      k.start()
    }
    for f in config.remoteForwards {
      do {
        try forwardRemote(f)
        note("remote forward \(f.bindPort) to \(f.host):\(f.port)")
      } catch {
        config.warn?("remote port forwarding failed for listen port \(f.bindPort): \(error)")
      }
    }
    for f in config.localForwards + config.dynamicForwards {
      do {
        try forwardLocal(f)
        note("local forward \(f.bindPort) to \(f.port == 0 ? "SOCKS" : "\(f.host):\(f.port)")")
      } catch {
        config.warn?("could not listen on port \(f.bindPort): \(error)")
      }
    }
    if config.noSession {
      io.deadline = nil
      note("no session: forwarding")
      return
    }
    let first: SSHChannel
    if let t = config.tunnel {
      first = try openTunnel(host: t.host, port: t.port)
    } else {
      first = try openSession(
        rows: config.rows, cols: config.cols, command: config.command,
        environment: config.environment, agent: config.forwardAgent)
    }
    first.onData = { [weak self] in self?.onData?($0) }
    first.onEOF = { [weak self] in self?.onEOF?() }
    first.onClose = { [weak self] in self?.onClose?($0, $1) }
    io.deadline = nil  // from here the keepalive, if any, watches the silence
    lock.lock()
    main = first
    lock.unlock()
    note(config.tunnel == nil ? "session open" : "tunnel open")
  }

  /// The first channel (config.tunnel) as a socket: see SSHChannel.socket().
  public func tunnelSocket() throws -> Int32 {
    guard let main else { throw SSHError.io("not connected") }
    return try main.socket()
  }

  /// Channels open on this connection; 0 once the last closed.
  public var channelCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return channels.count
  }

  /// Connected and not over: more channels may be opened on it.
  public var alive: Bool {
    lock.lock()
    defer { lock.unlock() }
    return (main != nil || config.noSession) && failed == nil && !ended
      && (config.noSession || !channels.isEmpty)
  }

  /// Whether this connection carries forwards: they end with its session.
  private var forwards: Bool {
    !config.localForwards.isEmpty || !config.remoteForwards.isEmpty
      || !config.dynamicForwards.isEmpty || config.forwardAgent
  }

  /// Ends the connection now, every channel and forward with it.
  public func disconnect() {
    lock.lock()
    ended = true
    let io = io
    lock.unlock()
    io?.shutdown()
  }

  /// Stops a connect() in progress, from another thread: it throws at once
  /// and nothing of it is kept.
  public func cancel() {
    lock.lock()
    cancelled = true
    let io = io
    lock.unlock()
    io?.shutdown()
  }

  /// Reads the next packet that is not transport noise.
  private func next() throws -> [UInt8] {
    while true {
      let p = try conn.readPacket()
      guard let t = p.first else { throw SSHError.protocolError("empty packet") }
      switch t {
      case Msg.ignore, Msg.debug, Msg.unimplemented:
        continue
      case Msg.disconnect:
        var r = SSHReader(p)
        _ = try r.byte()
        _ = try r.u32()
        throw SSHError.disconnected(try r.text())
      default:
        return p
      }
    }
  }

  // MARK: - key exchange (RFC 4253 section 7, RFC 8731, strict kex)

  /// Post-quantum hybrid first where CryptoKit has ML-KEM (OpenSSH 10's
  /// default too); curve25519 everywhere.
  private static let kexAlgorithms: [String] = {
    var list = [
      "curve25519-sha256", "curve25519-sha256@libssh.org", "ext-info-c",
      "kex-strict-c-v00@openssh.com",
    ]
    if #available(macOS 26, iOS 26, *) {
      list.insert("mlkem768x25519-sha256", at: 0)
    }
    return list
  }()

  /// The client's half of a key agreement: its public value, and from the
  /// server's, the shared secret K already encoded the way the exchange
  /// hash and the key derivation take it.
  private struct Agreement {
    let clientPublic: [UInt8]
    let finish: ([UInt8]) throws -> [UInt8]
  }

  private static func x25519(_ key: Curve25519.KeyAgreement.PrivateKey, _ peer: [UInt8]) throws
    -> [UInt8]
  {
    guard peer.count == 32 else { throw SSHError.protocolError("bad curve25519 public key") }
    let shared = try key.sharedSecretFromKeyAgreement(
      with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: peer))
    let k = shared.withUnsafeBytes { Array($0) }
    guard k.contains(where: { $0 != 0 }) else {
      throw SSHError.protocolError("degenerate shared secret")
    }
    return k
  }

  private static func agreement(_ name: String) throws -> Agreement {
    let x = Curve25519.KeyAgreement.PrivateKey()
    if name == "mlkem768x25519-sha256", #available(macOS 26, iOS 26, *) {
      // K = SHA256(ML-KEM secret || X25519 secret), as a string (OpenSSH
      // kexmlkem768x25519.c); the public values are concatenated likewise.
      let kem = try MLKEM768.PrivateKey()
      return Agreement(
        clientPublic: Array(kem.publicKey.rawRepresentation) + Array(x.publicKey.rawRepresentation)
      ) { reply in
        let ctLen = 1088
        guard reply.count == ctLen + 32 else {
          throw SSHError.protocolError("bad mlkem768x25519 reply")
        }
        let secret = try kem.decapsulate(reply[0..<ctLen])
        var both = secret.withUnsafeBytes { Array($0) }
        both += try x25519(x, Array(reply[ctLen...]))
        var w = SSHWriter()
        w.string(Array(SHA256.hash(data: both)))
        return w.bytes
      }
    }
    return Agreement(clientPublic: Array(x.publicKey.rawRepresentation)) { reply in
      var w = SSHWriter()
      w.mpint(try x25519(x, reply))
      return w.bytes
    }
  }
  private static let hostKeyAlgorithms = [
    "ssh-ed25519", "ecdsa-sha2-nistp256", "rsa-sha2-512", "rsa-sha2-256",
  ]
  private static let ciphers = ["aes256-gcm@openssh.com", "aes128-gcm@openssh.com"]
  private static let macs = ["hmac-sha2-256-etm@openssh.com", "hmac-sha2-256"]

  private func kexinit() -> [UInt8] {
    var w = SSHWriter(message: Msg.kexinit)
    var cookie = [UInt8](repeating: 0, count: 16)
    _ = SecRandomCopyBytes(kSecRandomDefault, 16, &cookie)
    w.bytes += cookie
    w.nameList(SSHClient.kexAlgorithms)
    w.nameList(SSHClient.hostKeyAlgorithms)
    w.nameList(SSHClient.ciphers)
    w.nameList(SSHClient.ciphers)
    w.nameList(SSHClient.macs)
    w.nameList(SSHClient.macs)
    w.nameList(["none"])
    w.nameList(["none"])
    w.nameList([])
    w.nameList([])
    w.bool(false)
    w.u32(0)
    return w.bytes
  }

  private static func choose(_ ours: [String], _ theirs: [String], _ what: String) throws -> String
  {
    guard
      let c = ours.first(where: {
        theirs.contains($0) && !$0.hasPrefix("kex-strict") && $0 != "ext-info-c"
      })
    else {
      throw SSHError.unsupported(
        "no common \(what): server offers \(theirs.joined(separator: ","))")
    }
    return c
  }

  private func keyExchange(serverKexinit: [UInt8]?) throws {
    let initial = sessionID.isEmpty
    let ours = kexinit()
    lock.lock()
    kexActive = true
    do {
      try writeLocked(ours)
    } catch {
      lock.unlock()
      throw error
    }
    lock.unlock()
    var theirs = serverKexinit
    if theirs == nil {
      let p = try next()
      guard p.first == Msg.kexinit else {
        throw SSHError.protocolError("expected KEXINIT, got message \(p.first ?? 0)")
      }
      theirs = p
    }
    guard let serverInit = theirs else { throw SSHError.protocolError("no KEXINIT") }
    var r = SSHReader(serverInit)
    _ = try r.byte()
    for _ in 0..<16 { _ = try r.byte() }
    let kexList = try r.nameList()
    let hostKeyList = try r.nameList()
    let cipherCS = try r.nameList()
    let cipherSC = try r.nameList()
    if initial {
      strict = kexList.contains("kex-strict-s-v00@openssh.com")
      if strict && (try? conn.recvSeq) != 1 {
        throw SSHError.protocolError("strict kex: KEXINIT was not the first packet")
      }
    }
    let kex = try SSHClient.choose(SSHClient.kexAlgorithms, kexList, "key exchange")
    _ = try SSHClient.choose(SSHClient.hostKeyAlgorithms, hostKeyList, "host key type")
    let cs = try SSHClient.choose(SSHClient.ciphers, cipherCS, "cipher")
    let sc = try SSHClient.choose(SSHClient.ciphers, cipherSC, "cipher")

    let agreement = try SSHClient.agreement(kex)
    var initMsg = SSHWriter(message: Msg.kexEcdhInit)
    initMsg.string(agreement.clientPublic)
    try write(initMsg.bytes)
    let reply = try next()
    guard reply.first == Msg.kexEcdhReply else {
      throw SSHError.protocolError("expected KEX_ECDH_REPLY, got message \(reply.first ?? 0)")
    }
    var rr = SSHReader(reply)
    _ = try rr.byte()
    let ks = try rr.string()
    let qs = try rr.string()
    let sig = try rr.string()
    let encodedK = try agreement.finish(qs)
    negotiatedKex = kex

    var h = SSHWriter()
    h.string(SSHClient.version)
    h.string(serverVersion)
    h.string(ours)
    h.string(serverInit)
    h.string(ks)
    h.string(agreement.clientPublic)
    h.string(qs)
    h.bytes += encodedK
    let exchangeHash = Array(SHA256.hash(data: h.bytes))
    _ = try verifyHostSignature(blob: ks, signature: sig, data: exchangeHash)
    if initial {
      try checkHostKey(ks)
      sessionID = exchangeHash
      hostKey = ks
    } else if ks != hostKey {
      throw SSHError.hostKey("the host key changed during rekey")
    }

    func derive(_ letter: Character, _ size: Int) -> [UInt8] {
      var out = Array(
        SHA256.hash(data: encodedK + exchangeHash + [letter.asciiValue!] + sessionID))
      while out.count < size {
        out += Array(SHA256.hash(data: encodedK + exchangeHash + out))
      }
      return Array(out[0..<size])
    }
    let csKey = cs.hasPrefix("aes256") ? 32 : 16
    let scKey = sc.hasPrefix("aes256") ? 32 : 16
    let send = GCMCipher(key: SymmetricKey(data: derive("C", csKey)), iv: derive("A", 12))
    let recv = GCMCipher(key: SymmetricKey(data: derive("D", scKey)), iv: derive("B", 12))

    lock.lock()
    do {
      try writeLocked([Msg.newkeys])
    } catch {
      lock.unlock()
      throw error
    }
    let c = try conn
    c.sendCipher = send
    if strict {
      c.sendSeq = 0
    }
    lock.unlock()
    let nk = try next()
    guard nk.first == Msg.newkeys else {
      throw SSHError.protocolError("expected NEWKEYS, got message \(nk.first ?? 0)")
    }
    c.recvCipher = recv
    if strict {
      c.recvSeq = 0
    }
    lock.lock()
    kexActive = false
    exchanges += 1
    for ch in channels.values {
      try? ch.flushLocked()
    }
    lock.unlock()
  }

  private func checkHostKey(_ blob: [UInt8]) throws {
    let kh = config.knownHosts
    switch kh.check(host: config.host, port: config.port, blob: blob) {
    case .known:
      return
    case .changed(let file, let line):
      throw SSHError.hostKeyChanged(
        host: KnownHosts.name(host: config.host, port: config.port),
        fingerprint: KnownHosts.fingerprint(blob), file: file, line: line)
    case .unknown:
      guard config.acceptNewHostKeys else {
        throw SSHError.hostKey("unknown host \(config.host), key \(KnownHosts.fingerprint(blob))")
      }
      try kh.add(host: config.host, port: config.port, blob: blob)
    }
  }

  // MARK: - authentication (RFC 4252)

  private func authenticate() throws {
    var req = SSHWriter(message: Msg.serviceRequest)
    req.string("ssh-userauth")
    try write(req.bytes)
    while true {
      let p = try next()
      if p.first == Msg.serviceAccept {
        break
      }
      guard p.first == Msg.extInfo else {
        throw SSHError.protocolError("expected SERVICE_ACCEPT, got message \(p.first ?? 0)")
      }
    }
    var offered: [String] = []
    for key in config.keys {
      // asked first, as OpenSSH does: only a key the server would take is
      // signed with, so a locked key is opened only when it is the one
      var query = SSHWriter(message: Msg.userauthRequest)
      query.string(config.user)
      query.string("ssh-connection")
      query.string("publickey")
      query.bool(false)
      query.string(key.algorithm)
      query.string(key.publicBlob)
      note("offering \(key.algorithm) \(KnownHosts.fingerprint(key.publicBlob))")
      guard try authResult(query.bytes, &offered, accepted: true) else {
        note("refused")
        continue
      }
      note("accepted: signing")
      var sigData = SSHWriter()
      sigData.string(sessionID)
      sigData.byte(Msg.userauthRequest)
      sigData.string(config.user)
      sigData.string("ssh-connection")
      sigData.string("publickey")
      sigData.bool(true)
      sigData.string(key.algorithm)
      sigData.string(key.publicBlob)
      var w = SSHWriter(message: Msg.userauthRequest)
      w.string(config.user)
      w.string("ssh-connection")
      w.string("publickey")
      w.bool(true)
      w.string(key.algorithm)
      w.string(key.publicBlob)
      w.string(try key.sign(sigData.bytes))
      if try authResult(w.bytes, &offered) {
        return
      }
    }
    if let password = config.password {
      var w = SSHWriter(message: Msg.userauthRequest)
      w.string(config.user)
      w.string("ssh-connection")
      w.string("password")
      w.bool(false)
      w.string(password)
      if try authResult(w.bytes, &offered) {
        return
      }
    }
    // servers behind PAM often take the password only this way
    if let password = config.password, offered.contains("keyboard-interactive") {
      var w = SSHWriter(message: Msg.userauthRequest)
      w.string(config.user)
      w.string("ssh-connection")
      w.string("keyboard-interactive")
      w.string("")  // language
      w.string("")  // submethods
      var answered = false
      let ok = try authResult(w.bytes, &offered) { request in
        try keyboardInteractiveResponse(request, password: password, answered: &answered)
      }
      if ok {
        return
      }
    }
    let methods = offered.isEmpty ? "" : " (server accepts: \(offered.joined(separator: ", ")))"
    throw SSHError.auth("permission denied for \(config.user)\(methods)")
  }

  /// accepted: a key query, where PK_OK (60) is the yes.
  private func authResult(
    _ request: [UInt8], _ offered: inout [String], accepted: Bool = false,
    info: (([UInt8]) throws -> [UInt8])? = nil
  ) throws -> Bool {
    try write(request)
    while true {
      let p = try next()
      var r = SSHReader(p)
      switch try r.byte() {
      case Msg.userauthSuccess:
        return true
      case Msg.userauthFailure:
        offered = try r.nameList()
        return false
      case Msg.userauthBanner:
        onBanner?(try r.text())
      case 60:  // PK_OK to a query, INFO_REQUEST under keyboard-interactive, or PASSWD_CHANGEREQ
        if accepted {
          return true
        }
        guard let info else { return false }
        try write(try info(p))
      default:
        throw SSHError.protocolError("unexpected message \(p.first ?? 0) during authentication")
      }
    }
  }

  // MARK: - channels (RFC 4254)

  /// A channel of a kind, open and confirmed. The reader must be running:
  /// the answer comes through it.
  private func open(_ type: String, _ extra: (inout SSHWriter) -> Void) throws -> SSHChannel {
    lock.lock()
    if let failed {
      lock.unlock()
      throw failed
    }
    let ch = SSHChannel(client: self, id: nextID)
    nextID += 1
    channels[ch.id] = ch
    ch.asking = "\(type) channel"
    var w = SSHWriter(message: Msg.channelOpen)
    w.string(type)
    w.u32(ch.id)
    w.u32(SSHClient.window)
    w.u32(SSHClient.maxPacket)
    extra(&w)
    do {
      try writeLocked(w.bytes)
    } catch {
      channels[ch.id] = nil
      lock.unlock()
      throw error
    }
    lock.unlock()
    try ch.await(config.timeout)
    return ch
  }

  /// A request on the channel; with wantReply, waits for the answer.
  private func request(
    _ ch: SSHChannel, _ name: String, wantReply: Bool, _ body: (inout SSHWriter) -> Void = { _ in }
  ) throws {
    lock.lock()
    var w = SSHWriter(message: Msg.channelRequest)
    w.u32(ch.remote)
    w.string(name)
    w.bool(wantReply)
    body(&w)
    ch.asking = name
    do {
      try writeLocked(w.bytes)
    } catch {
      lock.unlock()
      throw error
    }
    lock.unlock()
    if wantReply {
      try ch.await(config.timeout)
    }
  }

  /// A shell, or a command, on a terminal of that size: a second session
  /// on a connection already made (ControlMaster) costs no key exchange
  /// nor authentication. Set the callbacks, then start() it.
  public func openSession(
    rows: Int, cols: Int, command: String? = nil, environment: [String: String] = [:],
    agent: Bool = false
  ) throws -> SSHChannel {
    let ch = try open("session") { _ in }
    try request(ch, "pty-req", wantReply: true) { pty in
      pty.string(config.term)
      pty.u32(UInt32(cols))
      pty.u32(UInt32(rows))
      pty.u32(0)
      pty.u32(0)
      var modes = SSHWriter()
      modes.byte(3)  // VERASE: the Backspace key sends DEL
      modes.u32(127)
      modes.byte(42)  // IUTF8
      modes.u32(1)
      modes.byte(0)
      pty.string(modes.bytes)
    }
    if agent {
      try request(ch, "auth-agent-req@openssh.com", wantReply: false)
    }
    for (k, v) in environment.sorted(by: { $0.key < $1.key }) {
      try request(ch, "env", wantReply: false) { env in  // servers drop most (AcceptEnv)
        env.string(k)
        env.string(v)
      }
    }
    if let command {
      try request(ch, "exec", wantReply: true) { $0.string(command) }
    } else {
      try request(ch, "shell", wantReply: true)
    }
    return ch
  }

  /// A TCP connection the server makes to host:port, as a channel
  /// (direct-tcpip): ssh -J goes through one, -L tunnels are made of them.
  public func openTunnel(host: String, port: Int) throws -> SSHChannel {
    try open("direct-tcpip") { w in
      w.string(host)
      w.u32(UInt32(port))
      w.string("127.0.0.1")  // the originator, which the server only logs
      w.u32(0)
    }
  }

  // MARK: - forwards (RFC 4254 section 7)

  /// A global request and its answer: the replies come in the order asked.
  private final class GlobalAsk: @unchecked Sendable {
    let gate = DispatchSemaphore(value: 0)
    var ok = false
  }

  /// -R: the server listens on f's bind address and port; what connects
  /// there comes as forwarded-tcpip channels, made into connections to
  /// f.host:f.port from here.
  private func forwardRemote(_ f: SSHConfig.Forward) throws {
    let ask = GlobalAsk()
    lock.lock()
    var w = SSHWriter(message: Msg.globalRequest)
    w.string("tcpip-forward")
    w.bool(true)
    w.string(f.bindHost == "127.0.0.1" ? "localhost" : f.bindHost)
    w.u32(UInt32(f.bindPort))
    globalAsks.append(ask)
    do {
      try writeLocked(w.bytes)
    } catch {
      globalAsks.removeLast()
      lock.unlock()
      throw error
    }
    lock.unlock()
    guard ask.gate.wait(timeout: .now() + config.timeout) == .success else {
      throw SSHError.io("no answer from the server")
    }
    guard ask.ok else { throw SSHError.protocolError("the server refused it") }
  }

  /// -L: a socket here; each connection to it a direct-tcpip channel to
  /// f.host:f.port, as the server sees them. -D (port 0): the connection
  /// says where, in SOCKS.
  private func forwardLocal(_ f: SSHConfig.Forward) throws {
    let fd = try listenTCP(host: f.bindHost, port: f.bindPort)
    lock.lock()
    listeners.append(fd)
    lock.unlock()
    let accepting = Thread { [weak self] in
      while true {
        let conn = accept(fd, nil, nil)
        guard conn >= 0 else { return }  // closed with the connection
        guard let self else {
          Darwin.close(conn)
          return
        }
        var one: Int32 = 1
        setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        Thread.detachNewThread { [self] in
          var socks: SocksRequest?
          do {
            if f.port == 0 {
              socks = try socksRequest(conn)
            }
            let host = socks?.host ?? f.host
            let port = socks?.port ?? f.port
            let ch = try openTunnel(host: host, port: port)
            socks?.answer(true)
            ch.bridge(conn, halfClose: true)
          } catch {
            socks?.answer(false)
            let to = socks.map { "\($0.host):\($0.port)" } ?? "\(f.host):\(f.port)"
            config.warn?("port \(f.bindPort): \(to): \(error)")
            Darwin.close(conn)
          }
        }
      }
    }
    accepting.name = "fosforo.ssh.forward"
    accepting.start()
  }

  /// A channel the server opens on us: a connection to a -R port, or an
  /// agent's (-A). The rest is refused, as is any we did not ask for.
  private func channelOpened(_ r: inout SSHReader) throws {
    let type = try r.text()
    let sender = try r.u32()
    let window = try r.u32()
    let max = try r.u32()
    switch type {
    case "forwarded-tcpip":
      _ = try r.text()  // the address it came to, as the server names it
      let port = Int(try r.u32())
      guard let f = config.remoteForwards.first(where: { $0.bindPort == port }) else {
        try refuse(sender, "no forward for port \(port)")
        return
      }
      Thread.detachNewThread { [self] in  // the dial must not hold the reader
        do {
          let fd = try dial(host: f.host, port: f.port, timeout: config.timeout)
          try accepted(sender, window, max).bridge(fd, halfClose: true)
        } catch {
          config.warn?("port \(port) on the server: \(f.host):\(f.port): \(error)")
          try? refuse(sender, "connect failed", code: 2)
        }
      }
    case "auth-agent@openssh.com" where config.forwardAgent:
      AgentServer(keys: config.keys, channel: try accepted(sender, window, max)).start()
    default:
      try refuse(sender, "no \(type) here")
    }
  }

  private func refuse(_ sender: UInt32, _ why: String, code: UInt32 = 1) throws {
    var w = SSHWriter(message: Msg.channelOpenFailure)
    w.u32(sender)
    w.u32(code)  // 1 administratively prohibited, 2 connect failed
    w.string(why)
    w.string("")
    try write(w.bytes)
  }

  /// The server's channel, confirmed: ours from here as one we opened.
  private func accepted(_ sender: UInt32, _ window: UInt32, _ max: UInt32) throws -> SSHChannel {
    lock.lock()
    defer { lock.unlock() }
    if let failed {
      throw failed
    }
    let ch = SSHChannel(client: self, id: nextID)
    nextID += 1
    ch.remote = sender
    ch.remoteWindow = window
    ch.remoteMax = max
    channels[ch.id] = ch
    var w = SSHWriter(message: Msg.channelOpenConfirmation)
    w.u32(sender)
    w.u32(ch.id)
    w.u32(SSHClient.window)
    w.u32(SSHClient.maxPacket)
    try writeLocked(w.bytes)
    return ch
  }

  // MARK: - running

  /// Delivers the first channel's output from now on (what came before is
  /// queued); the connection is read since connect().
  public func start() {
    main?.start()
  }

  /// As OpenSSH's ServerAlive: a request the server must answer after each
  /// quiet interval; any packet counts as the answer. Too many unanswered
  /// and the connection is taken for dead: the socket is shut, the reader
  /// ends with the reason.
  private func keepalive() {
    let every = config.aliveInterval
    while true {
      Thread.sleep(forTimeInterval: every / 4)
      lock.lock()
      if ended || failed != nil || silent != nil {
        lock.unlock()
        return
      }
      guard !kexActive, Date().timeIntervalSince(heard) >= every else {
        lock.unlock()
        continue
      }
      if unanswered >= config.aliveCountMax {
        let waited = Int((every * Double(unanswered)).rounded())
        silent = .disconnected("no answer from the server in \(waited) s")
        lock.unlock()
        if let fd = io?.fd {
          shutdown(fd, SHUT_RDWR)
        }
        return
      }
      unanswered += 1
      heard = Date()  // the next question one interval from now
      var w = SSHWriter(message: Msg.globalRequest)
      w.string(Array("keepalive@openssh.com".utf8))
      w.bool(true)
      if (try? writeLocked(w.bytes)) != nil {
        globalAsks.append(nil)
      }
      lock.unlock()
    }
  }

  private func run() {
    var failure: SSHError?
    do {
      while true {
        try handle(try heardFrom(next()))
      }
    } catch let e as SSHError {
      failure = e
    } catch {
      failure = .io("\(error)")
    }
    lock.lock()
    failure = silent ?? failure
    let quiet = ended  // we shut it after the last channel: nothing to report
    let open = Array(channels.values)
    channels.removeAll()
    failed = failure ?? .io("connection closed")
    let sockets = listeners
    listeners.removeAll()
    let asks = globalAsks
    globalAsks.removeAll()
    lock.unlock()
    for fd in sockets {
      shutdown(fd, SHUT_RDWR)  // wakes the accept
      Darwin.close(fd)
    }
    for ask in asks {
      ask?.gate.signal()
    }
    onEnd?(quiet ? nil : failure)
    if quiet {
      return
    }
    for ch in open {
      ch.finish(status: nil, error: failure)
    }
  }

  private func heardFrom(_ p: [UInt8]) -> [UInt8] {
    lock.lock()
    heard = Date()
    unanswered = 0
    lock.unlock()
    return p
  }

  private func channel(_ id: UInt32) -> SSHChannel? {
    lock.lock()
    defer { lock.unlock() }
    return channels[id]
  }

  /// One packet from the server, to its channel or to the connection.
  private func handle(_ p: [UInt8]) throws {
    var r = SSHReader(p)
    switch try r.byte() {
    case Msg.channelData:
      let id = try r.u32()
      try channel(id)?.received(try r.string())
    case Msg.channelExtendedData:
      let id = try r.u32()
      _ = try r.u32()
      try channel(id)?.received(try r.string())
    case Msg.channelWindowAdjust:
      let id = try r.u32()
      let n = try r.u32()
      lock.lock()
      if let ch = channels[id] {
        ch.remoteWindow = ch.remoteWindow &+ n < ch.remoteWindow ? UInt32.max : ch.remoteWindow + n
        try? ch.flushLocked()
      }
      lock.unlock()
    case Msg.channelRequest:
      let id = try r.u32()
      let name = try r.text()
      let want = try r.bool()
      lock.lock()
      let ch = channels[id]
      if name == "exit-status" {
        ch?.exitStatus = Int32(bitPattern: try r.u32())
      } else if name == "exit-signal" {
        ch?.exitStatus = 255
      }
      if want, let ch {
        var w = SSHWriter(message: Msg.channelFailure)
        w.u32(ch.remote)
        try? writeLocked(w.bytes)
      }
      lock.unlock()
    case Msg.channelEOF:
      let id = try r.u32()
      channel(id)?.onEOF?()
    case Msg.channelClose:
      let id = try r.u32()
      lock.lock()
      guard let ch = channels[id] else {
        lock.unlock()
        return
      }
      if !ch.closeSent {
        ch.closeSent = true
        var w = SSHWriter(message: Msg.channelClose)
        w.u32(ch.remote)
        try? writeLocked(w.bytes)
      }
      channels[id] = nil
      let status = ch.exitStatus
      // the last channel ends the connection, and so does the session of
      // one with forwards (they were for it); with -N nothing does
      let last = !config.noSession && (channels.isEmpty || (ch === main && forwards))
      if last {
        ended = true
      }
      lock.unlock()
      ch.finish(status: status, error: nil)
      if last {
        io?.shutdown()  // no channel left: the connection has nothing more to do
      }
    case Msg.channelOpenConfirmation:
      let id = try r.u32()
      let remote = try r.u32()
      let window = try r.u32()
      let max = try r.u32()
      lock.lock()
      let ch = channels[id]
      ch?.remote = remote
      ch?.remoteWindow = window
      ch?.remoteMax = max
      ch?.answer = .success(())
      lock.unlock()
      ch?.gate.signal()
    case Msg.channelOpenFailure:
      let id = try r.u32()
      _ = try r.u32()
      let reason = try r.text()
      lock.lock()
      let ch = channels[id]
      channels[id] = nil
      ch?.answer = .failure(.protocolError("\(ch?.asking ?? "channel") refused: \(reason)"))
      lock.unlock()
      ch?.gate.signal()
    case Msg.channelSuccess, Msg.channelFailure:
      let ok = p.first == Msg.channelSuccess
      let id = try r.u32()
      lock.lock()
      let ch = channels[id]
      ch?.answer =
        ok ? .success(()) : .failure(.protocolError("server refused \(ch?.asking ?? "request")"))
      lock.unlock()
      ch?.gate.signal()
    case Msg.channelOpen:
      try channelOpened(&r)
    case Msg.globalRequest:
      _ = try r.text()
      if try r.bool() {
        try write([Msg.requestFailure])
      }
    case Msg.kexinit:
      try keyExchange(serverKexinit: p)
    case Msg.requestSuccess, Msg.requestFailure:
      lock.lock()
      let ask = globalAsks.isEmpty ? nil : globalAsks.removeFirst()
      ask?.ok = p.first == Msg.requestSuccess
      lock.unlock()
      ask?.gate.signal()
    case Msg.extInfo:
      break
    default:
      var w = SSHWriter(message: Msg.unimplemented)
      w.u32((try? conn.recvSeq).map { $0 &- 1 } ?? 0)
      try write(w.bytes)
    }
  }

  // MARK: - the first channel, through the client (the API before channels)

  public func send(_ bytes: [UInt8]) {
    main?.send(bytes)
  }

  public func resize(rows: Int, cols: Int) {
    main?.resize(rows: rows, cols: cols)
  }

  /// Closes the first channel (the connection follows when it was the
  /// last). Before it is open there is no channel: the connect is cancelled.
  public func close() {
    lock.lock()
    guard let main else {
      cancelled = true
      io?.shutdown()
      lock.unlock()
      return
    }
    lock.unlock()
    main.close()
  }
}

/// One channel of an SSH connection: a session (a shell or a command on a
/// pty) or a tunnel. Its bytes come through onData once started; send()
/// goes the other way, held while keys are being exchanged or the remote
/// window is closed. The client's lock guards all of it.
public final class SSHChannel: @unchecked Sendable {
  public let id: UInt32
  private unowned let client: SSHClient
  var remote: UInt32 = 0
  var remoteWindow: UInt32 = 0
  var remoteMax: UInt32 = 0
  private var localWindow = SSHClient.window
  private var pending: [UInt8] = []
  var closeSent = false
  private var finished = false
  var exitStatus: Int32?
  private var started = false
  private var queued: [[UInt8]] = []
  var asking = ""  // what the next CHANNEL_SUCCESS/FAILURE answers
  var answer: Result<Void, SSHError>?
  let gate = DispatchSemaphore(value: 0)

  /// Output of the remote side (stdout and stderr), on the reader thread.
  public var onData: (@Sendable ([UInt8]) -> Void)?
  /// Once, on the reader thread: the exit status when the remote side
  /// reported one, and the error when the connection broke instead.
  public var onClose: (@Sendable (Int32?, SSHError?) -> Void)?
  /// The server's EOF: nothing more will come (a tunnel's far end hung up).
  public var onEOF: (@Sendable () -> Void)?

  init(client: SSHClient, id: UInt32) {
    self.client = client
    self.id = id
  }

  /// Waits for the server's answer to the open or the request sent.
  func await(_ timeout: TimeInterval) throws {
    guard gate.wait(timeout: .now() + timeout) == .success else {
      throw SSHError.io("\(asking): no answer from the server in \(Int(timeout)) s")
    }
    client.lock.lock()
    let a = answer
    answer = nil
    client.lock.unlock()
    if case .failure(let e)? = a {
      throw e
    }
  }

  /// Delivers what the server sends from now on; what came before start()
  /// is delivered first, in order.
  public func start() {
    client.lock.lock()
    started = true
    let q = queued
    queued.removeAll()
    client.lock.unlock()
    for data in q {
      onData?(data)
    }
  }

  func received(_ data: [UInt8]) throws {
    client.lock.lock()
    let deliver = started
    if !deliver && !data.isEmpty {
      queued.append(data)
    }
    localWindow -= min(localWindow, UInt32(data.count))
    if localWindow < SSHClient.window / 2 {
      var w = SSHWriter(message: Msg.channelWindowAdjust)
      w.u32(remote)
      w.u32(SSHClient.window - localWindow)
      try client.writeLocked(w.bytes)
      localWindow = SSHClient.window
    }
    client.lock.unlock()
    if deliver && !data.isEmpty {
      onData?(data)
    }
  }

  /// Once: the close, with its status or the connection's failure; a
  /// pending await is answered with the failure too.
  func finish(status: Int32?, error: SSHError?) {
    client.lock.lock()
    let first = !finished
    finished = true
    if first, let error {
      answer = .failure(error)
    }
    client.lock.unlock()
    guard first else { return }
    if error != nil {
      gate.signal()
    }
    onClose?(status, status == nil ? error : nil)
  }

  public func send(_ bytes: [UInt8]) {
    client.lock.lock()
    pending += bytes
    try? flushLocked()
    client.lock.unlock()
  }

  func flushLocked() throws {
    while !client.kexActive && !pending.isEmpty && remoteWindow > 0 && !closeSent {
      let n = min(pending.count, Int(remoteWindow), Int(min(remoteMax, SSHClient.maxPacket)) - 64)
      var w = SSHWriter(message: Msg.channelData)
      w.u32(remote)
      w.string(Array(pending[0..<n]))
      try client.writeLocked(w.bytes)
      pending.removeFirst(n)
      remoteWindow -= UInt32(n)
    }
  }

  public func resize(rows: Int, cols: Int) {
    client.lock.lock()
    defer { client.lock.unlock() }
    guard !client.kexActive, !closeSent else { return }  // yagni: a resize during rekey is dropped
    var w = SSHWriter(message: Msg.channelRequest)
    w.u32(remote)
    w.string("window-change")
    w.bool(false)
    w.u32(UInt32(cols))
    w.u32(UInt32(rows))
    w.u32(0)
    w.u32(0)
    try? client.writeLocked(w.bytes)
  }

  /// Closes the channel; onClose comes when the server answers.
  public func close() {
    client.lock.lock()
    defer { client.lock.unlock() }
    guard !closeSent else { return }
    closeSent = true
    var w = SSHWriter(message: Msg.channelClose)
    w.u32(remote)
    try? client.writeLocked(w.bytes)
  }

  /// A tunnel as a socket: what is written to it goes down the channel,
  /// what comes up is read from it, as if it were a TCP connection to the
  /// tunnel's host. The channel pumps the other end on its own thread from
  /// here on; it closes when the socket is closed, and the socket ends
  /// when the channel does.
  public func socket() throws -> Int32 {
    var pair: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
      throw SSHError.io("socketpair: \(String(cString: strerror(errno)))")
    }
    bridge(pair[0], halfClose: false)
    return pair[1]
  }

  /// The channel and fd as one connection, pumped both ways until either
  /// ends; fd is closed then. halfClose: the server's EOF only shuts fd for
  /// writing (a TCP peer may still answer); otherwise it ends it.
  /// yagni: a slow fd holds the reader (no flow control past the window).
  func bridge(_ fd: Int32, halfClose: Bool) {
    onData = { data in
      var off = 0
      while off < data.count {
        let n = data[off...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        if n <= 0 {
          break
        }
        off += n
      }
    }
    onEOF = {
      shutdown(fd, halfClose ? SHUT_WR : SHUT_RDWR)  // the far side reads end of file
    }
    onClose = { _, _ in
      shutdown(fd, SHUT_RDWR)
    }
    start()
    let pump = Thread { [self] in
      var buf = [UInt8](repeating: 0, count: 32768)
      while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 {
          break
        }
        send(Array(buf[0..<n]))
      }
      close()
      Darwin.close(fd)
    }
    pump.name = "fosforo.ssh.tunnel"
    pump.start()
  }
}

/// RFC 4256: INFO_REQUEST in, INFO_RESPONSE out. The password answers the
/// first prompt that hides its input; prompts that echo get an empty
/// answer, and a request with no prompts (servers send one to finish) an
/// empty response. A second hidden prompt is a second factor.
/// yagni: second factors (an OTP) would need the prompt shown to the user.
func keyboardInteractiveResponse(_ request: [UInt8], password: String, answered: inout Bool)
  throws -> [UInt8]
{
  var r = SSHReader(request)
  _ = try r.byte()
  _ = try r.string()  // name
  _ = try r.string()  // instruction
  _ = try r.string()  // language
  let count = Int(try r.u32())
  guard count <= 16 else { throw SSHError.protocolError("\(count) keyboard-interactive prompts") }
  var w = SSHWriter(message: 61)
  w.u32(UInt32(count))
  for _ in 0..<count {
    let prompt = try r.text()
    let echo = try r.byte() != 0
    if echo {
      w.string("")
      continue
    }
    guard !answered else {
      let what = prompt.trimmingCharacters(in: .whitespaces)
      throw SSHError.auth("server asks for more than a password (\(what)): not supported yet")
    }
    answered = true
    w.string(password)
  }
  return w.bytes
}
