import CFosforo
import Foundation

/// What both terminal views keep between frames and do alike: the frame
/// and how far back it is scrolled, the selection, the search and the
/// jumps from prompt to prompt. Lines are absolute (history + screen),
/// rows are on screen. Main thread only, like the views.
@MainActor
public final class Viewport {
  public let session: Session
  public var screen = Screen()
  public var scrollBack = 0
  /// Something to draw again; the view clears it after a frame, and hears
  /// through onDirty when it is set, so it can sleep in between.
  public var dirty = true {
    didSet {
      if dirty && !oldValue {
        onDirty?()
      }
    }
  }
  public var onDirty: (() -> Void)?
  /// Selection in absolute lines, so it stays on its text while the view
  /// scrolls; start before end, both inclusive.
  public private(set) var selStart: (line: Int, col: Int)?
  public private(set) var selEnd: (line: Int, col: Int)?
  private var selAnchor: (line: Int, col: Int)?
  public let finder = Finder()
  public private(set) var finding = false
  var copyMark: (line: Int, col: Int)?
  var copyHandler: ((String) -> Void)?

  public init(session: Session) {
    self.session = session
    base = session.base()
  }

  public var topLine: Int { session.lines() - screen.rows - scrollBack }

  private func absolute(_ at: (row: Int, col: Int)) -> (line: Int, col: Int) {
    (topLine + at.row, at.col)
  }

  /// The terminal's generation as of the last frame's refresh.
  private var seen: UInt64 = .max

  /// Before a frame: output since the last one refreshes what follows it
  /// (the search). What is remembered is the generation seen here, not the
  /// snapshot's: output that lands between the two is refreshed next frame
  /// instead of passing as seen.
  public func beforeFrame() {
    let now = session.generation()
    if now != seen {
      seen = now
      outputChanged()
    }
  }

  /// New output reached the core: the matches may have moved.
  public func outputChanged() {
    dirty = true
    rebase()
    scrollBack = min(scrollBack, session.history())  // ⌘K or a screen switch took it away
    if finding {
      finder.refresh(session, restart: false)
    }
  }

  /// session.base() when the addresses here were taken.
  private var base = 0

  /// Lines are addressed from the oldest one kept, so every line the
  /// history drops moves the addresses up by one (a reflow renumbers them
  /// all): the selection and the mark follow their text, and what the ring
  /// let go of is gone from them too, so an old selection never copies
  /// other text.
  private func rebase() {
    let now = session.base()
    let shift = now - base
    guard shift != 0 else { return }
    base = now
    func moved(_ p: (line: Int, col: Int)) -> (line: Int, col: Int) {
      p.line < shift ? (0, 0) : (p.line - shift, p.col)
    }
    if let e = selEnd, e.line < shift {
      selStart = nil
      selEnd = nil
      selAnchor = nil
    } else {
      selStart = selStart.map(moved)
      selEnd = selEnd.map(moved)
      selAnchor = selAnchor.map(moved)
    }
    if let m = copyMark {
      copyMark = m.line < shift ? (0, m.col) : (m.line - shift, m.col)
    }
    dirty = true
  }

  /// A key was typed: back to the live screen, unless the search holds it.
  public func live() {
    if scrollBack != 0 && !finding && !copying {
      scrollBack = 0
      dirty = true
    }
  }

  public func scroll(by lines: Int) {
    scrollBack = max(0, min(session.history(), scrollBack + lines))
    dirty = true
  }

  // MARK: - selection

  public var hasSelection: Bool { selStart != nil }

  /// A click that did not drag: nothing worth keeping.
  public var selectsOneCell: Bool {
    guard let s = selStart, let e = selEnd else { return false }
    return s == e
  }

  public func anchorSelection(at: (row: Int, col: Int)) {
    let a = absolute(at)
    selAnchor = a
    selStart = a
    selEnd = a
    dirty = true
  }

  private static let wordChars = Set("_-./~:@%+=&?#,".unicodeScalars.map(\.value))

  private static func isWord(_ cp: UInt32) -> Bool {
    guard cp > 32, let s = Unicode.Scalar(cp) else { return false }
    return s.properties.isAlphabetic || s.properties.numericType != nil
      || wordChars.contains(cp)
  }

  /// Whether the cell is part of a word: the tail of a wide glyph goes
  /// with its head.
  private func wordCell(_ row: Int, _ col: Int) -> Bool {
    let cell = screen.cell(row, col)
    if UInt32(cell.flags) & UInt32(VT_CELL_WIDE_TAIL) != 0 {
      return col > 0 && Viewport.isWord(screen.cell(row, col - 1).cp)
    }
    return Viewport.isWord(cell.cp)
  }

  /// The word under `at` (letters, digits and what paths and URLs are made
  /// of); the cell alone when it holds none, both cells of a wide glyph.
  public func selectWord(at: (row: Int, col: Int)) {
    var lo = at.col
    var hi = at.col
    let cell = screen.cell(at.row, at.col)
    if UInt32(cell.flags) & UInt32(VT_CELL_WIDE_TAIL) != 0 && lo > 0 {
      lo -= 1  // clicked on the second half: the glyph starts one cell left
    }
    if wordCell(at.row, lo) {
      while lo > 0 && wordCell(at.row, lo - 1) { lo -= 1 }
      while hi < screen.cols - 1 && wordCell(at.row, hi + 1) { hi += 1 }
    } else if UInt32(screen.cell(at.row, lo).flags) & UInt32(VT_CELL_WIDE) != 0 {
      hi = min(lo + 1, screen.cols - 1)  // a wide glyph that is no word (an emoji): both halves
    }
    let line = topLine + at.row
    selAnchor = (line, lo)
    selStart = (line, lo)
    selEnd = (line, hi)
    dirty = true
  }

  /// The whole line of text under `at`: the rows autowrap joined count as
  /// one, as a triple click selects them in iTerm2.
  public func selectLine(at: (row: Int, col: Int)) {
    var first = topLine + at.row
    var last = first
    while first > 0 && session.wrapped(first - 1) { first -= 1 }
    while session.wrapped(last) { last += 1 }
    selAnchor = (first, 0)
    selStart = (first, 0)
    selEnd = (last, screen.cols - 1)
    dirty = true
  }

  /// Dragging: the anchor stays, the other end follows.
  public func extendSelection(to at: (row: Int, col: Int)) {
    guard let a = selAnchor else { return }
    let h = absolute(at)
    let before = h.line < a.line || (h.line == a.line && h.col < a.col)
    selStart = before ? h : a
    selEnd = before ? a : h
    dirty = true
  }

  public func clearSelection() {
    selStart = nil
    selEnd = nil
    selAnchor = nil
    dirty = true
  }

  /// The selected text, nil when there is none.
  public func selectedText() -> String? {
    rebase()  // output since the last frame may have moved the lines
    guard let s = selStart, let e = selEnd else { return nil }
    let text = session.copyText(from: s, to: e)
    return text.isEmpty ? nil : text
  }

  /// Visible part of the selection, for the renderer.
  public func visibleSelection() -> (start: (row: Int, col: Int), end: (row: Int, col: Int))? {
    guard let s = selStart, let e = selEnd else { return nil }
    let top = topLine
    var a = (row: s.line - top, col: s.col)
    var b = (row: e.line - top, col: e.col)
    if b.row < 0 || a.row >= screen.rows {
      return nil
    }
    if a.row < 0 { a = (0, 0) }
    if b.row >= screen.rows { b = (screen.rows - 1, screen.cols - 1) }
    return (a, b)
  }

  // MARK: - find, in the status bar: typing edits the text, Up goes older,
  // Down newer, Esc closes. Return or a click on the terminal gives the
  // keyboard back to the host with the matches still lit, as iTerm2 does;
  // a click on the field, or find() again, takes it back.

  public func find() {
    if !finding {
      finding = true
      finder.refresh(session, restart: true)
    }
    focusField(true)
  }

  /// The field takes the keys (⌘F, a click or tap on it) or gives them
  /// back; copy mode, which cannot share them, ends when the field takes
  /// them and keeps them when the search closes around it.
  public func focusField(_ on: Bool) {
    if on && copying {
      exitCopyMode()
    }
    finder.editing = on
    if on {
      session.intercept = { [weak self] bytes in
        guard let self else { return }
        self.apply(self.finder.key(bytes))
      }
    } else if copying {
      session.intercept = { [weak self] bytes in self?.copyKey(bytes) }
    } else {
      session.intercept = nil
    }
    dirty = true
  }

  /// False when there was no match to show (the Mac beeps).
  @discardableResult
  public func apply(_ action: Finder.Action) -> Bool {
    switch action {
    case .edited: finder.refresh(session, restart: true)
    case .older: finder.step(back: true)
    case .newer: finder.step(back: false)
    case .leave:
      focusField(false)
      return true
    case .edit:
      focusField(true)
      return true
    case .close:
      finding = false
      focusField(false)
      return true
    case .none: return true
    }
    return reveal()
  }

  @discardableResult
  public func step(back: Bool) -> Bool {
    guard !finder.text.isEmpty else { return true }
    finder.refresh(session, restart: false)
    finder.step(back: back)
    return reveal()
  }

  /// The current match, selected (to copy) and scrolled into sight, centered.
  private func reveal() -> Bool {
    dirty = true
    guard let m = finder.match else { return false }
    selStart = (m.line, m.col)
    selEnd = (m.line, m.end)
    selAnchor = selStart
    let top = topLine
    if m.line < top || m.line >= top + screen.rows {
      let want = session.lines() - screen.rows - (m.line - screen.rows / 2)
      scrollBack = max(0, min(session.history(), want))
    }
    return true
  }

  /// The matches in view, for the renderer to highlight; none once closed.
  public func visibleMatches() -> [(row: Int, start: Int, end: Int)] {
    guard finding else { return [] }
    let top = topLine
    return finder.matches.compactMap { m in
      m.line >= top && m.line < top + screen.rows ? (m.line - top, m.col, m.end) : nil
    }
  }

  /// ⌘↑/⌘↓: from prompt to prompt (the shell marks them with OSC 133;A),
  /// the prompt at the top of the view; past the last one, back to live.
  public func jumpPrompt(back: Bool) {
    let lines = session.lines()
    let top = topLine
    let from = scrollBack == 0 && back ? top + Int(screen.cursor.row) : top
    var found = session.prompt(from: from, back: back)
    while back, let l = found, l > top {  // already in view: it cannot go higher
      found = session.prompt(from: l, back: true)
    }
    guard let line = found else {
      if !back {
        scrollBack = 0
        dirty = true
      }
      return
    }
    scrollBack = max(0, min(session.history(), lines - screen.rows - line))
    dirty = true
  }
}

// MARK: - copy mode: the keyboard moves a mark over the screen and the
// history instead of reaching the host, as in iTerm2 and tmux. Arrows or
// h j k l move; v anchors a selection that then follows the mark, as
// do Shift+arrows; y copies and leaves; Esc or q leaves; g and
// G go to the oldest and the newest line, Home/End or 0/$ to the ends of
// the line, PageUp/PageDown a screen at a time.
extension Viewport {
  public var copying: Bool { copyMark != nil }

  /// What the view does with the text when y copies it.
  public var onCopy: ((String) -> Void)? {
    get { copyHandler }
    set { copyHandler = newValue }
  }

  public func enterCopyMode() {
    if finding && finder.editing {
      focusField(false)
    }
    copyMark = (topLine + Int(screen.cursor.row), Int(screen.cursor.col))
    session.intercept = { [weak self] bytes in self?.copyKey(bytes) }
    dirty = true
  }

  public func exitCopyMode() {
    copyMark = nil
    session.intercept = nil
    dirty = true
  }

  /// The mark on screen, for the renderer; nil while it is scrolled away.
  public func visibleMark() -> (row: Int, col: Int)? {
    guard let m = copyMark else { return nil }
    let row = m.line - topLine
    return row >= 0 && row < screen.rows ? (row, m.col) : nil
  }

  /// The mark never rests on the second half of a wide glyph: going right
  /// it passes the glyph, otherwise it lands on its head. Only the rows on
  /// screen are known; a line just scrolled into view is left as it is.
  private func offTail(_ line: Int, _ col: Int, rightward: Bool) -> Int {
    let row = line - topLine
    guard row >= 0, row < screen.rows, col > 0,
      UInt32(screen.cell(row, col).flags) & UInt32(VT_CELL_WIDE_TAIL) != 0
    else {
      return col
    }
    return rightward && col + 1 < screen.cols ? col + 1 : col - 1
  }

  private func copyKey(_ bytes: [UInt8]) {
    guard let m = copyMark else { return }
    var line = m.line
    var col = m.col
    var extend = false
    switch bytes {
    case [0x1B], [UInt8(ascii: "q")]:
      clearSelection()
      exitCopyMode()
      return
    case [UInt8(ascii: "y")]:
      if let text = selectedText() {
        copyHandler?(text)
      }
      exitCopyMode()
      return
    case [UInt8(ascii: "v")]:
      if selAnchor == nil {
        selAnchor = m
        selStart = m
        selEnd = m
      } else {
        clearSelection()
      }
      dirty = true
      return
    case [0x1B, 0x5B, 0x41], [0x1B, 0x4F, 0x41], [UInt8(ascii: "k")]: line -= 1
    case [0x1B, 0x5B, 0x42], [0x1B, 0x4F, 0x42], [UInt8(ascii: "j")]: line += 1
    case [0x1B, 0x5B, 0x43], [0x1B, 0x4F, 0x43], [UInt8(ascii: "l")]: col += 1
    case [0x1B, 0x5B, 0x44], [0x1B, 0x4F, 0x44], [UInt8(ascii: "h")]: col -= 1
    case [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41]:
      line -= 1
      extend = true
    case [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x42]:
      line += 1
      extend = true
    case [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x43]:
      col += 1
      extend = true
    case [0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x44]:
      col -= 1
      extend = true
    case [0x1B, 0x5B, 0x35, 0x7E]: line -= screen.rows
    case [0x1B, 0x5B, 0x36, 0x7E]: line += screen.rows
    case [0x1B, 0x5B, 0x48], [0x1B, 0x4F, 0x48], [UInt8(ascii: "0")]: col = 0
    case [0x1B, 0x5B, 0x46], [0x1B, 0x4F, 0x46], [UInt8(ascii: "$")]: col = screen.cols - 1
    case [UInt8(ascii: "g")]: line = 0
    case [UInt8(ascii: "G")]: line = session.lines() - 1
    default: return
    }
    if extend && selAnchor == nil {
      selAnchor = m
      selStart = m
      selEnd = m
    }
    line = max(0, min(session.lines() - 1, line))
    col = max(0, min(screen.cols - 1, col))
    col = offTail(line, col, rightward: col > m.col)
    copyMark = (line, col)
    if line < topLine {
      scroll(by: topLine - line)
    } else if line >= topLine + screen.rows {
      scroll(by: topLine + screen.rows - 1 - line)
    }
    if selAnchor != nil {
      extendSelection(to: (line - topLine, col))
    }
    dirty = true
  }
}
