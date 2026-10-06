import Foundation

/// A listening TCP socket on host:port ("" every interface), for ssh -L.
func listenTCP(host: String, port: Int) throws -> Int32 {
  var hints = addrinfo()
  hints.ai_flags = AI_PASSIVE | AI_NUMERICSERV
  hints.ai_family = AF_UNSPEC
  hints.ai_socktype = SOCK_STREAM
  var found: UnsafeMutablePointer<addrinfo>?
  let rc = getaddrinfo(host.isEmpty ? nil : host, String(port), &hints, &found)
  guard rc == 0, let first = found else {
    throw SSHError.io("\(host): \(String(cString: gai_strerror(rc)))")
  }
  defer { freeaddrinfo(found) }
  let fd = socket(first.pointee.ai_family, SOCK_STREAM, 0)
  guard fd >= 0 else { throw SSHError.io("socket: \(String(cString: strerror(errno)))") }
  var one: Int32 = 1
  setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
  guard bind(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0, listen(fd, 16) == 0 else {
    let why = String(cString: strerror(errno))
    close(fd)
    throw SSHError.io(why)
  }
  return fd
}

/// The agent's side of an auth-agent@openssh.com channel (ssh -A): the
/// server's ssh-add and ssh ask for the keys and for signatures, and the
/// keys sign here, never sent. The protocol is draft-miller-ssh-agent;
/// only listing and signing are served, anything else fails.
final class AgentServer: @unchecked Sendable {
  private let keys: [PrivateKey]
  private let channel: SSHChannel
  private var buffer: [UInt8] = []  // on queue
  /// Signing may wait for Face ID: not on the reader thread.
  private let queue = DispatchQueue(label: "fosforo.ssh.agent")

  private static let failure: UInt8 = 5
  private static let requestIdentities: UInt8 = 11
  private static let identitiesAnswer: UInt8 = 12
  private static let signRequest: UInt8 = 13
  private static let signResponse: UInt8 = 14
  private static let rsaSHA512: UInt32 = 4
  private static let messageMax = 256 * 1024

  init(keys: [PrivateKey], channel: SSHChannel) {
    self.keys = keys
    self.channel = channel
  }

  func start() {
    channel.onData = { [self] data in
      queue.async { [self] in feed(data) }
    }
    channel.onEOF = { [channel] in channel.close() }
    channel.start()
  }

  private func feed(_ data: [UInt8]) {
    buffer += data
    while buffer.count >= 4 {
      let n = buffer[0..<4].reduce(0) { $0 << 8 | Int($1) }
      guard n > 0, n <= AgentServer.messageMax else {
        channel.close()
        return
      }
      guard buffer.count >= 4 + n else { return }
      let reply = answer(Array(buffer[4..<4 + n]))
      buffer.removeFirst(4 + n)
      var w = SSHWriter()
      w.string(reply)
      channel.send(w.bytes)
    }
  }

  func answer(_ message: [UInt8]) -> [UInt8] {
    var r = SSHReader(message)
    switch try? r.byte() {
    case AgentServer.requestIdentities:
      var w = SSHWriter(message: AgentServer.identitiesAnswer)
      w.u32(UInt32(keys.count))
      for k in keys {
        w.string(k.publicBlob)
        w.string("fosforo")
      }
      return w.bytes
    case AgentServer.signRequest:
      guard let blob = try? r.string(), let data = try? r.string(), let flags = try? r.u32(),
        let key = keys.first(where: { $0.publicBlob == blob })
      else { return [AgentServer.failure] }
      // an RSA key here signs with SHA-512 only: asked for another, fail
      // rather than answer what the asker would refuse
      if key.algorithm == "rsa-sha2-512" && flags & AgentServer.rsaSHA512 == 0 {
        return [AgentServer.failure]
      }
      guard let sig = try? key.sign(data) else { return [AgentServer.failure] }
      var w = SSHWriter(message: AgentServer.signResponse)
      w.string(sig)
      return w.bytes
    default:
      return [AgentServer.failure]
    }
  }
}

/// What a SOCKS client (ssh -D) asks for: where to connect, and how to
/// tell it whether that worked. SOCKS 5 (RFC 1928, no authentication,
/// CONNECT) and SOCKS 4 and 4a, as OpenSSH serves them.
struct SocksRequest {
  let host: String
  let port: Int
  let answer: (Bool) -> Void
}

private func readExact(_ fd: Int32, _ n: Int) throws -> [UInt8] {
  var out = [UInt8](repeating: 0, count: n)
  var got = 0
  while got < n {
    let r = out[got...].withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
    guard r > 0 else { throw SSHError.io("socks: the client went away") }
    got += r
  }
  return out
}

/// Up to a NUL (SOCKS 4's user id and 4a's host name).
private func readZ(_ fd: Int32) throws -> [UInt8] {
  var out: [UInt8] = []
  while true {
    let b = try readExact(fd, 1)[0]
    if b == 0 {
      return out
    }
    guard out.count < 255 else { throw SSHError.io("socks: a name too long") }
    out.append(b)
  }
}

private func writeAll(_ fd: Int32, _ bytes: [UInt8]) {
  _ = bytes.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

func socksRequest(_ fd: Int32) throws -> SocksRequest {
  let version = try readExact(fd, 1)[0]
  if version == 4 {
    let head = try readExact(fd, 7)  // command, port, IPv4
    guard head[0] == 1 else {
      writeAll(fd, [0, 0x5B, 0, 0, 0, 0, 0, 0])
      throw SSHError.io("socks4: only CONNECT")
    }
    let port = Int(head[1]) << 8 | Int(head[2])
    _ = try readZ(fd)  // the user id, which says nothing here
    var host = head[3...6].map(String.init).joined(separator: ".")
    if head[3] == 0 && head[4] == 0 && head[5] == 0 && head[6] != 0 {
      host = String(decoding: try readZ(fd), as: UTF8.self)  // 4a: the name follows
    }
    return SocksRequest(host: host, port: port) { ok in
      writeAll(fd, [0, ok ? 0x5A : 0x5B, 0, 0, 0, 0, 0, 0])
    }
  }
  guard version == 5 else { throw SSHError.io("socks: version \(version)") }
  let methods = try readExact(fd, Int(try readExact(fd, 1)[0]))
  guard methods.contains(0) else {
    writeAll(fd, [5, 0xFF])
    throw SSHError.io("socks5: the client wants authentication")
  }
  writeAll(fd, [5, 0])
  let head = try readExact(fd, 4)  // version, command, reserved, address type
  let host: String
  switch head[3] {
  case 1:
    host = try readExact(fd, 4).map(String.init).joined(separator: ".")
  case 3:
    host = String(decoding: try readExact(fd, Int(try readExact(fd, 1)[0])), as: UTF8.self)
  case 4:
    let a = try readExact(fd, 16)
    host = stride(from: 0, to: 16, by: 2).map {
      String(Int(a[$0]) << 8 | Int(a[$0 + 1]), radix: 16)
    }
    .joined(separator: ":")
  default:
    writeAll(fd, [5, 8, 0, 1, 0, 0, 0, 0, 0, 0])  // address type not supported
    throw SSHError.io("socks5: address type \(head[3])")
  }
  let p = try readExact(fd, 2)
  guard head[1] == 1 else {
    writeAll(fd, [5, 7, 0, 1, 0, 0, 0, 0, 0, 0])  // command not supported
    throw SSHError.io("socks5: only CONNECT")
  }
  return SocksRequest(host: host, port: Int(p[0]) << 8 | Int(p[1])) { ok in
    writeAll(fd, [5, ok ? 0 : 5, 0, 1, 0, 0, 0, 0, 0, 0])  // 5: connection refused
  }
}
