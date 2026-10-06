import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Key files kept encrypted on disk by a key that lives in this device's
/// Secure Enclave: a copy of the file is useless anywhere else, and opening
/// it asks for the owner (Face ID, Touch ID or the passcode) once per
/// session, as banking apps do. Encrypting needs only the public half, so
/// it never asks. ECIES: an ephemeral P-256 agreement with the vault key,
/// HKDF-SHA256, AES-GCM.
public final class Vault: @unchecked Sendable {
  public static let header = "-----BEGIN FOSFORO PROTECTED KEY-----"
  static let footer = "-----END FOSFORO PROTECTED KEY-----"
  static let info = Array("fosforo vault v1".utf8)

  private let lock = NSLock()
  private let file: URL  // the vault key: an opaque Secure Enclave blob, or a software key in tests
  private let secureEnclave: Bool
  private var context = LAContext()
  /// Set when the device has no passcode: the key is then made without the
  /// presence check (still bound to this device), and this says so.
  public private(set) var withoutPresence = false

  /// secureEnclave false: a software key in the file, for tests on a Mac.
  public init(file: URL, secureEnclave: Bool = true) {
    self.file = file
    self.secureEnclave = secureEnclave
    withoutPresence = FileManager.default.fileExists(atPath: file.path + ".no-presence")
    context.localizedReason = "open your protected SSH keys"
  }

  /// Back to asking: the app calls this after a while in the background.
  public func relock() {
    lock.lock()
    context.invalidate()
    context = LAContext()
    context.localizedReason = "open your protected SSH keys"
    lock.unlock()
  }

  // MARK: - the vault key

  private func publicKey() throws -> P256.KeyAgreement.PublicKey {
    if secureEnclave {
      return try enclaveKey(create: true).publicKey
    }
    return try softwareKey().publicKey
  }

  private func softwareKey() throws -> P256.KeyAgreement.PrivateKey {
    if let raw = try? Data(contentsOf: file) {
      return try P256.KeyAgreement.PrivateKey(rawRepresentation: raw)
    }
    let key = P256.KeyAgreement.PrivateKey()
    try save(key.rawRepresentation)
    return key
  }

  private func enclaveKey(create: Bool) throws -> SecureEnclave.P256.KeyAgreement.PrivateKey {
    lock.lock()
    let ctx = context
    lock.unlock()
    if let blob = try? Data(contentsOf: file) {
      return try SecureEnclave.P256.KeyAgreement.PrivateKey(
        dataRepresentation: blob, authenticationContext: ctx)
    }
    guard create else {
      throw SSHError.auth("this device has no vault key: nothing was protected here")
    }
    guard SecureEnclave.isAvailable else { throw SSHError.unsupported("no Secure Enclave") }
    var made: SecureEnclave.P256.KeyAgreement.PrivateKey
    if let ac = Vault.access([.privateKeyUsage, .userPresence]),
      let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
    {
      made = key
    } else {
      // no passcode on the device: presence cannot be asked, the binding stays
      guard let ac = Vault.access([.privateKeyUsage]) else {
        throw SSHError.unsupported("Secure Enclave access control")
      }
      made = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac)
      withoutPresence = true
    }
    try save(made.dataRepresentation)
    if withoutPresence {
      // remembered, so it is said again after a relaunch
      try Data().write(to: URL(fileURLWithPath: file.path + ".no-presence"))
    }
    return made
  }

  private static func access(_ flags: SecAccessControlCreateFlags) -> SecAccessControl? {
    SecAccessControlCreateWithFlags(
      nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, nil)
  }

  private func save(_ data: Data) throws {
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    #if os(iOS)
      try data.write(to: file, options: [.atomic, .completeFileProtection])
    #else
      try data.write(to: file, options: [.atomic])
    #endif
  }

  // MARK: - sealing

  private static func symmetric(_ shared: SharedSecret, _ eph: [UInt8], _ vault: [UInt8])
    -> SymmetricKey
  {
    shared.hkdfDerivedSymmetricKey(
      using: SHA256.self, salt: info, sharedInfo: eph + vault, outputByteCount: 32)
  }

  /// The protected file for a key file: a header a person can read, the
  /// public key so a server can be asked about it without opening it, and
  /// the sealed original.
  public func protect(_ original: String, publicKey: String, note: String) throws -> String {
    let vault = try self.publicKey()
    let eph = P256.KeyAgreement.PrivateKey()
    let shared = try eph.sharedSecretFromKeyAgreement(with: vault)
    let e = Array(eph.publicKey.x963Representation)
    let key = Vault.symmetric(shared, e, Array(vault.x963Representation))
    guard let sealed = try AES.GCM.seal(Data(original.utf8), using: key).combined else {
      throw SSHError.io("vault: seal")
    }
    let body = Data([1] + e + [UInt8](sealed)).base64EncodedString(
      options: [.lineLength64Characters, .endLineWithLineFeed])
    return """
      \(Vault.header)
      Comment: \(note)
      Public: \(publicKey)

      \(body)
      \(Vault.footer)

      """
  }

  /// The original key file. On the first use of a session this asks for
  /// the owner.
  public func open(_ text: String) throws -> String {
    guard let b = text.range(of: Vault.header), let f = text.range(of: Vault.footer) else {
      throw SSHError.auth("not a protected key")
    }
    let body = text[b.upperBound..<f.lowerBound].split(separator: "\n").filter {
      !$0.contains(":")
    }.joined()
    guard let data = Data(base64Encoded: body), data.count > 66, data.first == 1 else {
      throw SSHError.auth("corrupt protected key")
    }
    let bytes = [UInt8](data)
    let e = Array(bytes[1..<66])
    let sealed = Data(bytes[66...])
    let ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: e)
    let shared: SharedSecret
    let vault: [UInt8]
    if secureEnclave {
      let k = try enclaveKey(create: false)
      do {
        shared = try k.sharedSecretFromKeyAgreement(with: ephemeral)
      } catch {
        throw SSHError.auth("the owner did not confirm: key not opened")
      }
      vault = Array(k.publicKey.x963Representation)
    } else {
      let k = try softwareKey()
      shared = try k.sharedSecretFromKeyAgreement(with: ephemeral)
      vault = Array(k.publicKey.x963Representation)
    }
    do {
      let plain = try AES.GCM.open(
        AES.GCM.SealedBox(combined: sealed), using: Vault.symmetric(shared, e, vault))
      return String(decoding: plain, as: UTF8.self)
    } catch {
      throw SSHError.auth("this key was protected on another device (or by another install)")
    }
  }

  public static func isProtected(_ text: String) -> Bool { text.contains(header) }

  /// The "Public:" line of a protected file, as in a .pub.
  public static func publicLine(_ text: String) -> String? {
    text.split(separator: "\n").first { $0.hasPrefix("Public: ") }.map {
      String($0.dropFirst("Public: ".count))
    }
  }
}
