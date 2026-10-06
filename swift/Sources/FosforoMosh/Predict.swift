import CFosforo
import FosforoCore
import Foundation

/// Local echo, as the Mosh client does it: typed characters are drawn
/// before the server echoes them. Each guess is checked once the server
/// acknowledges having echoed its keystroke; one wrong guess drops them all.
/// After anything that is not plain typing (Return, a control key) guesses
/// stay hidden until one is confirmed, so a password prompt never shows.
/// yagni: no shifting the rest of the line on insert, no wide characters.
struct Predictor {
  enum Mode {
    case adaptive  // only when the round trip is long enough to notice
    case always
  }

  struct Guess {
    var row: Int
    var col: Int
    var cp: UInt32
    var epoch: Int
    var index: Int  // input events the server must echo before this is checked
    var at: Date
  }

  var mode = Mode.adaptive
  private(set) var guesses: [Guess] = []
  private var cursor: (row: Int, col: Int)?
  private var cursorEpoch = 0
  private var cursorIndex = 0
  private var epoch = 1
  private var confirmed = 0
  private var latest = 0
  private var holdUntil = 0
  private(set) var srtt: Double?
  private var showing = false
  private var slow = false
  private var glitch = false
  private(set) var generation: UInt64 = 0

  // thresholds from the Mosh client, in seconds
  static let showAbove = 0.030
  static let hideBelow = 0.020
  static let flagAbove = 0.080
  static let unflagBelow = 0.050
  static let glitchAfter = 0.250

  var pending: Bool { !guesses.isEmpty || cursor != nil }

  mutating func rtt(_ sample: Double) {
    let s = srtt.map { $0 * 7 / 8 + sample / 8 } ?? sample
    srtt = s
    var show = showing
    if s > Predictor.showAbove { show = true }
    if s < Predictor.hideBelow { show = false }
    var flag = slow
    if s > Predictor.flagAbove { flag = true }
    if s < Predictor.unflagBelow { flag = false }
    if show != showing || flag != slow {
      showing = show
      slow = flag
      generation += 1
    }
  }

  private enum Key {
    case char(UInt32)
    case backspace
    case left
    case right
    case other
  }

  private static func keys(_ bytes: [UInt8]) -> [Key] {
    switch bytes {
    case [0x1B, 0x5B, 0x43], [0x1B, 0x4F, 0x43]: return [.right]
    case [0x1B, 0x5B, 0x44], [0x1B, 0x4F, 0x44]: return [.left]
    default: break
    }
    var out: [Key] = []
    for s in String(decoding: bytes, as: UTF8.self).unicodeScalars {
      switch s.value {
      case 0x7F: out.append(.backspace)
      // narrow for certain: ASCII, Latin-1, Latin Extended
      case 0x20..<0x7F, 0xA0..<0x300: out.append(.char(s.value))
      default: out.append(.other)
      }
    }
    return out
  }

  /// Keys the user typed. `index` is the input event count once they are
  /// sent, `echoed` how many the server has echoed; `real` is the cursor of
  /// the newest server screen.
  mutating func typed(
    _ bytes: [UInt8], index: Int, echoed: Int, real: (row: Int, col: Int), cols: Int, now: Date
  ) {
    latest = index
    if echoed < holdUntil {
      holdUntil = index  // the real cursor will not account for these either
      return
    }
    var c = cursor ?? real
    for k in Predictor.keys(bytes) {
      switch k {
      case .char(let cp) where c.col < cols - 1:
        guesses.removeAll { $0.row == c.row && $0.col == c.col }
        guesses.append(Guess(row: c.row, col: c.col, cp: cp, epoch: epoch, index: index, at: now))
        c.col += 1
      case .backspace where c.col > 0:
        c.col -= 1
        guesses.removeAll { $0.row == c.row && $0.col == c.col }
        guesses.append(Guess(row: c.row, col: c.col, cp: 0x20, epoch: epoch, index: index, at: now))
      case .right where c.col < cols - 1:
        c.col += 1
      case .left where c.col > 0:
        c.col -= 1
      default:
        // unknown effect: wait for the server, and start over tentative
        cursor = nil
        epoch += 1
        holdUntil = index
        generation += 1
        return
      }
    }
    cursor = c
    cursorEpoch = epoch
    cursorIndex = index
    generation += 1
  }

  /// Checks the guesses the server has echoed against its screen.
  mutating func check(echoed: Int, cell: (Int, Int) -> UInt32, real: (row: Int, col: Int)) {
    var keep: [Guess] = []
    for g in guesses {
      if g.index > echoed {
        keep.append(g)
        continue
      }
      let cp = cell(g.row, g.col)
      guard cp == g.cp || (g.cp == 0x20 && cp == 0) else {
        reset()
        return
      }
      confirmed = max(confirmed, g.epoch)
    }
    if keep.count != guesses.count {
      generation += 1
    }
    guesses = keep
    if let c = cursor, cursorIndex <= echoed {
      guard c == real else {
        reset()
        return
      }
      cursor = nil
      generation += 1
    }
  }

  /// Drops every guess and waits for the server to catch up with what was
  /// typed so far (a wrong guess, a resize).
  mutating func reset() {
    guesses.removeAll()
    cursor = nil
    epoch += 1
    holdUntil = latest
    generation += 1
  }

  /// Underlines the guesses once one has waited too long for its echo.
  mutating func tick(now: Date) {
    let late = guesses.contains {
      $0.epoch <= confirmed && now.timeIntervalSince($0.at) > Predictor.glitchAfter
    }
    if late != glitch {
      glitch = late
      generation += 1
    }
  }

  func overlay(_ screen: inout Screen) {
    guard mode == .always || (mode == .adaptive && showing) else { return }
    let underline = slow || glitch
    for g in guesses where g.epoch <= confirmed && g.row < screen.rows && g.col < screen.cols {
      let i = g.row * screen.cols + g.col
      screen.cells[i].cp = g.cp
      screen.cells[i].flags = 0
      if underline {
        screen.cells[i].attr =
          screen.cells[i].attr & ~UInt16(VT_ATTR_UL_MASK)
          | UInt16(UInt32(VT_UL_SINGLE) << VT_ATTR_UL_SHIFT)
      }
    }
    if let c = cursor, cursorEpoch <= confirmed, c.row < screen.rows, c.col < screen.cols {
      screen.cursor.row = Int32(c.row)
      screen.cursor.col = Int32(c.col)
    }
  }
}
