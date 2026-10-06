import Testing

@testable import FosforoMosh

private func hex(_ s: String) -> [UInt8] {
  var out: [UInt8] = []
  var i = s.startIndex
  while i < s.endIndex {
    let j = s.index(i, offsetBy: 2)
    out.append(UInt8(s[i..<j], radix: 16)!)
    i = j
  }
  return out
}

/// RFC 7253 appendix A, the cases with empty associated data.
@Test func ocbMatchesRFC7253() throws {
  let ocb = try #require(OCB(key: hex("000102030405060708090A0B0C0D0E0F")))
  let cases: [(nonce: String, plain: String, sealed: String)] = [
    ("BBAA99887766554433221100", "", "785407BFFFC8AD9EDCC5520AC9111EE6"),
    (
      "BBAA99887766554433221103", "0001020304050607",
      "45DD69F8F5AAE72414054CD1F35D82760B2CD00D2F99BFA9"
    ),
  ]
  for c in cases {
    #expect(ocb.seal(hex(c.plain), nonce: hex(c.nonce)) == hex(c.sealed), "\(c.nonce)")
    #expect(ocb.open(hex(c.sealed), nonce: hex(c.nonce)) == hex(c.plain))
  }
}

@Test func ocbRoundTripsAndRejectsTampering() throws {
  let ocb = try #require(OCB(key: Array(0..<16)))
  for n in [0, 1, 15, 16, 17, 31, 32, 33, 100, 1000] {
    let plain = (0..<n).map { UInt8(truncatingIfNeeded: $0 &* 7) }
    let nonce = [UInt8](repeating: 0, count: 4) + (0..<8).map { UInt8($0 + n % 5) }
    var sealed = ocb.seal(plain, nonce: nonce)
    #expect(sealed.count == n + 16)
    #expect(ocb.open(sealed, nonce: nonce) == plain)
    sealed[sealed.count / 2] ^= 1
    #expect(ocb.open(sealed, nonce: nonce) == nil)
  }
}
