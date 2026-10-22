import CryptoKit
import Foundation
import LocalAuthentication
import Security
import Testing

@testable import FosforoSSH

// MARK: - RSA host keys

private func rsaKey(bits: Int) throws -> SecKey {
  let attrs: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: bits]
  var error: Unmanaged<CFError>?
  guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
    throw error!.takeRetainedValue()
  }
  return key
}

/// The ssh-rsa blob of a key, from its PKCS#1 RSAPublicKey.
private func rsaBlob(_ key: SecKey) throws -> [UInt8] {
  let der = [UInt8](SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(key)!, nil)! as Data)
  var outer = DERReader(der)
  var seq = DERReader(try outer.sequence())
  let n = try seq.integer()
  let e = try seq.integer()
  var w = SSHWriter()
  w.string("ssh-rsa")
  w.mpint(e)
  w.mpint(n)
  return w.bytes
}

private func rsaSign(_ key: SecKey, _ alg: String, _ data: [UInt8]) -> [UInt8] {
  let a: SecKeyAlgorithm =
    alg == "rsa-sha2-512" ? .rsaSignatureMessagePKCS1v15SHA512 : .rsaSignatureMessagePKCS1v15SHA256
  return [UInt8](SecKeyCreateSignature(key, a, Data(data) as CFData, nil)! as Data)
}

private func signature(_ alg: String, _ sig: [UInt8]) -> [UInt8] {
  var w = SSHWriter()
  w.string(alg)
  w.string(sig)
  return w.bytes
}

@Test(arguments: ["rsa-sha2-256", "rsa-sha2-512"])
func rsaHostSignaturesVerifyAndAFlippedBitDoesNot(alg: String) throws {
  let key = try rsaKey(bits: 2048)
  let blob = try rsaBlob(key)
  let data = Array("exchange hash".utf8)
  let sig = rsaSign(key, alg, data)
  #expect(try verifyHostSignature(blob: blob, signature: signature(alg, sig), data: data) == alg)
  var bad = sig
  bad[bad.count / 2] ^= 0x01
  let refused = SSHError.hostKey("signature does not verify")
  #expect(throws: refused) {
    try verifyHostSignature(blob: blob, signature: signature(alg, bad), data: data)
  }
  #expect(throws: refused) {
    try verifyHostSignature(blob: blob, signature: signature(alg, sig), data: data + [0])
  }
  let other = alg == "rsa-sha2-256" ? "rsa-sha2-512" : "rsa-sha2-256"
  #expect(throws: refused) {
    try verifyHostSignature(blob: blob, signature: signature(other, sig), data: data)
  }
}

@Test func weakOrSHA1RSAHostKeysAreRefused() throws {
  let small = try rsaKey(bits: 1024)
  let data = Array("h".utf8)
  #expect(throws: SSHError.hostKey("RSA host key under 2048 bits")) {
    try verifyHostSignature(
      blob: try rsaBlob(small),
      signature: signature("rsa-sha2-512", rsaSign(small, "rsa-sha2-512", data)),
      data: data)
  }
  let key = try rsaKey(bits: 2048)
  #expect(throws: SSHError.hostKey("unsupported host key ssh-rsa/ssh-rsa")) {
    try verifyHostSignature(
      blob: try rsaBlob(key), signature: signature("ssh-rsa", rsaSign(key, "rsa-sha2-256", data)),
      data: data)
  }
}

/// ed25519 and ECDSA host signatures: the right one passes, a flipped bit
/// fails, an ECDSA r wider than the curve is refused before CryptoKit.
@Test func ellipticHostSignaturesVerifyAndAFlippedBitDoesNot() throws {
  let data = Array("exchange hash".utf8)
  for key in [PrivateKey.ed25519(.init()), PrivateKey.p256(.init())] {
    let sig = try key.sign(data)
    #expect(
      try verifyHostSignature(blob: key.publicBlob, signature: sig, data: data) == key.algorithm)
    var bad = sig
    bad[bad.count - 3] ^= 0x01
    #expect(throws: SSHError.hostKey("signature does not verify")) {
      try verifyHostSignature(blob: key.publicBlob, signature: bad, data: data)
    }
  }
  let p = PrivateKey.p256(.init())
  var rs = SSHWriter()
  rs.mpint([0x01] + [UInt8](repeating: 0x22, count: 32))  // 33 bytes
  rs.mpint([0x01])
  #expect(throws: SSHError.hostKey("bad ECDSA signature")) {
    try verifyHostSignature(
      blob: p.publicBlob, signature: signature("ecdsa-sha2-nistp256", rs.bytes), data: data)
  }
}

/// A server with only an RSA host key on offer, under each SHA-2 signature
/// name: the client checks the exchange signature and records ssh-rsa.
@Test(arguments: ["rsa-sha2-256", "rsa-sha2-512"])
func rsaHostKeyServerIsTrusted(alg: String) throws {
  let keys = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: keys) }
  let rsa = keys.appendingPathComponent("rsa_host").path
  try Server.run("/usr/bin/ssh-keygen", ["-q", "-t", "rsa", "-b", "2048", "-N", "", "-f", rsa])
  let server = try Server(extra: "HostKey \(rsa)\nHostKeyAlgorithms \(alg)")
  let client = SSHClient(config: try server.config(command: "echo rsa-host-ok"))
  let out = Collector()
  out.attach(client)
  try client.connect()
  client.start()
  #expect(out.wait())
  #expect(out.text.contains("rsa-host-ok"))
  let known = try String(contentsOfFile: server.knownHosts.path, encoding: .utf8)
  let pub = try String(contentsOfFile: rsa + ".pub", encoding: .utf8).split(separator: " ")
  #expect(known.hasPrefix("[127.0.0.1]:\(server.port) ssh-rsa \(pub[1])"))
}

// MARK: - encrypted key files

private func tempDir() throws -> URL {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  return dir
}

private func keygen(_ dir: URL, _ name: String, _ args: [String]) throws -> (String, String) {
  let path = dir.appendingPathComponent(name).path
  try Server.run("/usr/bin/ssh-keygen", ["-q", "-f", path] + args)
  return (
    try String(contentsOfFile: path, encoding: .utf8),
    try String(contentsOfFile: path + ".pub", encoding: .utf8)
  )
}

/// The container of an OpenSSH key file, changed by `edit` and written back.
private func rewrite(_ text: String, _ edit: (inout [UInt8]) throws -> Void) rethrows -> String {
  let begin = "-----BEGIN OPENSSH PRIVATE KEY-----"
  let end = "-----END OPENSSH PRIVATE KEY-----"
  let b64 = text.replacingOccurrences(of: begin, with: "").replacingOccurrences(of: end, with: "")
    .filter { !$0.isWhitespace }
  var bytes = [UInt8](Data(base64Encoded: b64)!)
  try edit(&bytes)
  return begin + "\n" + Data(bytes).base64EncodedString() + "\n" + end + "\n"
}

/// The same container with another kdf name and rounds.
private func withKDF(_ text: String, kdf: String, rounds: UInt32) throws -> String {
  try rewrite(text) { bytes in
    let magic = Array("openssh-key-v1\0".utf8)
    var r = SSHReader(Array(bytes[magic.count...]))
    let cipher = try r.string()
    _ = try r.string()
    var opts = SSHReader(try r.string())
    let salt = try opts.string()
    var w = SSHWriter()
    w.bytes = magic
    w.string(cipher)
    w.string(kdf)
    var o = SSHWriter()
    o.string(salt)
    o.u32(rounds)
    w.string(o.bytes)
    w.bytes += r.bytes[r.pos...]
    bytes = w.bytes
  }
}

/// aes256-gcm@openssh.com (ssh-keygen -Z), the cipher besides the default
/// aes256-ctr: the right passphrase opens it, a wrong one or a tag cut off
/// says so; ciphers, kdfs and round counts we do not take are refused.
@Test func encryptedOpenSSHKeysOpenWithTheirPassphraseOnly() throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let (gcm, gcmPub) = try keygen(
    dir, "gcm", ["-t", "ed25519", "-N", "abc", "-Z", "aes256-gcm@openssh.com"])
  #expect(gcmPub.hasPrefix(try PrivateKey.load(gcm, passphrase: "abc").authorizedKey))
  #expect(throws: SSHError.auth("wrong passphrase")) { try PrivateKey.load(gcm, passphrase: "abd") }
  #expect(throws: SSHError.auth("passphrase needed")) { try PrivateKey.load(gcm) }
  let cut = rewrite(gcm) { $0.removeLast(16) }
  #expect(throws: SSHError.auth("truncated key")) { try PrivateKey.load(cut, passphrase: "abc") }

  let (ctr, _) = try keygen(dir, "ctr", ["-t", "ecdsa", "-N", "abc"])
  #expect(throws: SSHError.auth("implausible kdf rounds 5000")) {
    try PrivateKey.load(try withKDF(ctr, kdf: "bcrypt", rounds: 5000), passphrase: "abc")
  }
  #expect(throws: SSHError.unsupported("key derivation scrypt")) {
    try PrivateKey.load(try withKDF(ctr, kdf: "scrypt", rounds: 16), passphrase: "abc")
  }
  let (aes128, _) = try keygen(dir, "aes128", ["-t", "ed25519", "-N", "abc", "-Z", "aes128-ctr"])
  #expect(throws: SSHError.unsupported("key cipher aes128-ctr")) {
    try PrivateKey.load(aes128, passphrase: "abc")
  }
}

/// PEM keys under OpenSSL's traditional encryption: AES-256 opens with its
/// passphrase; single DES, which we do not take, is refused by name.
@Test func pemEncryptionByCipher() throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  for (flag, header, opens) in [("-aes256", "AES-256-CBC", true), ("-des", "DES-CBC", false)] {
    let path = dir.appendingPathComponent("k\(flag)").path
    try Server.run(
      "/usr/bin/openssl", ["genrsa", flag, "-passout", "pass:abc", "-out", path, "2048"])
    let text = try String(contentsOfFile: path, encoding: .utf8)
    #expect(text.contains("DEK-Info: \(header),"))
    if opens {
      let key = try PrivateKey.load(text, passphrase: "abc")
      #expect(throws: SSHError.self) { try PrivateKey.load(text, passphrase: "abd") }
      // locked, offered by its .pub as ssh-keygen -y writes it: no comment
      let pub = key.authorizedKey + "\n"
      let commented = try PrivateKey.deferred(
        text, pub: key.authorizedKey + " k@test\n", name: "k", passphrase: nil)
      #expect(commented.authorizedKey == key.authorizedKey)
      #expect(throws: SSHError.locked("k")) { try commented.sign([]) }
      let offered = try PrivateKey.deferred(text, pub: pub, name: "k", passphrase: nil)
      #expect(offered.authorizedKey == key.authorizedKey)
      continue
    }
    do {
      _ = try PrivateKey.load(text, passphrase: "abc")
      Issue.record("\(header) opened")
    } catch SSHError.unsupported(let what) {
      #expect(what.hasPrefix("PEM encryption \(header),"))
    }
  }
}

// MARK: - authentication fallbacks

/// A key the server takes as only the first of two steps (partial
/// success): the password and keyboard-interactive are tried in turn, and
/// the refusal names what the server still wants. No password is checked
/// for real: the server takes neither here.
@Test func partialSuccessTriesTheRestThenSaysWhatIsLeft() throws {
  let server = try Server(
    extra: "KbdInteractiveAuthentication yes\nAuthenticationMethods publickey,keyboard-interactive")
  var cfg = try server.config(command: "true")
  cfg.password = "not-a-password"
  let steps = Lines()
  cfg.trace = { steps.add($0) }
  #expect(
    throws: SSHError.auth(
      "permission denied for \(NSUserName()) (server accepts: keyboard-interactive)")
  ) { try SSHClient(config: cfg).connect() }
  #expect(steps.all.contains { $0.contains("accepted: signing") })
}

/// No key the server takes and a password it does not accept either: the
/// password is offered, then the error lists the server's methods.
@Test func aPasswordTheServerDoesNotTakeEndsInTheMethodsLeft() throws {
  let banner = try tempDir()
  defer { try? FileManager.default.removeItem(at: banner) }
  let bannerFile = banner.appendingPathComponent("banner")
  try "fosforo test banner\n".write(to: bannerFile, atomically: true, encoding: .utf8)
  let server = try Server(extra: "Banner \(bannerFile.path)")
  var cfg = try server.config(command: "true")
  cfg.keys = []
  cfg.password = "not-a-password"
  let client = SSHClient(config: cfg)
  let banners = Lines()
  client.onBanner = { banners.add($0) }
  #expect(
    throws: SSHError.auth("permission denied for \(NSUserName()) (server accepts: publickey)")
  ) {
    try client.connect()
  }
  #expect(banners.all == ["fosforo test banner\n"])
}

final class Lines: @unchecked Sendable {
  private let lock = NSLock()
  private var lines: [String] = []
  func add(_ s: String) {
    lock.lock()
    lines.append(s)
    lock.unlock()
  }
  var all: [String] {
    lock.lock()
    defer { lock.unlock() }
    return lines
  }
}

// MARK: - packets the server sends now and then

/// sshd with ClientAliveInterval asks keepalive@openssh.com every second
/// and hangs up after two unanswered; it also sends hostkeys-00 after
/// login, wanting no reply. A command that outlasts both still ends well.
@Test func serverKeepalivesAreAnswered() throws {
  let server = try Server(extra: "ClientAliveInterval 1\nClientAliveCountMax 2")
  let client = SSHClient(config: try server.config(command: "sleep 4; echo still-here"))
  let out = Collector()
  out.attach(client)
  try client.connect()
  client.start()
  #expect(out.wait(seconds: 30))
  #expect(out.error == nil)
  #expect(out.text.contains("still-here"))
  #expect(out.status == 0)
}

/// A client whose packets go in the clear to a socketpair; the other end,
/// non-blocking, is returned to read them.
private func wired(_ config: SSHConfig? = nil) -> (SSHClient, Int32) {
  var pair: [Int32] = [0, 0]
  _ = socketpair(AF_UNIX, SOCK_STREAM, 0, &pair)
  var one: Int32 = 1
  setsockopt(pair[0], SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
  _ = fcntl(pair[1], F_SETFL, O_NONBLOCK)
  let client = SSHClient(
    config: config
      ?? SSHConfig(host: "x", user: "u", knownHosts: KnownHosts(path: "/nonexistent")))
  client.io = PacketIO(fd: pair[0])
  return (client, pair[1])
}

/// The payloads of the packets waiting on fd.
private func sent(_ fd: Int32) -> [[UInt8]] {
  var raw: [UInt8] = []
  var buf = [UInt8](repeating: 0, count: 65536)
  while true {
    let n = read(fd, &buf, buf.count)
    guard n > 0 else { break }
    raw += buf[0..<n]
  }
  var out: [[UInt8]] = []
  var at = 0
  while at + 5 <= raw.count {
    var head = SSHReader(Array(raw[at..<at + 5]))
    let len = Int((try? head.u32()) ?? 0)
    let pad = Int((try? head.byte()) ?? 0)
    out.append(Array(raw[at + 5..<at + 4 + len - pad]))
    at += 4 + len
  }
  return out
}

private func channelOpen(_ type: String, sender: UInt32, max: UInt32 = 32768, extra: [UInt8] = [])
  -> [UInt8]
{
  var w = SSHWriter(message: Msg.channelOpen)
  w.string(type)
  w.u32(sender)
  w.u32(65536)
  w.u32(max)
  return w.bytes + extra
}

private func openFailure(_ p: [UInt8]) throws -> (sender: UInt32, code: UInt32, why: String) {
  var r = SSHReader(p)
  #expect(try r.byte() == Msg.channelOpenFailure)
  return (try r.u32(), try r.u32(), try r.text())
}

/// Channels the server opens that nobody asked for are refused, each with
/// its reason; a -R port whose local end does not answer is "connect
/// failed" (code 2), with a warning.
@Test func unwantedChannelsAreRefused() throws {
  let (client, fd) = wired()
  defer { close(fd) }
  try client.handle(channelOpen("x11", sender: 5))
  try client.handle(channelOpen("session", sender: 6, max: 0))
  var port = SSHWriter()
  port.string("127.0.0.1")
  port.u32(9)
  try client.handle(channelOpen("forwarded-tcpip", sender: 7, extra: port.bytes))
  try client.handle(channelOpen("auth-agent@openssh.com", sender: 8))
  let got = try sent(fd).map(openFailure)
  #expect(got.map(\.sender) == [5, 6, 7, 8])
  #expect(got.allSatisfy { $0.code == 1 })
  #expect(
    got.map(\.why) == [
      "no x11 here", "maximum packet size 0", "no forward for port 9",
      "no auth-agent@openssh.com here",
    ])

  let listener = try listenTCP(host: "127.0.0.1", port: 0)
  var addr = sockaddr_in()
  var len = socklen_t(MemoryLayout<sockaddr_in>.size)
  _ = withUnsafeMutablePointer(to: &addr) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) }
  }
  let dead = Int(UInt16(bigEndian: addr.sin_port))
  close(listener)  // nothing listens there now
  var cfg = SSHConfig(host: "x", user: "u", knownHosts: KnownHosts(path: "/nonexistent"))
  cfg.timeout = 2
  cfg.remoteForwards = [SSHConfig.Forward(bindPort: 8022, host: "127.0.0.1", port: dead)]
  let warnings = Lines()
  cfg.warn = { warnings.add($0) }
  let (forwarding, fd2) = wired(cfg)
  defer { close(fd2) }
  var to = SSHWriter()
  to.string("127.0.0.1")
  to.u32(8022)
  try forwarding.handle(channelOpen("forwarded-tcpip", sender: 9, extra: to.bytes))
  var answer: [[UInt8]] = []
  let deadline = Date().addingTimeInterval(5)
  while answer.isEmpty && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.02)
    answer = sent(fd2)
  }
  let refused = try answer.map(openFailure)
  #expect(refused.count == 1 && refused.first?.sender == 9 && refused.first?.code == 2)
  #expect(refused.first?.why == "connect failed")
  #expect(warnings.all.first?.hasPrefix("port 8022 on the server: 127.0.0.1:\(dead)") == true)
}

/// Global requests wanting a reply get REQUEST_FAILURE, the rest none; a
/// channel request wanting one gets CHANNEL_FAILURE on the peer's number;
/// exit-signal is status 255; a message we do not know is answered
/// UNIMPLEMENTED; EXT_INFO and an unasked REQUEST_SUCCESS are dropped.
@Test func rarePacketsGetTheirAnswers() throws {
  let (client, fd) = wired()
  defer { close(fd) }
  let ch = SSHChannel(client: client, id: 0)
  ch.remote = 42
  client.channels[0] = ch
  for want in [true, false] {
    var g = SSHWriter(message: Msg.globalRequest)
    g.string(want ? "keepalive@openssh.com" : "hostkeys-00@openssh.com")
    g.bool(want)
    try client.handle(g.bytes)
  }
  var req = SSHWriter(message: Msg.channelRequest)
  req.u32(0)
  req.string("exit-signal")
  req.bool(true)
  req.string("TERM")
  try client.handle(req.bytes)
  try client.handle([Msg.extInfo, 0, 0, 0, 0])
  try client.handle([Msg.requestSuccess])
  try client.handle([200])
  let got = sent(fd)
  #expect(got.count == 3)
  #expect(got.first == [Msg.requestFailure])
  #expect(got.dropFirst().first == [Msg.channelFailure, 0, 0, 0, 42])
  #expect(got.last?.first == Msg.unimplemented && got.last?.count == 5)
  #expect(ch.exitStatus == 255)
}

// MARK: - the vault in the Secure Enclave

private func enclaveKey() -> SecureEnclave.P256.KeyAgreement.PrivateKey? {
  // no presence check: opening asks nobody, so the test shows nothing
  guard
    let ac = SecAccessControlCreateWithFlags(
      nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage], nil)
  else {
    return nil
  }
  return try? SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
}

/// With a Secure Enclave vault key (none is kept in the keychain: the file
/// holds the enclave's wrapped blob), a key sealed here opens here and not
/// under another enclave key; relock drops the context that was unlocked
/// for a fresh one; a vault with no key file opens nothing. Skipped where
/// the hardware or the test process cannot make enclave keys.
@Test(.enabled(if: SecureEnclave.isAvailable))
func vaultInTheSecureEnclave() throws {
  guard let mine = enclaveKey(), let theirs = enclaveKey() else { return }
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  try mine.dataRepresentation.write(to: dir.appendingPathComponent("mine"))
  try theirs.dataRepresentation.write(to: dir.appendingPathComponent("theirs"))
  let vault = Vault(file: dir.appendingPathComponent("mine"))
  let original = "-----BEGIN OPENSSH PRIVATE KEY-----\nAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
  let sealed = try vault.protect(original, publicKey: "ssh-ed25519 AAAA x", note: "test")
  #expect(try vault.open(sealed) == original)

  let unlocked = vault.context
  vault.relock()
  var error: NSError?
  #expect(!unlocked.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error))
  #expect(error?.code == LAError.invalidContext.rawValue)
  #expect(vault.context !== unlocked)
  #expect(try vault.open(sealed) == original)

  #expect(
    throws: SSHError.auth("this key was protected on another device (or by another install)")
  ) { try Vault(file: dir.appendingPathComponent("theirs")).open(sealed) }
  #expect(throws: SSHError.auth("this device has no vault key: nothing was protected here")) {
    try Vault(file: dir.appendingPathComponent("none")).open(sealed)
  }
  // the first protect makes the vault key; not opened here, as that would
  // ask for the owner when the Mac has a password
  let fresh = Vault(file: dir.appendingPathComponent("fresh"))
  #expect(Vault.isProtected(try fresh.protect(original, publicKey: "ssh-ed25519 AAAA x", note: "")))
  #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("fresh").path))
  #expect(
    fresh.withoutPresence
      == FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("fresh.no-presence").path))
}

/// relock on a software vault (the tests' kind) keeps it working.
@Test func softwareVaultSurvivesRelock() throws {
  let dir = try tempDir()
  defer { try? FileManager.default.removeItem(at: dir) }
  let vault = Vault(file: dir.appendingPathComponent("v"), secureEnclave: false)
  let sealed = try vault.protect("k", publicKey: "ssh-ed25519 AAAA x", note: "")
  let before = vault.context
  vault.relock()
  #expect(vault.context !== before)
  #expect(try vault.open(sealed) == "k")
}
