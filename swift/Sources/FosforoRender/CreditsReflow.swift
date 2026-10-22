import Foundation

extension Credits {
  /// The notices come hard-wrapped at 72 columns, too wide for a phone: a
  /// line continues the one before unless that ended a sentence or this
  /// one starts an item (a copyright line, a bullet, a numbered clause).
  public static func reflowed(_ notices: String) -> String {
    var out: [String] = []
    for raw in notices.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = raw.trimmingCharacters(in: .whitespaces)
      let item =
        line.isEmpty || line.hasPrefix("*") || line.hasPrefix("Copyright")
        || line.first?.isNumber == true && line.dropFirst().hasPrefix(".")
      if let last = out.last, !last.isEmpty, !item, !last.hasSuffix("."), !last.hasSuffix(":") {
        out[out.count - 1] = last + " " + line
      } else {
        out.append(line)
      }
    }
    return out.joined(separator: "\n")
  }
}
