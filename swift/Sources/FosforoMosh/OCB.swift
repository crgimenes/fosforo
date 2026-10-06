import CommonCrypto
import Foundation

/// AES-128-OCB3 (RFC 7253) with a 96-bit nonce, 128-bit tag and no
/// associated data: exactly what Mosh uses. CryptoKit has no OCB; the AES
/// block function comes from CommonCrypto.
final class OCB {
  private let enc: CCCryptorRef
  private let dec: CCCryptorRef
  private let lStar: [UInt8]
  private let lDollar: [UInt8]
  private var l: [[UInt8]]

  init?(key: [UInt8]) {
    guard key.count == 16 else { return nil }
    var e: CCCryptorRef?
    var d: CCCryptorRef?
    let ok1 = CCCryptorCreate(
      CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, 16,
      nil, &e)
    let ok2 = CCCryptorCreate(
      CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, 16,
      nil, &d)
    guard ok1 == kCCSuccess, ok2 == kCCSuccess, let e, let d else {
      if let e { CCCryptorRelease(e) }
      if let d { CCCryptorRelease(d) }
      return nil
    }
    enc = e
    dec = d
    lStar = OCB.block(e, [UInt8](repeating: 0, count: 16))
    lDollar = OCB.double(lStar)
    l = [OCB.double(lDollar)]
  }

  deinit {
    CCCryptorRelease(enc)
    CCCryptorRelease(dec)
  }

  private static func block(_ c: CCCryptorRef, _ input: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 16)
    var moved = 0
    _ = CCCryptorUpdate(c, input, 16, &out, 16, &moved)
    return out
  }

  /// Multiplication by x in GF(2^128) (RFC 7253 section 2).
  private static func double(_ s: [UInt8]) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: 16)
    for i in 0..<16 {
      out[i] = s[i] << 1 | (i < 15 ? s[i + 1] >> 7 : 0)
    }
    if s[0] & 0x80 != 0 {
      out[15] ^= 0x87
    }
    return out
  }

  private static func xor(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
    var out = a
    for i in 0..<min(a.count, b.count) {
      out[i] ^= b[i]
    }
    return out
  }

  private func lAt(_ i: Int) -> [UInt8] {
    while l.count <= i {
      l.append(OCB.double(l[l.count - 1]))
    }
    return l[i]
  }

  private func initialOffset(_ nonce: [UInt8]) -> [UInt8] {
    var n = [0, 0, 0, 1] + nonce  // taglen 128 → first 7 bits zero; the 1 bit before N
    let bottom = Int(n[15] & 0x3F)
    n[15] &= 0xC0
    let ktop = OCB.block(enc, n)
    var stretch = ktop
    for i in 0..<8 {
      stretch.append(ktop[i] ^ ktop[i + 1])
    }
    let byteShift = bottom / 8
    let bitShift = bottom % 8
    var offset = [UInt8](repeating: 0, count: 16)
    for i in 0..<16 {
      let hi = stretch[i + byteShift] << bitShift
      let lo = bitShift == 0 ? 0 : stretch[i + byteShift + 1] >> (8 - bitShift)
      offset[i] = hi | lo
    }
    return offset
  }

  func seal(_ plain: [UInt8], nonce: [UInt8]) -> [UInt8] {
    var offset = initialOffset(nonce)
    var checksum = [UInt8](repeating: 0, count: 16)
    var out: [UInt8] = []
    out.reserveCapacity(plain.count + 16)
    let full = plain.count / 16
    for i in 0..<full {
      let p = Array(plain[i * 16..<i * 16 + 16])
      offset = OCB.xor(offset, lAt((i + 1).trailingZeroBitCount))
      out += OCB.xor(offset, OCB.block(enc, OCB.xor(p, offset)))
      checksum = OCB.xor(checksum, p)
    }
    let rest = Array(plain[(full * 16)...])
    if !rest.isEmpty {
      offset = OCB.xor(offset, lStar)
      let pad = OCB.block(enc, offset)
      out += OCB.xor(rest, pad)
      var padded = rest + [0x80]
      padded += [UInt8](repeating: 0, count: 16 - padded.count)
      checksum = OCB.xor(checksum, padded)
    }
    out += OCB.block(enc, OCB.xor(OCB.xor(checksum, offset), lDollar))
    return out
  }

  /// nil when the tag does not authenticate.
  func open(_ sealed: [UInt8], nonce: [UInt8]) -> [UInt8]? {
    guard sealed.count >= 16 else { return nil }
    let body = Array(sealed[0..<sealed.count - 16])
    let tag = Array(sealed[(sealed.count - 16)...])
    var offset = initialOffset(nonce)
    var checksum = [UInt8](repeating: 0, count: 16)
    var out: [UInt8] = []
    out.reserveCapacity(body.count)
    let full = body.count / 16
    for i in 0..<full {
      let c = Array(body[i * 16..<i * 16 + 16])
      offset = OCB.xor(offset, lAt((i + 1).trailingZeroBitCount))
      let p = OCB.xor(offset, OCB.block(dec, OCB.xor(c, offset)))
      out += p
      checksum = OCB.xor(checksum, p)
    }
    let rest = Array(body[(full * 16)...])
    if !rest.isEmpty {
      offset = OCB.xor(offset, lStar)
      let p = OCB.xor(rest, OCB.block(enc, offset))
      out += p
      var padded = p + [0x80]
      padded += [UInt8](repeating: 0, count: 16 - padded.count)
      checksum = OCB.xor(checksum, padded)
    }
    let want = OCB.block(enc, OCB.xor(OCB.xor(checksum, offset), lDollar))
    var diff: UInt8 = 0
    for i in 0..<16 {
      diff |= want[i] ^ tag[i]
    }
    return diff == 0 ? out : nil
  }
}
