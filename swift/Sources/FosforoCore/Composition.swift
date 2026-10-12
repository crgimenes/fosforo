import Foundation

/// What an input method is composing (dead keys, kana, hangul), with the
/// selection inside it: the whole "document" UITextInput sees, counted in
/// UTF-16 as that protocol's ranges are. Nothing of it is the host's until
/// committed.
public struct Composition: Equatable, Sendable {
  public private(set) var text = ""
  public private(set) var selection = NSRange(location: 0, length: 0)

  public init() {}

  public var length: Int { text.utf16.count }
  public var isEmpty: Bool { text.isEmpty }

  /// setMarkedText: the new composition replaces the old one whole.
  public mutating func mark(_ text: String, selected: NSRange) {
    self.text = text
    selection = clamped(selected)
  }

  public mutating func select(_ range: NSRange) {
    selection = clamped(range)
  }

  /// replace(_:withText:) inside the composition: it goes on, the caret
  /// after what came in.
  public mutating func replace(_ range: NSRange, with new: String) {
    let r = clamped(range)
    text = (text as NSString).replacingCharacters(in: r, with: new)
    selection = NSRange(location: r.location + new.utf16.count, length: 0)
  }

  public func text(in range: NSRange) -> String {
    (text as NSString).substring(with: clamped(range))
  }

  /// The composition as it stands, taken (committed); empty after.
  public mutating func commit() -> String {
    defer { self = Composition() }
    return text
  }

  /// Within the text, and never splitting a surrogate pair at either end.
  private func clamped(_ r: NSRange) -> NSRange {
    let ns = text as NSString
    let n = ns.length
    let a = min(max(r.location == NSNotFound ? n : r.location, 0), n)
    let b = min(max(a + max(r.length, 0), a), n)
    return ns.rangeOfComposedCharacterSequences(for: NSRange(location: a, length: b - a))
  }
}
