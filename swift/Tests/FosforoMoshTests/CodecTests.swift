import Testing

@testable import FosforoMosh

@Test func zlibRoundTripsAndReadsZlib() throws {
  for n in [0, 1, 100, 70000] {
    let data = (0..<n).map { UInt8(truncatingIfNeeded: $0 % 251) }
    do {
      #expect(try Zlib.decompress(Zlib.compress(data)) == data, "n=\(n)")
    } catch {
      Issue.record("n=\(n): \(error)")
    }
  }
  // python3 -c 'import zlib;print(zlib.compress(b"fosforo "*4).hex())'
  let fromPython: [UInt8] = [
    0x78, 0x9c, 0x4b, 0xcb, 0x2f, 0x4e, 0xcb, 0x2f, 0xca, 0x57, 0x48, 0xc3, 0x41, 0x03, 0x00,
    0xd1, 0xa4, 0x0c, 0x79,
  ]
  #expect(
    String(decoding: try Zlib.decompress(fromPython), as: UTF8.self)
      == "fosforo fosforo fosforo fosforo ")
  var bad = Zlib.compress([1, 2, 3])
  bad[bad.count - 1] ^= 1
  #expect(throws: MoshError.self) { try Zlib.decompress(bad) }
}

@Test func instructionRoundTrips() throws {
  let i = Instruction(oldNum: 3, newNum: 7, ackNum: 1 << 40, throwawayNum: 2, diff: [1, 2, 3])
  #expect(try Instruction.decode(i.encode()) == i)
  var w = ProtoWriter()
  w.field(1, varint: 3)
  #expect(throws: MoshError.self) { try Instruction.decode(w.bytes) }
}

@Test func userAndHostMessages() throws {
  let user = encodeUser([.keys([0x61, 0x62]), .resize(cols: 100, rows: 30)][...])
  #expect(user.count > 8)
  var inst = ProtoWriter()
  var hb = ProtoWriter()
  hb.field(4, bytes: Array("hi".utf8))
  inst.field(2, bytes: hb.bytes)
  var rs = ProtoWriter()
  rs.field(5, varint: 120)
  rs.field(6, varint: 40)
  var inst2 = ProtoWriter()
  inst2.field(3, bytes: rs.bytes)
  var msg = ProtoWriter()
  msg.field(1, bytes: inst2.bytes)
  msg.field(1, bytes: inst.bytes)
  #expect(try decodeHost(msg.bytes) == [.resize(cols: 120, rows: 40), .bytes(Array("hi".utf8))])
}
