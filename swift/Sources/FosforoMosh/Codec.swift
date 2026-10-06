import Compression
import Foundation

public struct MoshError: Error, CustomStringConvertible, Equatable {
  public let description: String
}

/// zlib (RFC 1950) around the raw deflate Apple's Compression speaks: the
/// two-byte header and the Adler-32 trailer by hand.
enum Zlib {
  static func adler32(_ data: [UInt8]) -> UInt32 {
    var a: UInt32 = 1
    var b: UInt32 = 0
    for byte in data {
      a = (a + UInt32(byte)) % 65521
      b = (b + a) % 65521
    }
    return b << 16 | a
  }

  static func compress(_ data: [UInt8]) -> [UInt8] {
    var raw: [UInt8] = [0x03, 0x00]  // an empty final fixed-Huffman block
    if !data.isEmpty {
      var out = [UInt8](repeating: 0, count: data.count + data.count / 8 + 64)
      let n = compression_encode_buffer(&out, out.count, data, data.count, nil, COMPRESSION_ZLIB)
      raw = Array(out[0..<n])
    }
    let adler = adler32(data)
    return [0x78, 0x9C] + raw + [
      UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF),
      UInt8(adler & 0xFF),
    ]
  }

  static func decompress(_ z: [UInt8], limit: Int = 16 << 20) throws -> [UInt8] {
    guard z.count >= 6, z[0] & 0x0F == 8, (UInt16(z[0]) << 8 | UInt16(z[1])) % 31 == 0,
      z[1] & 0x20 == 0
    else {
      throw MoshError(description: "not a zlib stream")
    }
    let raw = Array(z[2..<(z.count - 4)])
    let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
    defer { stream.deallocate() }
    guard
      compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB)
        == COMPRESSION_STATUS_OK
    else {
      throw MoshError(description: "inflate init")
    }
    defer { compression_stream_destroy(stream) }
    var out: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 65536)
    try raw.withUnsafeBufferPointer { src in
      stream.pointee.src_ptr = src.baseAddress!
      stream.pointee.src_size = src.count
      while true {
        let status = chunk.withUnsafeMutableBufferPointer { dst -> compression_status in
          stream.pointee.dst_ptr = dst.baseAddress!
          stream.pointee.dst_size = dst.count
          return compression_stream_process(stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
        }
        out += chunk[0..<(chunk.count - stream.pointee.dst_size)]
        if out.count > limit {
          throw MoshError(description: "inflated past \(limit) bytes")
        }
        if status == COMPRESSION_STATUS_END {
          return
        }
        if status != COMPRESSION_STATUS_OK {
          throw MoshError(description: "corrupt deflate data")
        }
      }
    }
    let trailer = z[(z.count - 4)...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    guard trailer == adler32(out) else { throw MoshError(description: "zlib checksum") }
    return out
  }
}

/// The protobuf wire format, only as much of it as Mosh's messages use.
struct ProtoWriter {
  var bytes: [UInt8] = []

  mutating func varint(_ v: UInt64) {
    var x = v
    while x >= 0x80 {
      bytes.append(UInt8(x & 0x7F) | 0x80)
      x >>= 7
    }
    bytes.append(UInt8(x))
  }

  mutating func field(_ number: UInt64, varint v: UInt64) {
    varint(number << 3)
    varint(v)
  }

  mutating func field(_ number: UInt64, bytes b: [UInt8]) {
    varint(number << 3 | 2)
    varint(UInt64(b.count))
    bytes += b
  }
}

struct ProtoReader {
  enum Value {
    case varint(UInt64)
    case bytes([UInt8])
  }

  let data: [UInt8]
  var pos = 0

  init(_ data: [UInt8]) { self.data = data }

  private mutating func varint() throws -> UInt64 {
    var v: UInt64 = 0
    var shift: UInt64 = 0
    while true {
      guard pos < data.count, shift < 64 else { throw MoshError(description: "bad varint") }
      let b = data[pos]
      pos += 1
      v |= UInt64(b & 0x7F) << shift
      if b & 0x80 == 0 {
        return v
      }
      shift += 7
    }
  }

  /// The next field, or nil at the end; fixed-width fields are skipped.
  mutating func next() throws -> (UInt64, Value)? {
    while pos < data.count {
      let key = try varint()
      switch key & 7 {
      case 0:
        return (key >> 3, .varint(try varint()))
      case 2:
        let n = Int(try varint())
        guard n <= data.count - pos else { throw MoshError(description: "field past the end") }
        pos += n
        return (key >> 3, .bytes(Array(data[(pos - n)..<pos])))
      case 1:
        pos += 8
      case 5:
        pos += 4
      default:
        throw MoshError(description: "unknown wire type \(key & 7)")
      }
      guard pos <= data.count else { throw MoshError(description: "field past the end") }
    }
    return nil
  }
}

/// TransportBuffers.Instruction.
struct Instruction: Equatable {
  var oldNum: UInt64 = 0
  var newNum: UInt64 = 0
  var ackNum: UInt64 = 0
  var throwawayNum: UInt64 = 0
  var diff: [UInt8] = []

  static let version: UInt64 = 2

  func encode() -> [UInt8] {
    var w = ProtoWriter()
    w.field(1, varint: Instruction.version)
    w.field(2, varint: oldNum)
    w.field(3, varint: newNum)
    w.field(4, varint: ackNum)
    w.field(5, varint: throwawayNum)
    w.field(6, bytes: diff)
    return w.bytes
  }

  static func decode(_ data: [UInt8]) throws -> Instruction {
    var r = ProtoReader(data)
    var i = Instruction()
    while let (field, value) = try r.next() {
      switch (field, value) {
      case (1, .varint(let v)) where v != version:
        throw MoshError(description: "mosh protocol version \(v), this client speaks \(version)")
      case (2, .varint(let v)): i.oldNum = v
      case (3, .varint(let v)): i.newNum = v
      case (4, .varint(let v)): i.ackNum = v
      case (5, .varint(let v)): i.throwawayNum = v
      case (6, .bytes(let b)): i.diff = b
      default: break
      }
    }
    return i
  }
}

enum UserEvent: Equatable {
  case keys([UInt8])
  case resize(cols: Int, rows: Int)
}

/// ClientBuffers.UserMessage for a run of events.
func encodeUser(_ events: ArraySlice<UserEvent>) -> [UInt8] {
  var msg = ProtoWriter()
  for e in events {
    var inst = ProtoWriter()
    switch e {
    case .keys(let k):
      var ks = ProtoWriter()
      ks.field(4, bytes: k)
      inst.field(2, bytes: ks.bytes)
    case .resize(let cols, let rows):
      var rs = ProtoWriter()
      rs.field(5, varint: UInt64(cols))
      rs.field(6, varint: UInt64(rows))
      inst.field(3, bytes: rs.bytes)
    }
    msg.field(1, bytes: inst.bytes)
  }
  return msg.bytes
}

enum HostEvent: Equatable {
  case bytes([UInt8])
  case resize(cols: Int, rows: Int)
  case echoAck(UInt64)  // the newest input state the server has echoed
}

/// HostBuffers.HostMessage.
func decodeHost(_ data: [UInt8]) throws -> [HostEvent] {
  var out: [HostEvent] = []
  var msg = ProtoReader(data)
  while let (field, value) = try msg.next() {
    guard field == 1, case .bytes(let inst) = value else { continue }
    var ir = ProtoReader(inst)
    while let (f, v) = try ir.next() {
      guard case .bytes(let body) = v else { continue }
      var br = ProtoReader(body)
      switch f {
      case 2:
        while let (bf, bv) = try br.next() {
          if bf == 4, case .bytes(let s) = bv {
            out.append(.bytes(s))
          }
        }
      case 3:
        var w = 80
        var h = 24
        while let (bf, bv) = try br.next() {
          if case .varint(let n) = bv, n <= 10000 {
            if bf == 5 { w = Int(n) }
            if bf == 6 { h = Int(n) }
          }
        }
        out.append(.resize(cols: w, rows: h))
      case 7:
        while let (bf, bv) = try br.next() {
          if bf == 8, case .varint(let n) = bv {
            out.append(.echoAck(n))
          }
        }
      default:
        break
      }
    }
  }
  return out
}
