import CFosforo

/// What the keyboard sends beyond what the core encodes.
public enum Keys {
  /// Option with an arrow or Backspace moves or deletes by the word, as
  /// Terminal.app sends them (OptionArrows "word") (ESC b, ESC f, ESC DEL: readline
  /// and zsh know these without any configuration); Option with a letter
  /// still composes the character. nil for any other key.
  public static func optionWord(_ key: Int32) -> [UInt8]? {
    switch key {
    case Int32(VT_KEY_LEFT): return [0x1B, UInt8(ascii: "b")]
    case Int32(VT_KEY_RIGHT): return [0x1B, UInt8(ascii: "f")]
    case Int32(VT_KEY_BACKSPACE): return [0x1B, 0x7F]
    default: return nil
    }
  }
}
