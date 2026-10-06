import CryptoKit
import Darwin
import Foundation

/// aes-gcm@openssh.com: the length in clear as additional data, the rest
/// sealed, a 16-byte tag; the nonce's last 8 bytes count packets.
struct GCMCipher {
  let key: SymmetricKey
  var iv: [UInt8]  // 12 bytes

  mutating func next() -> AES.GCM.Nonce {
    let nonce = try! AES.GCM.Nonce(data: iv)  // 12 bytes by construction
    var i = 11
    while i >= 4 {
      iv[i] &+= 1
      if iv[i] != 0 {
        break
      }
      i -= 1
    }
    return nonce
  }
}

/// RFC 4253 section 6 over a connected socket: framing, padding, sequence
/// numbers, encryption once keys are in.
final class PacketIO {
  static let maxPacket = 256 * 1024  // OpenSSH's own ceiling
  let fd: Int32
  var sendSeq: UInt32 = 0
  var recvSeq: UInt32 = 0
  var sendCipher: GCMCipher?
  var recvCipher: GCMCipher?
  private var inbuf: [UInt8] = []
  private var inpos = 0

  /// Until when a read or a write may wait (the negotiation runs under
  /// one); nil waits as long as it takes.
  var deadline: Date?
  private var shut = false

  init(fd: Int32) { self.fd = fd }

  deinit { close(fd) }

  /// Wakes whoever is blocked in a read or a write of this socket, from any
  /// thread: they fail with "cancelled". How a connect in progress is stopped.
  func shutdown() {
    shut = true
    _ = Darwin.shutdown(fd, SHUT_RDWR)
  }

  private func wait(for events: Int32) throws {
    guard let deadline else { return }
    let left = deadline.timeIntervalSinceNow
    guard left > 0 else { throw SSHError.io("no answer from the server in time") }
    var p = pollfd(fd: fd, events: Int16(events), revents: 0)
    if poll(&p, 1, Int32(min(left * 1000 + 1, 1_000_000))) == 0 {
      throw SSHError.io("no answer from the server in time")
    }
  }

  private func fill(_ want: Int) throws {
    while inbuf.count - inpos < want {
      if inpos > 65536 {
        inbuf.removeFirst(inpos)
        inpos = 0
      }
      try wait(for: POLLIN)
      var chunk = [UInt8](repeating: 0, count: 65536)
      let n = chunk.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
      if n < 0 && errno == EINTR {
        continue
      }
      if n <= 0 {
        if shut {
          throw SSHError.io("cancelled")
        }
        throw SSHError.disconnected(n == 0 ? "connection closed" : String(cString: strerror(errno)))
      }
      inbuf += chunk[0..<n]
    }
  }

  private func take(_ n: Int) throws -> [UInt8] {
    try fill(n)
    let out = Array(inbuf[inpos..<inpos + n])
    inpos += n
    return out
  }

  func writeAll(_ bytes: [UInt8]) throws {
    var off = 0
    while off < bytes.count {
      try wait(for: POLLOUT)
      let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
      if n < 0 && errno == EINTR {
        continue
      }
      if n <= 0 {
        throw SSHError.io("write: \(String(cString: strerror(errno)))")
      }
      off += n
    }
  }

  /// The identification line; lines before it are allowed (RFC 4253 4.2).
  func readVersion() throws -> String {
    for _ in 0..<64 {
      var line: [UInt8] = []
      while true {
        let b = try take(1)[0]
        if b == 0x0A {
          break
        }
        line.append(b)
        if line.count > 255 {
          throw SSHError.protocolError("identification line too long")
        }
      }
      if line.last == 0x0D {
        line.removeLast()
      }
      let s = String(decoding: line, as: UTF8.self)
      if s.hasPrefix("SSH-") {
        return s
      }
    }
    throw SSHError.protocolError("no SSH identification")
  }

  func writePacket(_ payload: [UInt8]) throws {
    let block = sendCipher == nil ? 8 : 16
    let lengthCounts = sendCipher == nil ? 4 : 0  // under GCM the length is outside the blocks
    var pad = block - (lengthCounts + 1 + payload.count) % block
    if pad < 4 {
      pad += block
    }
    var padding = [UInt8](repeating: 0, count: pad)
    _ = SecRandomCopyBytes(kSecRandomDefault, pad, &padding)
    var len = SSHWriter()
    len.u32(UInt32(1 + payload.count + pad))
    let body = [UInt8(pad)] + payload + padding
    defer { sendSeq &+= 1 }
    guard var c = sendCipher else {
      try writeAll(len.bytes + body)
      return
    }
    let box = try AES.GCM.seal(body, using: c.key, nonce: c.next(), authenticating: len.bytes)
    sendCipher = c
    try writeAll(len.bytes + Array(box.ciphertext) + Array(box.tag))
  }

  func readPacket() throws -> [UInt8] {
    let head = try take(4)
    var r = SSHReader(head)
    let len = Int(try r.u32())
    guard len >= 5, len <= PacketIO.maxPacket else {
      throw SSHError.protocolError("bad packet length \(len)")
    }
    defer { recvSeq &+= 1 }
    var body: [UInt8]
    if var c = recvCipher {
      guard len % 16 == 0 else { throw SSHError.protocolError("unaligned packet") }
      let sealed = try take(len + 16)
      let box = try AES.GCM.SealedBox(
        nonce: c.next(), ciphertext: sealed[0..<len], tag: sealed[len...])
      recvCipher = c
      do {
        body = Array(try AES.GCM.open(box, using: c.key, authenticating: head))
      } catch {
        throw SSHError.protocolError("packet failed authentication")
      }
    } else {
      body = try take(len)
    }
    let pad = Int(body[0])
    guard pad >= 4, pad < len else { throw SSHError.protocolError("bad padding") }
    return Array(body[1..<(len - pad)])
  }
}

/// A TCP connection with a deadline on connect; afterwards blocking, with
/// Nagle off (keystrokes go out one by one).
/// Addresses as each family's lookup returns them: IPv4 and IPv6 are
/// asked apart, so a slow answer for one (mDNS on .local waits for AAAA)
/// does not hold the other back.
private final class Lookup: @unchecked Sendable {
  let cond = NSCondition()
  var found: [(family: Int32, addr: Data)] = []
  var waiting = 2
  var failure = "no address"

  init(host: String, port: Int) {
    for family in [AF_INET, AF_INET6] {
      Thread.detachNewThread { [self] in
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = family
        var res: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(host, String(port), &hints, &res)
        var got: [(Int32, Data)] = []
        var ai = rc == 0 ? res : nil
        while let a = ai {
          let addr = Data(bytes: a.pointee.ai_addr, count: Int(a.pointee.ai_addrlen))
          ai = a.pointee.ai_next
          // ::ffff:a.b.c.d is the IPv4 address again, on an IPv6 socket: the
          // IPv4 attempt covers it, and a peer named that way confuses mosh
          if a.pointee.ai_family == AF_INET6, addr.count >= 24,
            addr[8..<18] == Data(repeating: 0, count: 10), addr[18] == 0xFF, addr[19] == 0xFF
          {
            continue
          }
          got.append((a.pointee.ai_family, addr))
        }
        if let res {
          freeaddrinfo(res)
        }
        cond.lock()
        found += got
        waiting -= 1
        if rc != 0 && got.isEmpty && found.isEmpty {
          failure = String(cString: gai_strerror(rc))
        }
        cond.broadcast()
        cond.unlock()
      }
    }
  }
}

/// Connects as Happy Eyeballs (RFC 8305) does, simply: every address is
/// tried as soon as its lookup returns, the attempts race, the first to
/// connect wins and the rest are closed.
func dial(
  host: String, port: Int, timeout: TimeInterval, trace: ((String) -> Void)? = nil,
  cancelled: (() -> Bool)? = nil
) throws -> Int32 {
  let lookup = Lookup(host: host, port: port)
  let deadline = Date().addingTimeInterval(timeout)
  var tried = 0
  var racing: [Int32] = []
  var last = "no address"
  defer {
    for fd in racing {
      close(fd)
    }
  }
  while Date() < deadline {
    if cancelled?() == true {
      throw SSHError.io("cancelled")
    }
    lookup.cond.lock()
    if tried == lookup.found.count && lookup.waiting > 0 && racing.isEmpty {
      _ = lookup.cond.wait(until: min(deadline, Date().addingTimeInterval(0.05)))
    }
    let fresh = Array(lookup.found[tried...])
    let done = lookup.waiting == 0
    if done && lookup.found.isEmpty {
      last = lookup.failure
    }
    lookup.cond.unlock()
    tried += fresh.count
    if !fresh.isEmpty {
      trace?("resolved \(host): \(fresh.count) address\(fresh.count == 1 ? "" : "es")")
    }
    for (family, addr) in fresh {
      let fd = socket(family, SOCK_STREAM, 0)
      if fd < 0 {
        continue
      }
      var one: Int32 = 1
      setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
      setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
      // TCPKeepAlive, on as in OpenSSH
      setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &one, socklen_t(MemoryLayout<Int32>.size))
      _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
      let rc = addr.withUnsafeBytes {
        connect(fd, $0.baseAddress!.assumingMemoryBound(to: sockaddr.self), socklen_t(addr.count))
      }
      if rc == 0 || errno == EINPROGRESS {
        racing.append(fd)
      } else {
        last = String(cString: strerror(errno))
        trace?("an address of \(host): \(last)")
        close(fd)
      }
    }
    if racing.isEmpty {
      if done && tried == lookup.found.count {
        break
      }
      continue
    }
    var polls = racing.map { pollfd(fd: $0, events: Int16(POLLOUT), revents: 0) }
    guard poll(&polls, nfds_t(polls.count), 20) > 0 else { continue }
    for p in polls where p.revents != 0 {
      var err: Int32 = 0
      var len = socklen_t(MemoryLayout<Int32>.size)
      getsockopt(p.fd, SOL_SOCKET, SO_ERROR, &err, &len)
      racing.removeAll { $0 == p.fd }
      if err == 0 {
        _ = fcntl(p.fd, F_SETFL, fcntl(p.fd, F_GETFL) & ~O_NONBLOCK)
        return p.fd
      }
      last = String(cString: strerror(err))
      trace?("an address of \(host): \(last)")
      close(p.fd)
    }
  }
  if Date() >= deadline {
    last = String(cString: strerror(ETIMEDOUT))
  }
  throw SSHError.io("\(host):\(port): \(last)")
}

func numericPeer(_ fd: Int32) -> String? {
  var addr = sockaddr_storage()
  var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
  let got = withUnsafeMutablePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
  }
  guard got == 0 else { return nil }
  var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
  let rc = withUnsafePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
      getnameinfo($0, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
    }
  }
  guard rc == 0 else { return nil }
  return String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
}
