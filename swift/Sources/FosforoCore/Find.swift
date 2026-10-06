import Foundation

/// Search in the scrollback, typed into the status bar: what the user
/// types while it is open edits the text instead of reaching the host.
public final class Finder {
  public struct Match: Equatable, Sendable {
    public var line: Int
    public var col: Int
    public var end: Int
  }

  public enum Action {
    case none
    case edited  // the text changed: search again
    case older
    case newer
    case leave  // Return: the keyboard goes back to the host, the matches stay lit
    case edit  // the field was tapped: the keyboard is the field's again
    case close
  }

  /// Keys go to the field; off, they reach the host while the matches stay
  /// on screen, as in iTerm2.
  public var editing = true
  public private(set) var text = ""
  public private(set) var matches: [Match] = []  // oldest first
  public private(set) var current: Int?
  static let limit = 10_000  // matches counted; past it the count stops growing

  public init() {}

  /// Bytes as the keyboard encodes them (vt_key, vt_text, a paste).
  public func key(_ bytes: [UInt8]) -> Action {
    switch bytes {
    case [0x1B]: return .close
    case [0x0D]: return .leave
    case [0x1B, 0x5B, 0x41], [0x1B, 0x4F, 0x41]: return .older
    case [0x1B, 0x5B, 0x42], [0x1B, 0x4F, 0x42]: return .newer
    case [0x7F], [0x08]:
      guard !text.isEmpty else { return .none }
      text.removeLast()
      return .edited
    default:
      break
    }
    guard bytes.first != 0x1B else { return .none }  // other keys, mouse reports
    let typed = String(decoding: bytes, as: UTF8.self).unicodeScalars.filter { $0.value >= 0x20 }
    guard !typed.isEmpty else { return .none }
    text.unicodeScalars.append(contentsOf: typed)
    return .edited
  }

  /// More matches than `limit`: the oldest were dropped, the count is "N+".
  public private(set) var truncated = false
  /// What `matches` cover: the session's base, line count and rows then.
  private var scanned: (base: Int, lines: Int, rows: Int)?

  /// Finds every match again: the whole text after an edit (restart), with
  /// the newest match current; after output, only what can have changed.
  /// History is append-only, so the lines below the screen of the last pass
  /// keep their matches (moved up by what the ring dropped) and the screen
  /// and anything newer are searched again; a renumbering (reflow, screen
  /// switch) starts over.
  public func refresh(_ s: Session, restart: Bool) {
    guard !text.isEmpty else {
      matches = []
      current = nil
      truncated = false
      scanned = nil
      return
    }
    let base = s.base()
    let lines = s.lines()
    let rows = s.size().rows
    let shift = scanned.map { base - $0.base } ?? 0
    let kept = current.map { i in
      Match(line: matches[i].line - shift, col: matches[i].col, end: matches[i].end)
    }
    var all: [Match]
    if let was = scanned, !restart, shift < was.lines {
      let keep = was.lines - was.rows - shift  // addresses [0, keep) have not changed
      all = matches.compactMap { m in
        let l = m.line - shift
        return l >= 0 && l < keep ? Match(line: l, col: m.col, end: m.end) : nil
      }
      // the changed region, whole: forward and bounded; past the limit by
      // itself, its newest ones instead (a backward pass that never has to
      // leave it), and nothing older survives
      var more = s.findAll(text, back: false, from: (keep, -1), limit: Finder.limit + 1)
      if more.count > Finder.limit {
        more = s.findAll(text, back: true, from: nil, limit: Finder.limit).reversed()
        all = []
        truncated = true
      }
      all += more.map { Match(line: $0.line, col: $0.col, end: $0.end) }
      if all.count > Finder.limit {
        all.removeFirst(all.count - Finder.limit)
        truncated = true
      } else if truncated && all.count < Finder.limit {
        // the screen lost matches (cleared) and older ones were dropped for
        // the limit before: only a whole pass can bring those back
        let newest = s.findAll(text, back: true, from: nil, limit: Finder.limit)
        all = newest.reversed().map { Match(line: $0.line, col: $0.col, end: $0.end) }
        truncated = newest.count == Finder.limit
      }
    } else {
      let newest = s.findAll(text, back: true, from: nil, limit: Finder.limit)
      all = newest.reversed().map { Match(line: $0.line, col: $0.col, end: $0.end) }
      truncated = newest.count == Finder.limit
    }
    matches = all
    scanned = (base, lines, rows)
    if all.isEmpty {
      current = nil
    } else if restart || current == nil {
      current = all.count - 1
    } else if let k = kept, let i = all.firstIndex(of: k) {
      current = i  // the same match, where it is now
    } else {
      current = min(current!, all.count - 1)
    }
  }

  /// Moves to the next match going back in time, or forward; wraps around.
  public func step(back: Bool) {
    guard let c = current, !matches.isEmpty else { return }
    current = (c + (back ? matches.count - 1 : 1)) % matches.count
  }

  public var match: Match? {
    current.map { matches[$0] }
  }
}
