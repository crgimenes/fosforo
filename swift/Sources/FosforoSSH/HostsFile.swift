import Foundation

/// ~/.ssh/config as the config screen edits it: one host a block (`Host
/// alias`), the keys it knows set, removed or added inside that block, and
/// every other line (comments, other keys, `Host *`, Match) left as it is.
public struct SSHHostsFile: Equatable, Sendable {
  public struct Host: Equatable, Sendable {
    public var alias: String
    public var hostName = ""
    public var user = ""
    public var port: Int?
    public var identityFile = ""
    public var mosh = false
    public var moshServer = ""

    public init(alias: String) { self.alias = alias }
  }

  public private(set) var lines: [String]

  /// The keys of this screen, as written in the file.
  static let managed = ["HostName", "User", "Port", "IdentityFile", "Mosh", "MoshServer"]
  static let ignore = "IgnoreUnknown Mosh,MoshServer"

  public init(_ text: String) {
    lines = text.isEmpty ? [] : text.components(separatedBy: "\n")
    while lines.last == "" {
      lines.removeLast()
    }
  }

  public init(contentsOf url: URL) {
    self.init((try? String(contentsOf: url, encoding: .utf8)) ?? "")
  }

  public var text: String { lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n" }

  public func write(to url: URL) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// The hosts a block names alone and plainly (no pattern, no negation).
  public var hosts: [Host] {
    blocks().compactMap { b in
      guard let alias = b.alias else { return nil }
      var h = Host(alias: alias)
      for i in (b.start + 1)..<b.end {
        guard let (key, value) = SSHHostsFile.keyValue(lines[i]) else { continue }
        switch key.lowercased() {
        case "hostname" where h.hostName.isEmpty: h.hostName = value
        case "user" where h.user.isEmpty: h.user = value
        case "port" where h.port == nil: h.port = Int(value)
        case "identityfile" where h.identityFile.isEmpty: h.identityFile = value
        case "mosh": h.mosh = value.lowercased() == "yes"
        case "moshserver" where h.moshServer.isEmpty: h.moshServer = value
        default: break
        }
      }
      return h
    }
  }

  /// Writes h's block: in place when its alias has one (old: the alias it
  /// had, when renamed), before the first block with a pattern otherwise,
  /// since the first value found wins and `Host *` is meant to be last.
  public mutating func save(_ h: Host, replacing old: String? = nil) {
    let wanted: [(String, String)] = [
      ("HostName", h.hostName), ("User", h.user), ("Port", h.port.map(String.init) ?? ""),
      ("IdentityFile", h.identityFile), ("Mosh", h.mosh ? "yes" : ""),
      ("MoshServer", h.mosh ? h.moshServer : ""),
    ]
    if let b = blocks().first(where: { $0.alias == (old ?? h.alias) }) {
      var body = Array(lines[(b.start + 1)..<b.end])
      for (key, value) in wanted {
        let at = body.firstIndex { SSHHostsFile.keyValue($0)?.0.lowercased() == key.lowercased() }
        switch (at, value.isEmpty) {
        case (let i?, true): body.remove(at: i)
        case (let i?, false): body[i] = "  \(key) \(value)"
        case (nil, false):
          let after = body.lastIndex { SSHHostsFile.isManaged($0) } ?? -1
          body.insert("  \(key) \(value)", at: after + 1)
        case (nil, true): break
        }
      }
      lines.replaceSubrange(b.start..<b.end, with: ["Host \(h.alias)"] + body)
    } else {
      var block = ["Host \(h.alias)"]
      for (key, value) in wanted where !value.isEmpty {
        block.append("  \(key) \(value)")
      }
      let at = blocks().first { $0.alias == nil && !$0.global }?.start ?? lines.count
      if at > 0, at <= lines.count, !lines[at - 1].trimmingCharacters(in: .whitespaces).isEmpty {
        block.insert("", at: 0)
      }
      if at < lines.count {
        block.append("")
      }
      lines.insert(contentsOf: block, at: at)
    }
    if h.mosh {
      ensureIgnore()
    }
  }

  /// The alias's block goes, its lines with it.
  public mutating func remove(_ alias: String) {
    guard let b = blocks().first(where: { $0.alias == alias }) else { return }
    lines.removeSubrange(b.start..<b.end)
    func blank(_ i: Int) -> Bool { lines[i].trimmingCharacters(in: .whitespaces).isEmpty }
    if b.start > 0, b.start < lines.count, blank(b.start - 1), blank(b.start) {
      lines.remove(at: b.start)  // one blank line between blocks, not two
    }
    while let last = lines.indices.last, blank(last) {
      lines.removeLast()
    }
  }

  /// OpenSSH refuses keys it does not know unless told to skip them.
  private mutating func ensureIgnore() {
    let head = blocks().first { !$0.global }?.start ?? lines.count
    for i in 0..<head {
      guard let (key, value) = SSHHostsFile.keyValue(lines[i]), key.lowercased() == "ignoreunknown"
      else { continue }
      var names = value.split(separator: ",").map(String.init)
      for n in ["Mosh", "MoshServer"]
      where !names.contains(where: { $0.lowercased() == n.lowercased() }) {
        names.append(n)
      }
      lines[i] = "IgnoreUnknown " + names.joined(separator: ",")
      return
    }
    lines.insert(SSHHostsFile.ignore, at: 0)
    if lines.count > 1, !lines[1].trimmingCharacters(in: .whitespaces).isEmpty {
      lines.insert("", at: 1)
    }
  }

  private struct Block {
    var start: Int  // the Host line; for the global part, 0
    var end: Int  // the next block's first line
    var alias: String?  // a single plain name
    var global: Bool
  }

  private func blocks() -> [Block] {
    var out = [Block(start: 0, end: lines.count, alias: nil, global: true)]
    for (i, line) in lines.enumerated() {
      guard let (key, value) = SSHHostsFile.keyValue(line) else { continue }
      let k = key.lowercased()
      guard k == "host" || k == "match" else { continue }
      out[out.count - 1].end = i
      let names = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
      let plain =
        k == "host" && names.count == 1 && !names[0].contains(where: { "*?!".contains($0) })
      out.append(
        Block(start: i, end: lines.count, alias: plain ? String(names[0]) : nil, global: false))
    }
    return out
  }

  private static func isManaged(_ line: String) -> Bool {
    guard let key = keyValue(line)?.0.lowercased() else { return false }
    return managed.contains { $0.lowercased() == key }
  }

  /// Key and value of a line, `Key value` or `Key=value`; nil for blanks
  /// and comments.
  static func keyValue(_ line: String) -> (String, String)? {
    let t = line.trimmingCharacters(in: .whitespaces)
    guard !t.isEmpty, !t.hasPrefix("#") else { return nil }
    guard let sep = t.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
      return nil
    }
    let value = t[t.index(after: sep)...].trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "="))
      .trimmingCharacters(in: .whitespaces)
    return (String(t[..<sep]), value)
  }
}
