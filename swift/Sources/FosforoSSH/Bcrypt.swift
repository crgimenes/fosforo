import CryptoKit
import Foundation

/// Blowfish as bcrypt uses it (the "eks" key schedule), for bcrypt_pbkdf,
/// which is how ssh-keygen turns a passphrase into the key that protects a
/// private key file. Mirrors OpenBSD's blowfish.c and bcrypt_pbkdf.c.
struct Blowfish {
  var p = blowfishP
  var s = blowfishS.flatMap { $0 }  // 4 x 256, flat

  private func f(_ x: UInt32) -> UInt32 {
    let a = s[Int(x >> 24)]
    let b = s[256 + Int((x >> 16) & 0xFF)]
    let c = s[512 + Int((x >> 8) & 0xFF)]
    let d = s[768 + Int(x & 0xFF)]
    return ((a &+ b) ^ c) &+ d
  }

  func encipher(_ l: inout UInt32, _ r: inout UInt32) {
    var xl = l ^ p[0]
    var xr = r
    var i = 1
    while i <= 16 {
      xr ^= f(xl) ^ p[i]
      xl ^= f(xr) ^ p[i + 1]
      i += 2
    }
    l = xr ^ p[17]
    r = xl
  }

  /// Four bytes of data as a big-endian word, wrapping around its end.
  private static func word(_ data: [UInt8], _ j: inout Int) -> UInt32 {
    var w: UInt32 = 0
    for _ in 0..<4 {
      if j >= data.count {
        j = 0
      }
      w = w << 8 | UInt32(data[j])
      j += 1
    }
    return w
  }

  /// Blowfish_expandstate (salt given) and Blowfish_expand0state (none).
  mutating func expand(key: [UInt8], salt: [UInt8]?) {
    var j = 0
    for i in 0..<18 {
      p[i] ^= Blowfish.word(key, &j)
    }
    j = 0
    var l: UInt32 = 0
    var r: UInt32 = 0
    func next() {
      if let salt {
        l ^= Blowfish.word(salt, &j)
        r ^= Blowfish.word(salt, &j)
      }
      encipher(&l, &r)
    }
    for i in stride(from: 0, to: 18, by: 2) {
      next()
      p[i] = l
      p[i + 1] = r
    }
    for i in stride(from: 0, to: 1024, by: 2) {
      next()
      s[i] = l
      s[i + 1] = r
    }
  }
}

enum BcryptPBKDF {
  private static func hash(_ sha2pass: [UInt8], _ sha2salt: [UInt8]) -> [UInt8] {
    var bf = Blowfish()
    bf.expand(key: sha2pass, salt: sha2salt)
    for _ in 0..<64 {
      bf.expand(key: sha2salt, salt: nil)
      bf.expand(key: sha2pass, salt: nil)
    }
    let magic = Array("OxychromaticBlowfishSwatDynamite".utf8)
    var words = (0..<8).map { i in
      magic[(i * 4)..<(i * 4 + 4)].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
    for _ in 0..<64 {
      for k in stride(from: 0, to: 8, by: 2) {
        var l = words[k]
        var r = words[k + 1]
        bf.encipher(&l, &r)
        words[k] = l
        words[k + 1] = r
      }
    }
    var out: [UInt8] = []
    for w in words {  // little-endian here, unlike everything else in bcrypt
      out += [UInt8(w & 0xFF), UInt8((w >> 8) & 0xFF), UInt8((w >> 16) & 0xFF), UInt8(w >> 24)]
    }
    return out
  }

  static func derive(password: [UInt8], salt: [UInt8], rounds: Int, length: Int) -> [UInt8] {
    let stride = (length + 31) / 32
    let amount = (length + stride - 1) / stride
    let sha2pass = Array(SHA512.hash(data: password))
    var key = [UInt8](repeating: 0, count: length)
    var remaining = length
    var count: UInt32 = 1
    while remaining > 0 {
      let countSalt =
        salt + [
          UInt8(count >> 24), UInt8((count >> 16) & 0xFF), UInt8((count >> 8) & 0xFF),
          UInt8(count & 0xFF),
        ]
      var tmp = hash(sha2pass, Array(SHA512.hash(data: countSalt)))
      var out = tmp
      for _ in 1..<max(rounds, 1) {
        tmp = hash(sha2pass, Array(SHA512.hash(data: tmp)))
        for i in 0..<32 {
          out[i] ^= tmp[i]
        }
      }
      let n = min(amount, remaining)
      var i = 0
      while i < n {
        let dest = i * stride + Int(count - 1)
        if dest >= length {
          break
        }
        key[dest] = out[i]
        i += 1
      }
      remaining -= i
      count += 1
    }
    return key
  }
}
