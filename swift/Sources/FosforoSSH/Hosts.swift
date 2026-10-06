import Foundation

/// Host aliases in the ssh_config format, so a ~/.ssh/config can be copied
/// in as it is. HostName, User, Port, IdentityFile, IdentitiesOnly,
/// ProxyJump, ServerAlive*, LocalForward, RemoteForward, DynamicForward
/// and ForwardAgent are read; the rest (AddKeysToAgent, UseKeychain...) is ignored. As in
/// OpenSSH, every Host block whose patterns match applies, in file order,
/// and the first value found wins (IdentityFile adds up): specific blocks
/// go first, `Host *` last.
/// yagni: Include and Match are ignored (a Match block applies to nothing).
public struct SSHHosts: Sendable {
  public struct Entry: Sendable, Equatable {
    public var hostName: String?
    public var user: String?
    public var port: Int?
    public var identityFiles: [String] = []  // every one that applies, in order
    public var identitiesOnly = false
    public var aliveInterval: Int?  // ServerAliveInterval
    public var aliveCountMax: Int?  // ServerAliveCountMax
    public var proxyJump: String?  // ProxyJump: the first hop only (yagni: no chain)
    public var localForwards: [String] = []  // as -L spells them; these add up
    public var remoteForwards: [String] = []  // as -R spells them
    public var dynamicForwards: [String] = []  // as -D spells them
    public var forwardAgent: Bool?

    public init(
      hostName: String? = nil, user: String? = nil, port: Int? = nil, identityFiles: [String] = [],
      identitiesOnly: Bool = false
    ) {
      self.hostName = hostName
      self.user = user
      self.port = port
      self.identityFiles = identityFiles
      self.identitiesOnly = identitiesOnly
    }
  }

  private struct Block {
    var patterns: [String]
    var settings: [(key: String, value: String)] = []
    /// The lines before the first Host: they apply to every host, first.
    var global = false
  }

  private var blocks = [Block(patterns: ["*"], global: true)]

  public init(_ text: String) {
    for raw in text.split(whereSeparator: \.isNewline) {
      let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
      let words = line.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
      guard let key = words.first?.lowercased(), words.count >= 2 else { continue }
      switch key {
      case "host":
        blocks.append(Block(patterns: words.dropFirst().map { $0.lowercased() }))
      case "match":
        blocks.append(Block(patterns: []))
      case "localforward", "remoteforward":
        // [bind:]port host:hostport, two words: as -L and -R spell it, one
        guard words.count == 3 else { continue }
        blocks[blocks.count - 1].settings.append((key, words[1] + ":" + words[2]))
      default:
        blocks[blocks.count - 1].settings.append((key, String(words[1])))
      }
    }
  }

  public init(contentsOf url: URL) {
    self.init((try? String(contentsOf: url, encoding: .utf8)) ?? "")
  }

  /// A block applies when a pattern matches and no negated one does.
  private static func applies(_ patterns: [String], to host: String) -> Bool {
    var hit = false
    for p in patterns {
      if p.hasPrefix("!") {
        if glob(Array(p.dropFirst()), Array(host)) {
          return false
        }
      } else if glob(Array(p), Array(host)) {
        hit = true
      }
    }
    return hit
  }

  static func glob(_ p: [Character], _ s: [Character]) -> Bool {
    var pi = 0
    var si = 0
    var star = -1
    var mark = 0
    while si < s.count {
      if pi < p.count && (p[pi] == "?" || p[pi] == s[si]) {
        pi += 1
        si += 1
      } else if pi < p.count && p[pi] == "*" {
        star = pi
        mark = si
        pi += 1
      } else if star >= 0 {
        pi = star + 1
        mark += 1
        si = mark
      } else {
        return false
      }
    }
    while pi < p.count && p[pi] == "*" {
      pi += 1
    }
    return pi == p.count
  }

  /// The settings for a host as typed; nil when no block applies.
  public subscript(name: String) -> Entry? {
    let host = name.lowercased()
    var e = Entry()
    var any = false
    var identitiesOnlySet = false  // first value wins here too; false may be explicit
    for b in blocks where SSHHosts.applies(b.patterns, to: host) {
      if !b.global || !b.settings.isEmpty {
        any = true
      }
      for (key, value) in b.settings {
        switch key {
        case "hostname" where e.hostName == nil:
          e.hostName = value.replacingOccurrences(of: "%%", with: "\u{0}")
            .replacingOccurrences(of: "%h", with: name)
            .replacingOccurrences(of: "\u{0}", with: "%")
        case "user" where e.user == nil: e.user = value
        case "identityfile": e.identityFiles.append(value)  // these add up, as in OpenSSH
        case "identitiesonly" where !identitiesOnlySet:
          e.identitiesOnly = value.lowercased() == "yes"
          identitiesOnlySet = true
        case "proxyjump" where e.proxyJump == nil:
          let first = value.split(separator: ",").first.map(String.init) ?? ""
          e.proxyJump = first.lowercased() == "none" || first.isEmpty ? nil : first
        case "localforward": e.localForwards.append(value)
        case "remoteforward": e.remoteForwards.append(value)
        case "dynamicforward": e.dynamicForwards.append(value)
        case "forwardagent" where e.forwardAgent == nil:
          e.forwardAgent = value.lowercased() == "yes"
        case "serveraliveinterval" where e.aliveInterval == nil: e.aliveInterval = Int(value)
        case "serveralivecountmax" where e.aliveCountMax == nil: e.aliveCountMax = Int(value)
        case "port" where e.port == nil:
          if let p = Int(value), (1...65535).contains(p) {
            e.port = p
          }
        default: break
        }
      }
    }
    return any ? e : nil
  }
}
