import Foundation

public enum SSHError: Error, CustomStringConvertible, Equatable {
  case io(String)
  case protocolError(String)
  case disconnected(String)
  case hostKey(String)
  case auth(String)
  case unsupported(String)
  /// The server takes this key file, which needs its passphrase to sign.
  case locked(String)
  /// Another key than the one on record, at line of file.
  case hostKeyChanged(host: String, fingerprint: String, file: String, line: Int)

  public var description: String {
    switch self {
    case .io(let s): return "ssh: \(s)"
    case .protocolError(let s): return "ssh protocol: \(s)"
    case .disconnected(let s): return "ssh: disconnected: \(s)"
    case .hostKey(let s): return "ssh host key: \(s)"
    case .auth(let s): return "ssh authentication: \(s)"
    case .unsupported(let s): return "ssh: not supported: \(s)"
    case .locked(let s): return "ssh: \(s) needs its passphrase"
    case .hostKeyChanged(let h, let fp, let file, let line):
      return "ssh host key: \(h) presented \(fp), not the key at \(file):\(line): refusing"
    }
  }
}

/// RFC 4251 section 5 encodings, written.
struct SSHWriter {
  var bytes: [UInt8] = []

  init() {}
  init(message: UInt8) { bytes = [message] }

  mutating func byte(_ b: UInt8) { bytes.append(b) }

  mutating func bool(_ b: Bool) { bytes.append(b ? 1 : 0) }

  mutating func u32(_ v: UInt32) {
    bytes.append(UInt8(v >> 24))
    bytes.append(UInt8((v >> 16) & 0xFF))
    bytes.append(UInt8((v >> 8) & 0xFF))
    bytes.append(UInt8(v & 0xFF))
  }

  mutating func string(_ b: [UInt8]) {
    u32(UInt32(b.count))
    bytes += b
  }

  mutating func string(_ s: String) { string(Array(s.utf8)) }

  mutating func nameList(_ names: [String]) { string(names.joined(separator: ",")) }

  /// Unsigned big-endian magnitude as an mpint: no leading zero bytes, and
  /// one zero byte in front when the top bit would read as a sign.
  mutating func mpint(_ magnitude: [UInt8]) {
    var m = magnitude.drop { $0 == 0 }
    if let first = m.first, first & 0x80 != 0 {
      m.insert(0, at: m.startIndex)
    }
    string(Array(m))
  }
}

/// RFC 4251 section 5 encodings, read; every read is bounds-checked because
/// all of it comes off the network.
struct SSHReader {
  let bytes: [UInt8]
  var pos = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  var remaining: Int { bytes.count - pos }

  mutating func byte() throws -> UInt8 {
    guard pos < bytes.count else { throw SSHError.protocolError("truncated message") }
    pos += 1
    return bytes[pos - 1]
  }

  mutating func bool() throws -> Bool { try byte() != 0 }

  mutating func u32() throws -> UInt32 {
    guard remaining >= 4 else { throw SSHError.protocolError("truncated message") }
    let b = bytes[pos..<pos + 4]
    pos += 4
    return b.reduce(0) { $0 << 8 | UInt32($1) }
  }

  mutating func string() throws -> [UInt8] {
    let n = Int(try u32())
    guard n <= remaining else { throw SSHError.protocolError("string past the end") }
    pos += n
    return Array(bytes[pos - n..<pos])
  }

  mutating func text() throws -> String { String(decoding: try string(), as: UTF8.self) }

  mutating func nameList() throws -> [String] {
    let s = try text()
    return s.isEmpty ? [] : s.split(separator: ",").map(String.init)
  }

  /// mpint as an unsigned magnitude (leading sign byte dropped).
  mutating func mpint() throws -> [UInt8] {
    Array(try string().drop { $0 == 0 })
  }
}

enum Msg {
  static let disconnect: UInt8 = 1
  static let ignore: UInt8 = 2
  static let unimplemented: UInt8 = 3
  static let debug: UInt8 = 4
  static let serviceRequest: UInt8 = 5
  static let serviceAccept: UInt8 = 6
  static let extInfo: UInt8 = 7
  static let kexinit: UInt8 = 20
  static let newkeys: UInt8 = 21
  static let kexEcdhInit: UInt8 = 30
  static let kexEcdhReply: UInt8 = 31
  static let userauthRequest: UInt8 = 50
  static let userauthFailure: UInt8 = 51
  static let userauthSuccess: UInt8 = 52
  static let userauthBanner: UInt8 = 53
  static let globalRequest: UInt8 = 80
  static let requestSuccess: UInt8 = 81
  static let requestFailure: UInt8 = 82
  static let channelOpen: UInt8 = 90
  static let channelOpenConfirmation: UInt8 = 91
  static let channelOpenFailure: UInt8 = 92
  static let channelWindowAdjust: UInt8 = 93
  static let channelData: UInt8 = 94
  static let channelExtendedData: UInt8 = 95
  static let channelEOF: UInt8 = 96
  static let channelClose: UInt8 = 97
  static let channelRequest: UInt8 = 98
  static let channelSuccess: UInt8 = 99
  static let channelFailure: UInt8 = 100
}
