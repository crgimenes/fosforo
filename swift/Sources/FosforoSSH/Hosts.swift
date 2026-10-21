import Foundation

/// Host aliases in the ssh_config format, so a ~/.ssh/config can be copied
/// in as it is. HostName, User, Port, IdentityFile, IdentitiesOnly,
/// ProxyJump, ServerAlive*, LocalForward, RemoteForward, DynamicForward
/// and ForwardAgent are read; the rest (AddKeysToAgent, UseKeychain...) is ignored.
/// Mosh (yes: ssh to this host is mosh) and MoshServer (its path there) are
/// fosforo's own; `IgnoreUnknown Mosh,MoshServer` keeps OpenSSH quiet about them. As in
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
    public var mosh: Bool?  // Mosh yes
    public var moshServer: String?  // MoshServer: mosh-server's path on the host

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
      guard let (word, args) = SSHConfigLine.parse(String(raw)), !args.isEmpty else { continue }
      let key = word.lowercased()
      switch key {
      case "host":
        blocks.append(Block(patterns: args.map { $0.lowercased() }))
      case "match":
        blocks.append(Block(patterns: []))
      case "localforward", "remoteforward":
        // [bind:]port host:hostport, two words: as -L and -R spell it, one
        guard args.count == 2 else { continue }
        blocks[blocks.count - 1].settings.append((key, args[0] + ":" + args[1]))
      default:
        blocks[blocks.count - 1].settings.append((key, args[0]))
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
        case "mosh" where e.mosh == nil: e.mosh = value.lowercased() == "yes"
        case "moshserver" where e.moshServer == nil: e.moshServer = value
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

/// A line of ssh_config as OpenSSH reads it: the keyword, then its
/// arguments split on blanks, quotes grouping and a backslash escaping a
/// quote, a backslash or (outside quotes) a blank; `=` separates the keyword
/// from the arguments, once; `#` opens a comment only where a word would
/// start, so `a#b` is a name. Nil for a blank line or a comment.
enum SSHConfigLine {
  static func parse(_ line: String) -> (key: String, args: [String])? {
    let s = Array(line)
    var i = 0
    func blank(_ c: Character) -> Bool { c == " " || c == "\t" }
    while i < s.count && blank(s[i]) {
      i += 1
    }
    guard i < s.count, s[i] != "#" else { return nil }
    var key = ""
    while i < s.count && !blank(s[i]) && s[i] != "=" {
      key.append(s[i])
      i += 1
    }
    while i < s.count && blank(s[i]) {
      i += 1
    }
    if i < s.count && s[i] == "=" {
      i += 1
    }
    var args: [String] = []
    while true {
      while i < s.count && blank(s[i]) {
        i += 1
      }
      guard i < s.count, s[i] != "#" else { break }
      var arg = ""
      var quote: Character?
      while i < s.count {
        let c = s[i]
        let next: Character? = i + 1 < s.count ? s[i + 1] : nil
        if c == "\\", let next, "'\"\\".contains(next) || (quote == nil && next == " ") {
          i += 1
          arg.append(next)
        } else if quote == nil, blank(c) {
          break
        } else if quote == nil, c == "\"" || c == "'" {
          quote = c
        } else if quote == c {
          quote = nil
        } else {
          arg.append(c)
        }
        i += 1
      }
      args.append(arg)
    }
    return (key, args)
  }

  /// value as one argument of such a line: as it is when it reads back so,
  /// in double quotes otherwise.
  static func quoted(_ value: String) -> String {
    let plain =
      !value.isEmpty && !value.hasPrefix("#")
      && !value.contains(where: { " \t\"'\\".contains($0) })
    if plain {
      return value
    }
    var out = "\""
    for c in value {
      if c == "\"" || c == "\\" {
        out.append("\\")
      }
      out.append(c)
    }
    return out + "\""
  }
}
