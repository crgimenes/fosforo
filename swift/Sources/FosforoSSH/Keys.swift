import CommonCrypto
import CryptoKit
import Foundation
import Security

/// A user key for publickey authentication.
public struct PrivateKey: @unchecked Sendable {
  let algorithm: String
  let publicBlob: [UInt8]
  let sign: ([UInt8]) throws -> [UInt8]  // returns the signature blob

  /// Whether an OpenSSH private key file is protected by a passphrase.
  public static func isEncrypted(_ text: String) -> Bool {
    if text.contains(pemBegin) {
      return text.contains("Proc-Type: 4,ENCRYPTED")
    }
    guard let bytes = try? container(text) else { return false }
    var r = SSHReader(bytes)
    return (try? r.text()) != "none"
  }

  private static let magic = Array("openssh-key-v1\0".utf8)

  private static func container(_ text: String) throws -> [UInt8] {
    let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
    let end = "-----END OPENSSH PRIVATE KEY-----"
    guard let b = text.range(of: begin), let e = text.range(of: end), b.upperBound < e.lowerBound,
      let data = Data(
        base64Encoded: text[b.upperBound..<e.lowerBound].filter { !$0.isWhitespace }.description)
    else {
      throw SSHError.auth("not an OpenSSH private key")
    }
    let bytes = [UInt8](data)
    guard bytes.starts(with: magic) else { throw SSHError.auth("not an OpenSSH private key") }
    return Array(bytes[magic.count...])
  }

  /// A private key file in any format we read: OpenSSH's own, or the
  /// older PEM RSA ("BEGIN RSA PRIVATE KEY") many existing keys still use.
  public static func load(_ text: String, passphrase: String? = nil) throws -> PrivateKey {
    if text.contains(pemBegin) {
      return try pemRSA(text, passphrase: passphrase)
    }
    return try openSSH(text, passphrase: passphrase)
  }

  /// A key file whose public half is known without opening it (the
  /// OpenSSH container carries it in the clear; a PEM key has its .pub),
  /// so the server can be asked about it first. The private half is opened
  /// only to sign; a locked one throws SSHError.locked(name) unless the
  /// passphrase is given.
  public static func deferred(_ text: String, pub: String?, name: String, passphrase: String?)
    throws -> PrivateKey
  {
    guard PrivateKey.isEncrypted(text), passphrase == nil else {
      return try load(text, passphrase: passphrase)
    }
    var blob: [UInt8]
    if text.contains(pemBegin) {
      let fields = (pub ?? "").split(separator: " ")
      guard fields.count >= 2, let data = Data(base64Encoded: String(fields[1])) else {
        throw SSHError.locked(name)  // nothing to ask the server with: the passphrase first
      }
      blob = [UInt8](data)
    } else {
      var r = SSHReader(try container(text))
      for _ in 0..<3 {
        _ = try r.string()  // cipher, kdf, kdf options
      }
      _ = try r.u32()
      blob = try r.string()
    }
    var b = SSHReader(blob)
    let type = try b.text()
    let algorithm = type == "ssh-rsa" ? "rsa-sha2-512" : type
    return PrivateKey(algorithm: algorithm, publicBlob: blob) { _ in throw SSHError.locked(name) }
  }

  /// A key kept by the Vault: offered by the public key its file shows,
  /// opened (once per session, asking for the owner) only to sign.
  public static func protected(
    publicLine: String, name: String, passphrase: String?, open: @escaping () throws -> String
  ) throws -> PrivateKey {
    let fields = publicLine.split(separator: " ")
    guard fields.count >= 2, let data = Data(base64Encoded: String(fields[1])) else {
      throw SSHError.auth("\(name): protected key without its public line")
    }
    let blob = [UInt8](data)
    var r = SSHReader(blob)
    let type = try r.text()
    return PrivateKey(algorithm: type == "ssh-rsa" ? "rsa-sha2-512" : type, publicBlob: blob) {
      data in
      let text = try open()
      if isEncrypted(text) && passphrase == nil {
        throw SSHError.locked(name)
      }
      return try load(text, passphrase: passphrase).sign(data)
    }
  }

  /// The same key, with something to do when it is about to sign (a
  /// warning, say).
  public func onSign(_ before: @escaping () -> Void) -> PrivateKey {
    let inner = sign
    return PrivateKey(algorithm: algorithm, publicBlob: publicBlob) { data in
      before()
      return try inner(data)
    }
  }

  /// Whether the text is a private key file we can try to load.
  public static func isPrivateKey(_ text: String) -> Bool {
    text.contains("-----BEGIN OPENSSH PRIVATE KEY-----") || text.contains(pemBegin)
  }

  private static let pemBegin = "-----BEGIN RSA PRIVATE KEY-----"

  /// PEM RSA, plain or with OpenSSL's traditional encryption: headers
  /// "Proc-Type: 4,ENCRYPTED" and "DEK-Info: <cipher>,<hex iv>", the key
  /// derived from the passphrase by EVP_BytesToKey (MD5, one round, the
  /// first 8 bytes of the iv as salt). Inside, PKCS#1 RSAPrivateKey DER.
  static func pemRSA(_ text: String, passphrase: String?) throws -> PrivateKey {
    let end = "-----END RSA PRIVATE KEY-----"
    guard let b = text.range(of: pemBegin), let e = text.range(of: end),
      b.upperBound < e.lowerBound
    else {
      throw SSHError.auth("not a PEM RSA key")
    }
    var headers: [String: String] = [:]
    var body = ""
    for line in text[b.upperBound..<e.lowerBound].split(whereSeparator: \.isNewline) {
      if let colon = line.firstIndex(of: ":") {
        headers[String(line[..<colon])] = line[line.index(after: colon)...]
          .trimmingCharacters(in: .whitespaces)
      } else {
        body += line.filter { !$0.isWhitespace }
      }
    }
    guard let data = Data(base64Encoded: body) else { throw SSHError.auth("corrupt PEM key") }
    var der = [UInt8](data)
    if headers["Proc-Type"]?.hasSuffix("ENCRYPTED") == true {
      guard let passphrase else { throw SSHError.auth("passphrase needed") }
      der = try pemDecrypt(der, info: headers["DEK-Info"] ?? "", passphrase: passphrase)
    }
    var r = DERReader(der)
    let ints: [[UInt8]]
    do {
      var seq = DERReader(try r.sequence())
      ints = try (0..<9).map { _ in try seq.integer() }  // version n e d p q dp dq qinv
    } catch {
      // a wrong passphrase can still unpad cleanly (1 in 256); the DER says no
      throw SSHError.auth(passphrase == nil ? "corrupt PEM key" : "wrong passphrase")
    }
    guard ints[0] == [0] || ints[0].isEmpty else { throw SSHError.unsupported("multi-prime RSA") }
    return try rsa(n: ints[1], e: ints[2], d: ints[3], p: ints[4], q: ints[5], iqmp: ints[8])
  }

  private static func pemDecrypt(_ data: [UInt8], info: String, passphrase: String) throws
    -> [UInt8]
  {
    let parts = info.split(separator: ",")
    let ciphers: [String: (alg: CCAlgorithm, key: Int, block: Int)] = [
      "AES-128-CBC": (CCAlgorithm(kCCAlgorithmAES), 16, 16),
      "AES-192-CBC": (CCAlgorithm(kCCAlgorithmAES), 24, 16),
      "AES-256-CBC": (CCAlgorithm(kCCAlgorithmAES), 32, 16),
      "DES-EDE3-CBC": (CCAlgorithm(kCCAlgorithm3DES), 24, 8),
    ]
    guard parts.count == 2, let c = ciphers[String(parts[0])],
      let iv = hexBytes(String(parts[1])), iv.count == c.block
    else {
      throw SSHError.unsupported("PEM encryption \(info)")
    }
    // EVP_BytesToKey: D1 = MD5(pass || salt), Di = MD5(Di-1 || pass || salt)
    let pass = Array(passphrase.utf8)
    var key: [UInt8] = []
    var last: [UInt8] = []
    while key.count < c.key {
      last = Array(Insecure.MD5.hash(data: last + pass + iv[0..<8]))
      key += last
    }
    key = Array(key[0..<c.key])
    var out = [UInt8](repeating: 0, count: data.count + c.block)
    var moved = 0
    let status = CCCrypt(
      CCOperation(kCCDecrypt), c.alg, CCOptions(kCCOptionPKCS7Padding), key, key.count, iv,
      data, data.count, &out, out.count, &moved)
    guard status == kCCSuccess else { throw SSHError.auth("wrong passphrase") }
    return Array(out[0..<moved])
  }

  private static func hexBytes(_ s: String) -> [UInt8]? {
    guard s.count % 2 == 0 else { return nil }
    var out: [UInt8] = []
    var i = s.startIndex
    while i < s.endIndex {
      let j = s.index(i, offsetBy: 2)
      guard let b = UInt8(s[i..<j], radix: 16) else { return nil }
      out.append(b)
      i = j
    }
    return out
  }

  /// OpenSSH's private key file ("BEGIN OPENSSH PRIVATE KEY"): ed25519,
  /// ECDSA (P-256, P-384, P-521) or RSA, plain or protected by a passphrase (bcrypt_pbkdf with
  /// aes256-ctr, ssh-keygen's default, or aes256-gcm).
  public static func openSSH(_ text: String, passphrase: String? = nil) throws -> PrivateKey {
    var r = SSHReader(try container(text))
    let cipher = try r.text()
    let kdf = try r.text()
    var opts = SSHReader(try r.string())
    guard try r.u32() == 1 else { throw SSHError.unsupported("files with more than one key") }
    _ = try r.string()  // public key, repeated inside
    var block = try r.string()
    if cipher != "none" {
      guard kdf == "bcrypt" else { throw SSHError.unsupported("key derivation \(kdf)") }
      guard let passphrase else { throw SSHError.auth("passphrase needed") }
      let salt = try opts.string()
      let rounds = Int(try opts.u32())
      guard (1...1000).contains(rounds) else {
        throw SSHError.auth("implausible kdf rounds \(rounds)")
      }
      block = try decrypt(
        block, cipher: cipher, tag: r, passphrase: passphrase, salt: salt, rounds: rounds)
    }
    var p = SSHReader(block)
    guard try p.u32() == p.u32() else {
      throw SSHError.auth(cipher == "none" ? "corrupt private key" : "wrong passphrase")
    }
    let type = try p.text()
    switch type {
    case "ssh-ed25519":
      let pub = try p.string()
      let priv = try p.string()  // seed || public
      guard pub.count == 32, priv.count == 64 else { throw SSHError.auth("corrupt ed25519 key") }
      return ed25519(try Curve25519.Signing.PrivateKey(rawRepresentation: priv[0..<32]))
    case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
      _ = try p.string()  // curve name
      _ = try p.string()  // public point
      return try ecdsa(type, scalar: try p.mpint())
    case "ssh-rsa":
      let n = try p.mpint()
      let e = try p.mpint()
      let d = try p.mpint()
      let iqmp = try p.mpint()
      let pp = try p.mpint()
      let q = try p.mpint()
      return try rsa(n: n, e: e, d: d, p: pp, q: q, iqmp: iqmp)
    default:
      throw SSHError.unsupported("\(type) user keys")
    }
  }

  private static func decrypt(
    _ block: [UInt8], cipher: String, tag after: SSHReader, passphrase: String, salt: [UInt8],
    rounds: Int
  ) throws -> [UInt8] {
    let pass = Array(passphrase.utf8)
    switch cipher {
    case "aes256-ctr":
      let kiv = BcryptPBKDF.derive(password: pass, salt: salt, rounds: rounds, length: 48)
      return try aesCTR(block, key: Array(kiv[0..<32]), iv: Array(kiv[32..<48]))
    case "aes256-gcm@openssh.com":
      // the 16-byte tag follows the private block, outside its string
      let kiv = BcryptPBKDF.derive(password: pass, salt: salt, rounds: rounds, length: 44)
      guard after.remaining >= 16 else { throw SSHError.auth("truncated key") }
      let tag = after.bytes[after.pos..<(after.pos + 16)]
      do {
        let box = try AES.GCM.SealedBox(
          nonce: AES.GCM.Nonce(data: kiv[32..<44]), ciphertext: block, tag: tag)
        return Array(try AES.GCM.open(box, using: SymmetricKey(data: kiv[0..<32])))
      } catch {
        throw SSHError.auth("wrong passphrase")
      }
    default:
      throw SSHError.unsupported("key cipher \(cipher)")
    }
  }

  private static func aesCTR(_ data: [UInt8], key: [UInt8], iv: [UInt8]) throws -> [UInt8] {
    var ref: CCCryptorRef?
    let ok = CCCryptorCreateWithMode(
      CCOperation(kCCDecrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES),
      CCPadding(ccNoPadding), iv, key, key.count, nil, 0, 0,
      CCModeOptions(kCCModeOptionCTR_BE), &ref)
    guard ok == kCCSuccess, let ref else { throw SSHError.auth("aes-ctr") }
    defer { CCCryptorRelease(ref) }
    var out = [UInt8](repeating: 0, count: data.count)
    var moved = 0
    guard CCCryptorUpdate(ref, data, data.count, &out, out.count, &moved) == kCCSuccess else {
      throw SSHError.auth("aes-ctr")
    }
    return out
  }

  public static func ed25519(_ key: Curve25519.Signing.PrivateKey) -> PrivateKey {
    var blob = SSHWriter()
    blob.string("ssh-ed25519")
    blob.string(Array(key.publicKey.rawRepresentation))
    return PrivateKey(algorithm: "ssh-ed25519", publicBlob: blob.bytes) { data in
      var sig = SSHWriter()
      sig.string("ssh-ed25519")
      sig.string(Array(try key.signature(for: data)))
      return sig.bytes
    }
  }

  /// ecdsa-sha2-nistp256 from any P-256 signer: a software key or one held
  /// by the Secure Enclave, which signs without the key ever leaving it.
  public static func p256(
    publicKey: P256.Signing.PublicKey,
    sign: @escaping ([UInt8]) throws -> P256.Signing.ECDSASignature
  ) -> PrivateKey {
    var blob = SSHWriter()
    blob.string("ecdsa-sha2-nistp256")
    blob.string("nistp256")
    blob.string(Array(publicKey.x963Representation))
    return PrivateKey(algorithm: "ecdsa-sha2-nistp256", publicBlob: blob.bytes) { data in
      let raw = Array(try sign(data).rawRepresentation)  // r || s
      var rs = SSHWriter()
      rs.mpint(Array(raw[0..<32]))
      rs.mpint(Array(raw[32..<64]))
      var sig = SSHWriter()
      sig.string("ecdsa-sha2-nistp256")
      sig.string(rs.bytes)
      return sig.bytes
    }
  }

  /// An ECDSA key from its private scalar: P-256, P-384 or P-521, each
  /// signing with the hash its SSH name implies (SHA-256, -384, -512).
  static func ecdsa(_ type: String, scalar d: [UInt8]) throws -> PrivateKey {
    let size = ["ecdsa-sha2-nistp256": 32, "ecdsa-sha2-nistp384": 48, "ecdsa-sha2-nistp521": 66][
      type]
    guard let size, d.count <= size else { throw SSHError.auth("corrupt ECDSA key") }
    let raw = [UInt8](repeating: 0, count: size - d.count) + d
    switch size {
    case 32:
      return p256(try P256.Signing.PrivateKey(rawRepresentation: raw))
    case 48:
      let key = try P384.Signing.PrivateKey(rawRepresentation: raw)
      return ecdsa(type, curve: "nistp384", point: Array(key.publicKey.x963Representation)) {
        Array(try key.signature(for: $0).rawRepresentation)
      }
    default:
      let key = try P521.Signing.PrivateKey(rawRepresentation: raw)
      return ecdsa(type, curve: "nistp521", point: Array(key.publicKey.x963Representation)) {
        Array(try key.signature(for: $0).rawRepresentation)
      }
    }
  }

  /// The SSH wrapping of an ECDSA signer whose signature is r || s.
  private static func ecdsa(
    _ type: String, curve: String, point: [UInt8], sign: @escaping ([UInt8]) throws -> [UInt8]
  ) -> PrivateKey {
    var blob = SSHWriter()
    blob.string(type)
    blob.string(curve)
    blob.string(point)
    return PrivateKey(algorithm: type, publicBlob: blob.bytes) { data in
      let raw = try sign(data)
      let half = raw.count / 2
      var rs = SSHWriter()
      rs.mpint(Array(raw[0..<half]))
      rs.mpint(Array(raw[half...]))
      var sig = SSHWriter()
      sig.string(type)
      sig.string(rs.bytes)
      return sig.bytes
    }
  }

  public static func p256(_ key: P256.Signing.PrivateKey) -> PrivateKey {
    p256(publicKey: key.publicKey) { try key.signature(for: $0) }
  }

  public static func secureEnclave(_ key: SecureEnclave.P256.Signing.PrivateKey) -> PrivateKey {
    p256(publicKey: key.publicKey) { try key.signature(for: $0) }
  }

  /// RSA signs with SHA-512 (rsa-sha2-512, RFC 8332); SHA-1 ssh-rsa
  /// signatures are refused by current servers anyway.
  static func rsa(n: [UInt8], e: [UInt8], d: [UInt8], p: [UInt8], q: [UInt8], iqmp: [UInt8])
    throws -> PrivateKey
  {
    guard n.count >= 256, !p.isEmpty, !q.isEmpty else {
      throw SSHError.auth("RSA key under 2048 bits")
    }
    // PKCS#1 wants the CRT exponents the OpenSSH file leaves out
    let body =
      derInteger([0]) + derInteger(n) + derInteger(e) + derInteger(d) + derInteger(p)
      + derInteger(q) + derInteger(bigMod(d, minusOne(p))) + derInteger(bigMod(d, minusOne(q)))
      + derInteger(iqmp)
    let der = [0x30] + derLength(body.count) + body
    let attrs: [CFString: Any] = [
      kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate,
    ]
    guard let key = SecKeyCreateWithData(Data(der) as CFData, attrs as CFDictionary, nil) else {
      throw SSHError.auth("unreadable RSA key")
    }
    var blob = SSHWriter()
    blob.string("ssh-rsa")
    blob.mpint(e)
    blob.mpint(n)
    return PrivateKey(algorithm: "rsa-sha2-512", publicBlob: blob.bytes) { data in
      var error: Unmanaged<CFError>?
      guard
        let s = SecKeyCreateSignature(
          key, .rsaSignatureMessagePKCS1v15SHA512, Data(data) as CFData, &error)
      else {
        throw SSHError.auth("RSA signature failed")
      }
      var sig = SSHWriter()
      sig.string("rsa-sha2-512")
      sig.string([UInt8](s as Data))
      return sig.bytes
    }
  }

  /// The line for authorized_keys: the key type, which for RSA is not the
  /// signature algorithm.
  public var authorizedKey: String {
    var r = SSHReader(publicBlob)
    let type = (try? r.text()) ?? algorithm
    return "\(type) \(Data(publicBlob).base64EncodedString())"
  }

  /// A new key as `ssh-keygen -t` makes it: the private file in OpenSSH's
  /// format (aes256-ctr under bcrypt_pbkdf, 16 rounds, when a passphrase
  /// is given, as ssh-keygen does) and the .pub line. type is "ed25519" or
  /// "ecdsa" with bits 256, 384 or 521.
  public static func generate(type: String, bits: Int = 256, comment: String, passphrase: String)
    throws -> (key: PrivateKey, file: String, pub: String)
  {
    var priv = SSHWriter()
    let key: PrivateKey
    switch (type, bits) {
    case ("ed25519", _):
      let k = Curve25519.Signing.PrivateKey()
      key = ed25519(k)
      priv.string("ssh-ed25519")
      priv.string(Array(k.publicKey.rawRepresentation))
      priv.string(Array(k.rawRepresentation) + Array(k.publicKey.rawRepresentation))
    case ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521):
      let name = "ecdsa-sha2-nistp\(bits)"
      let scalar: [UInt8]
      let point: [UInt8]
      switch bits {
      case 256:
        let k = P256.Signing.PrivateKey()
        scalar = Array(k.rawRepresentation)
        point = Array(k.publicKey.x963Representation)
      case 384:
        let k = P384.Signing.PrivateKey()
        scalar = Array(k.rawRepresentation)
        point = Array(k.publicKey.x963Representation)
      default:
        let k = P521.Signing.PrivateKey()
        scalar = Array(k.rawRepresentation)
        point = Array(k.publicKey.x963Representation)
      }
      key = try ecdsa(name, scalar: scalar)
      priv.string(name)
      priv.string("nistp\(bits)")
      priv.string(point)
      priv.mpint(scalar)
    case ("ecdsa", _):
      throw SSHError.unsupported("ecdsa bits \(bits): 256, 384 or 521")
    default:
      throw SSHError.unsupported("key type \(type): ed25519 or ecdsa")
    }
    let encrypted = !passphrase.isEmpty
    var block = SSHWriter()
    let check = UInt32.random(in: 0...UInt32.max)
    block.u32(check)
    block.u32(check)
    block.bytes += priv.bytes
    block.string(comment)
    let unit = encrypted ? 16 : 8
    var pad: UInt8 = 1
    while block.bytes.count % unit != 0 {
      block.byte(pad)
      pad += 1
    }
    var file = SSHWriter()
    file.bytes += magic
    file.string(encrypted ? "aes256-ctr" : "none")
    file.string(encrypted ? "bcrypt" : "none")
    var opts = SSHWriter()
    var body = block.bytes
    if encrypted {
      let salt = (0..<16).map { _ in UInt8.random(in: .min ... .max) }
      opts.string(salt)
      opts.u32(16)
      let kiv = BcryptPBKDF.derive(
        password: Array(passphrase.utf8), salt: salt, rounds: 16, length: 48)
      // CTR is the same operation both ways: the reader's decrypt encrypts
      body = try aesCTR(body, key: Array(kiv[0..<32]), iv: Array(kiv[32..<48]))
    }
    file.string(opts.bytes)
    file.u32(1)
    file.string(key.publicBlob)
    file.string(body)
    let b64 = Data(file.bytes).base64EncodedString()
    var lines: [String] = []
    var i = b64.startIndex
    while i < b64.endIndex {
      let j = b64.index(i, offsetBy: 70, limitedBy: b64.endIndex) ?? b64.endIndex
      lines.append(String(b64[i..<j]))
      i = j
    }
    let text =
      "-----BEGIN OPENSSH PRIVATE KEY-----\n" + lines.joined(separator: "\n")
      + "\n-----END OPENSSH PRIVATE KEY-----\n"
    return (key, text, "\(key.authorizedKey) \(comment)\n")
  }
}

/// Checks a server's signature over the exchange hash with the host key it
/// sent. Returns the algorithm name on success.
func verifyHostSignature(blob: [UInt8], signature: [UInt8], data: [UInt8]) throws -> String {
  var k = SSHReader(blob)
  let type = try k.text()
  var s = SSHReader(signature)
  let sigType = try s.text()
  let sig = try s.string()
  let ok: Bool
  switch (type, sigType) {
  case ("ssh-ed25519", "ssh-ed25519"):
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: try k.string())
    ok = key.isValidSignature(sig, for: data)
  case ("ecdsa-sha2-nistp256", "ecdsa-sha2-nistp256"):
    _ = try k.string()  // curve name
    let key = try P256.Signing.PublicKey(x963Representation: try k.string())
    var rs = SSHReader(sig)
    let r = try rs.mpint()
    let sv = try rs.mpint()
    guard r.count <= 32, sv.count <= 32 else { throw SSHError.hostKey("bad ECDSA signature") }
    let raw =
      [UInt8](repeating: 0, count: 32 - r.count) + r
      + [UInt8](repeating: 0, count: 32 - sv.count) + sv
    ok = key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: raw), for: data)
  case ("ssh-rsa", "rsa-sha2-256"), ("ssh-rsa", "rsa-sha2-512"):
    let e = try k.mpint()
    let n = try k.mpint()
    ok = try rsaVerify(n: n, e: e, sha512: sigType == "rsa-sha2-512", signature: sig, data: data)
  default:
    throw SSHError.hostKey("unsupported host key \(type)/\(sigType)")
  }
  guard ok else { throw SSHError.hostKey("signature does not verify") }
  return sigType
}

/// Big-endian magnitude minus one; for an odd prime only the low byte moves.
func minusOne(_ a: [UInt8]) -> [UInt8] {
  var r = a
  var i = r.count - 1
  while i >= 0 {
    if r[i] > 0 {
      r[i] -= 1
      break
    }
    r[i] = 0xFF
    i -= 1
  }
  return r
}

/// a mod m for big-endian magnitudes, one bit at a time: runs once per key
/// load, where simple beats fast.
func bigMod(_ a: [UInt8], _ m: [UInt8]) -> [UInt8] {
  let width = m.count + 1
  let mm = [UInt8](repeating: 0, count: width - m.count) + m
  var r = [UInt8](repeating: 0, count: width)
  for byte in a {
    for bit in stride(from: 7, through: 0, by: -1) {
      var carry = (byte >> UInt8(bit)) & 1
      for i in stride(from: width - 1, through: 0, by: -1) {
        let next = r[i] >> 7
        r[i] = r[i] << 1 | carry
        carry = next
      }
      if !r.lexicographicallyPrecedes(mm) {
        var borrow = 0
        for i in stride(from: width - 1, through: 0, by: -1) {
          let v = Int(r[i]) - Int(mm[i]) - borrow
          borrow = v < 0 ? 1 : 0
          r[i] = UInt8((v + 256) & 0xFF)
        }
      }
    }
  }
  return Array(r.drop { $0 == 0 })
}

private func derLength(_ n: Int) -> [UInt8] {
  if n < 0x80 {
    return [UInt8(n)]
  }
  var bytes: [UInt8] = []
  var v = n
  while v > 0 {
    bytes.insert(UInt8(v & 0xFF), at: 0)
    v >>= 8
  }
  return [0x80 | UInt8(bytes.count)] + bytes
}

private func derInteger(_ magnitude: [UInt8]) -> [UInt8] {
  var m = magnitude
  if m.first.map({ $0 & 0x80 != 0 }) ?? true {
    m.insert(0, at: 0)
  }
  return [0x02] + derLength(m.count) + m
}

/// PKCS#1 RSAPublicKey DER for Security.framework, which takes no raw n/e.
private func rsaVerify(n: [UInt8], e: [UInt8], sha512: Bool, signature: [UInt8], data: [UInt8])
  throws -> Bool
{
  guard n.count >= 256 else { throw SSHError.hostKey("RSA host key under 2048 bits") }
  let body = derInteger(n) + derInteger(e)
  let der = [0x30] + derLength(body.count) + body
  let attrs: [CFString: Any] = [
    kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic,
  ]
  guard let key = SecKeyCreateWithData(Data(der) as CFData, attrs as CFDictionary, nil) else {
    throw SSHError.hostKey("unreadable RSA host key")
  }
  let alg: SecKeyAlgorithm =
    sha512 ? .rsaSignatureMessagePKCS1v15SHA512 : .rsaSignatureMessagePKCS1v15SHA256
  return SecKeyVerifySignature(key, alg, Data(data) as CFData, Data(signature) as CFData, nil)
}

/// Host keys seen before, in OpenSSH's known_hosts format ("[host]:port
/// type base64" for non-22 ports). Hashed lines are skipped, not matched:
/// this file is fosforo's own.
public struct KnownHosts: Sendable {
  public let path: String

  public init(path: String) {
    self.path = path
  }

  public enum Verdict: Equatable, Sendable {
    case known
    case unknown
    case changed(file: String, line: Int)  // a different key under this name: refuse
  }

  /// How the file names a host: "[host]:port" off port 22.
  public static func name(host: String, port: Int) -> String {
    port == 22 ? host : "[\(host)]:\(port)"
  }

  public func check(host: String, port: Int, blob: [UInt8]) -> Verdict {
    KnownHosts.check(path, host: host, port: port, blob: blob)
  }

  private static func check(_ path: String, host: String, port: Int, blob: [UInt8]) -> Verdict {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return .unknown }
    let name = KnownHosts.name(host: host, port: port)
    var r = SSHReader(blob)
    let type = (try? r.text()) ?? ""
    var verdict = Verdict.unknown
    for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
      let f = line.split(separator: " ", omittingEmptySubsequences: true)
      guard f.count >= 3, f[0].split(separator: ",").contains(where: { names(name, $0) }),
        f[1] == type
      else {
        continue
      }
      if Data(base64Encoded: String(f[2])) == Data(blob) {
        return .known
      }
      if verdict == .unknown {
        verdict = .changed(file: path, line: i + 1)
      }
    }
    return verdict
  }

  /// Whether a known_hosts host field names `name`: as written, or hashed
  /// (`|1|salt|HMAC-SHA1(salt, name)`, what HashKnownHosts writes and many
  /// servers' files carry); a hashed line that never matched would let a
  /// changed key pass as unknown.
  private static func names(_ name: String, _ field: Substring) -> Bool {
    guard field.hasPrefix("|1|") else { return field == Substring(name) }
    let parts = field.split(separator: "|", omittingEmptySubsequences: true)
    guard parts.count == 3, let salt = Data(base64Encoded: String(parts[1])),
      let hash = Data(base64Encoded: String(parts[2]))
    else {
      return false
    }
    let mac = HMAC<Insecure.SHA1>.authenticationCode(
      for: Data(name.utf8), using: SymmetricKey(data: salt))
    return Data(mac) == hash
  }

  public func add(host: String, port: Int, blob: [UInt8]) throws {
    var r = SSHReader(blob)
    let line =
      "\(KnownHosts.name(host: host, port: port)) \(try r.text()) \(Data(blob).base64EncodedString())\n"
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let h = FileHandle(forWritingAtPath: path) {
      defer { try? h.close() }
      try h.seekToEnd()
      try h.write(contentsOf: Data(line.utf8))
      return
    }
    try line.write(to: url, atomically: true, encoding: .utf8)
  }

  /// ssh-keygen -R: every line of the writable file that names the host
  /// goes, the file as it was kept in known_hosts.old. How many went.
  public func remove(host: String, port: Int) throws -> Int {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return 0 }
    let name = Substring(KnownHosts.name(host: host, port: port))
    var kept: [Substring] = []
    var gone = 0
    for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
      let first = line.split(separator: " ", maxSplits: 1).first ?? ""
      if first.split(separator: ",").contains(name) {
        gone += 1
      } else {
        kept.append(line)
      }
    }
    if gone > 0 {
      try text.write(toFile: path + ".old", atomically: true, encoding: .utf8)
      try kept.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
    return gone
  }

  /// SHA256 fingerprint as ssh-keygen -l prints it.
  public static func fingerprint(_ blob: [UInt8]) -> String {
    let b64 = Data(SHA256.hash(data: blob)).base64EncodedString()
    return "SHA256:" + b64.trimmingCharacters(in: CharacterSet(charactersIn: "="))
  }
}

/// Just enough DER for PKCS#1: definite lengths, SEQUENCE and INTEGER.
struct DERReader {
  let bytes: [UInt8]
  var pos = 0

  init(_ bytes: [UInt8]) { self.bytes = bytes }

  private mutating func element(_ tag: UInt8) throws -> [UInt8] {
    guard pos + 2 <= bytes.count, bytes[pos] == tag else { throw SSHError.auth("corrupt DER") }
    var len = Int(bytes[pos + 1])
    pos += 2
    if len & 0x80 != 0 {
      let n = len & 0x7F
      guard n >= 1, n <= 4, pos + n <= bytes.count else { throw SSHError.auth("corrupt DER") }
      len = bytes[pos..<(pos + n)].reduce(0) { $0 << 8 | Int($1) }
      pos += n
    }
    guard len <= bytes.count - pos else { throw SSHError.auth("corrupt DER") }
    defer { pos += len }
    return Array(bytes[pos..<(pos + len)])
  }

  mutating func sequence() throws -> [UInt8] { try element(0x30) }

  /// The magnitude, leading zero bytes dropped (all positive here).
  mutating func integer() throws -> [UInt8] { Array(try element(0x02).drop { $0 == 0 }) }
}
