import Foundation

/// settings.filo, the config screen's file: one `(set Key value)` a line,
/// and `(theme "name")`. The lines it does not know stay as they are, so a
/// hand in the file is kept; what it changes is the line for that key.
public struct SettingsFile: Equatable {
  public private(set) var lines: [String]

  public static let header = [
    ";; settings.filo: written by the config screen (`config` in the shell).",
    ";; init.filo runs after it, so what init.filo sets wins.",
  ]

  public init(_ text: String) {
    lines = text.isEmpty ? SettingsFile.header : text.components(separatedBy: "\n")
    while lines.last == "" {
      lines.removeLast()
    }
  }

  public init(contentsOf url: URL) {
    self.init((try? String(contentsOf: url, encoding: .utf8)) ?? "")
  }

  public static var url: URL {
    Theme.configURL.deletingLastPathComponent().appendingPathComponent("settings.filo")
  }

  public var text: String { lines.joined(separator: "\n") + "\n" }

  public func write(to url: URL = SettingsFile.url) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
  }

  /// The value as written in the file, "18" or "\"phosphor\""; nil when unset.
  public subscript(key: String) -> String? {
    guard let i = index(of: key) else { return nil }
    let line = lines[i].trimmingCharacters(in: .whitespaces)
    let start = line.index(line.startIndex, offsetBy: "(set \(key) ".count)
    return String(line[start..<line.index(before: line.endIndex)])
  }

  public mutating func set(_ key: String, number: Double) {
    let text = number == number.rounded() ? String(Int(number)) : String(number)
    put("(set \(key) \(text))", at: index(of: key))
  }

  public mutating func set(_ key: String, flag: Bool) {
    put("(set \(key) \(flag ? "#t" : "#f"))", at: index(of: key))
  }

  public mutating func set(_ key: String, string: String) {
    put("(set \(key) \(SettingsFile.quote(string)))", at: index(of: key))
  }

  /// Back to init.filo's value or the default: the line goes.
  public mutating func unset(_ key: String) {
    if let i = index(of: key) {
      lines.remove(at: i)
    }
  }

  /// The theme picked here; nil for none.
  public var theme: String? {
    get {
      guard let i = themeIndex else { return nil }
      let line = lines[i].trimmingCharacters(in: .whitespaces)
      return String(line.dropFirst("(theme \"".count).dropLast("\")".count))
    }
    set {
      guard let name = newValue else {
        if let i = themeIndex {
          lines.remove(at: i)
        }
        return
      }
      put("(theme \(SettingsFile.quote(name)))", at: themeIndex)
    }
  }

  private mutating func put(_ line: String, at i: Int?) {
    if let i {
      lines[i] = line
    } else {
      lines.append(line)
    }
  }

  private func index(of key: String) -> Int? {
    lines.firstIndex {
      let t = $0.trimmingCharacters(in: .whitespaces)
      return t.hasPrefix("(set \(key) ") && t.hasSuffix(")")
    }
  }

  private var themeIndex: Int? {
    lines.firstIndex {
      let t = $0.trimmingCharacters(in: .whitespaces)
      return t.hasPrefix("(theme \"") && t.hasSuffix("\")")
    }
  }

  /// A Filo string literal.
  static func quote(_ s: String) -> String {
    var out = "\""
    for c in s {
      switch c {
      case "\"": out += "\\\""
      case "\\": out += "\\\\"
      case "\n": out += "\\n"
      default: out.append(c)
      }
    }
    return out + "\""
  }
}
