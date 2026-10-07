import CFosforo
import Foundation
import Testing

@testable import FosforoCore

/// Polls until the condition holds or five seconds pass: the child runs on
/// its own schedule and there is nothing to await but its output.
private func eventually(_ condition: () -> Bool) -> Bool {
  let deadline = Date().addingTimeInterval(5)
  while Date() < deadline {
    if condition() {
      return true
    }
    Thread.sleep(forTimeInterval: 0.01)
  }
  return condition()
}

private func text(_ screen: Screen, row: Int) -> String {
  var s = ""
  for c in 0..<screen.cols {
    let cell = screen.cell(row, c)
    if cell.flags & UInt8(VT_CELL_WIDE_TAIL) != 0 {
      continue
    }
    s.unicodeScalars.append(Unicode.Scalar(cell.cp == 0 ? 32 : cell.cp) ?? " ")
  }
  while s.hasSuffix(" ") {
    s.removeLast()
  }
  return s
}

private func shell(_ script: String, rows: Int = 5, cols: Int = 30) throws -> Session {
  let s = try Session(
    executable: "/bin/sh", argv: ["sh", "-c", script],
    environment: ["PATH": "/bin:/usr/bin", "TERM": "xterm-256color"], directory: nil,
    rows: rows, cols: cols, history: 100)
  s.start()
  return s
}

@Test func outputReachesTheScreenWithColors() throws {
  let s = try shell("printf '\\033[31mred\\033[0m\\n'; stty size")
  #expect(eventually { s.hasExited })
  var screen = Screen()
  s.snapshot(into: &screen)
  #expect(text(screen, row: 0) == "red")
  #expect(screen.cell(0, 0).fg == (1 << 24 | 1))
  #expect(text(screen, row: 1) == "5 30")
}

@Test func repliesGoBackToTheChild() throws {
  let s = try shell(
    "stty -echo -icanon min 0 time 20; printf '\\033[3;7H\\033[6n'; x=$(dd bs=6 count=1 2>/dev/null); printf '\\r\\n%s' \"${x#?}\""
  )
  #expect(eventually { s.hasExited })
  var screen = Screen()
  s.snapshot(into: &screen)
  #expect(text(screen, row: 3) == "[3;7R")
}

@Test func resizeReachesTheChild() throws {
  let s = try shell("read x; stty size")
  s.resize(rows: 10, cols: 40)
  s.send("\n")
  #expect(eventually { s.hasExited })
  var screen = Screen()
  s.snapshot(into: &screen)
  #expect(screen.rows == 10 && screen.cols == 40)
  #expect((0..<screen.rows).contains { text(screen, row: $0) == "10 40" })
}

/// ⌘T opens where the session in front is: the directory comes from its
/// foreground process and goes to the new shell as it is, spaces, Unicode
/// and all, through the pty and not through a command line.
@Test func aShellOpensInTheDirectoryItIsGiven() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
    "fosforo ünï 日本 \(UUID().uuidString)")
  defer { try? FileManager.default.removeItem(at: dir) }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let real = realpath(dir.path, nil)!  // /var is /private/var to the kernel
  defer { free(real) }
  let path = String(cString: real)
  let s = try Session(
    executable: "/bin/sh", argv: ["sh", "-c", "pwd; sleep 5"],
    environment: ["PATH": "/bin:/usr/bin"], directory: path, rows: 3, cols: 200, history: 0)
  s.start()
  #expect(eventually { s.generation() > 0 && s.transport.foreground().cwd == path })
  var screen = Screen()
  s.snapshot(into: &screen)
  #expect(text(screen, row: 0) == path)
  s.transport.hangup()
}

/// Output the test feeds a little at a time.
private final class Feed: Transport, @unchecked Sendable {
  private var output: (([UInt8]) -> Void)?
  func start(
    output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void
  ) {
    self.output = output
  }
  func write(_ text: String) { output?(Array(text.utf8)) }
  func send(_ bytes: [UInt8]) {}
  func resize(rows: Int, cols: Int) {}
  func hangup() {}
}

/// Every line the history drops moves the addresses up by one: the
/// selection and the copy mark stay on their text, lose what the ring let
/// go of, and go when all of it went; a reflow renumbers everything.
@MainActor @Test func selectionFollowsItsTextWhenHistoryDropsLines() throws {
  let host = Feed()
  let s = try Session(transport: host, rows: 2, cols: 8, history: 2)
  s.start()
  host.write("A\r\nB\r\nC\r\nD")
  let vp = Viewport(session: s)
  func show(back: Int) {
    vp.outputChanged()
    vp.scrollBack = back
    s.snapshot(into: &vp.screen, back: back)
  }
  show(back: 2)  // A and B in view
  vp.selectLine(at: (1, 0))
  #expect(vp.selectedText() == "B")
  host.write("\r\nE")  // A is gone
  show(back: 2)
  #expect(vp.selectedText() == "B" && vp.visibleSelection()?.start.row == 0)
  host.write("\r\nF")  // B is gone
  show(back: 2)
  #expect(vp.selectedText() == nil && !vp.hasSelection)
  vp.anchorSelection(at: (0, 0))  // C and D
  vp.extendSelection(to: (1, 0))
  #expect(vp.selectedText() == "C\nD")
  host.write("\r\nG")  // what is left of it: D
  show(back: 2)
  #expect(vp.selectedText() == "D")
  vp.clearSelection()
  show(back: 0)
  vp.enterCopyMode()  // the mark on G, the cursor's line
  #expect(vp.visibleMark()?.row == 1)
  host.write("\r\nH")
  show(back: 1)
  #expect(vp.visibleMark()?.row == 1)  // still on G, one line up now
  vp.exitCopyMode()
  vp.selectLine(at: (0, 0))
  #expect(vp.selectedText() == "F")
  s.resize(rows: 2, cols: 12)  // a reflow: no address survives
  show(back: 0)
  #expect(!vp.hasSelection)
}

/// ⌘K, the alternate screen and a reset renumber the lines: a selection or
/// a mark from before never copies text from another screen.
@MainActor @Test func selectionGoesWhenTheScreenIsReplaced() throws {
  let host = Feed()
  let s = try Session(transport: host, rows: 3, cols: 8, history: 0)
  s.start()
  host.write("A\r\nB\r\nC")
  let vp = Viewport(session: s)
  func show() {
    vp.outputChanged()
    s.snapshot(into: &vp.screen, back: vp.scrollBack)
  }
  show()
  vp.selectLine(at: (0, 0))
  #expect(vp.selectedText() == "A")
  s.clear()
  show()
  #expect(!vp.hasSelection && vp.selectedText() == nil)
  vp.selectLine(at: (0, 0))
  #expect(vp.selectedText() == "C")
  host.write("\u{1B}[?1049h\u{1B}[HXYZ")
  show()
  #expect(!vp.hasSelection)
  vp.enterCopyMode()
  vp.selectLine(at: (0, 0))
  #expect(vp.selectedText() == "XYZ")
  host.write("\u{1B}[?1049l")
  show()
  #expect(!vp.hasSelection && vp.visibleMark() != nil)
  vp.exitCopyMode()
  // a scrollback that outlives its history is clamped
  let h = Feed()
  let s2 = try Session(transport: h, rows: 2, cols: 8, history: 4)
  s2.start()
  h.write("1\r\n2\r\n3\r\n4\r\n5")
  let vp2 = Viewport(session: s2)
  vp2.outputChanged()
  s2.snapshot(into: &vp2.screen)
  vp2.scroll(by: 3)
  #expect(vp2.scrollBack == 3 && vp2.topLine == 0)
  s2.clear()
  vp2.outputChanged()
  s2.snapshot(into: &vp2.screen)
  #expect(vp2.scrollBack == 0 && vp2.topLine == 0)
}

/// After output the search looks only at what can have changed, and gets
/// what a search of everything gets; past the limit it keeps the newest
/// matches, starts on the newest and says the count is partial.
@MainActor @Test func searchRefreshesIncrementallyAndKeepsTheNewest() throws {
  let host = Feed()
  let s = try Session(transport: host, rows: 4, cols: 12, history: 6)
  s.start()
  host.write("ab ab\r\nxx\r\nab\r\n")
  let vp = Viewport(session: s)
  func full() -> [Finder.Match] {
    s.findAll("ab", back: false, from: nil, limit: 1000).map {
      Finder.Match(line: $0.line, col: $0.col, end: $0.end)
    }
  }
  func show() {
    vp.outputChanged()
    s.snapshot(into: &vp.screen, back: vp.scrollBack)
  }
  show()
  vp.find()
  s.send("ab")
  #expect(vp.finder.matches == full() && vp.finder.matches.count == 3)
  #expect(vp.finder.match == Finder.Match(line: 2, col: 0, end: 1))
  vp.step(back: true)  // on the match in line 0, col 3
  host.write("ab\r\n\u{1B}[3Aab\u{1B}[3B")  // a new line, and "xx" on screen edited to "ab"
  show()
  #expect(vp.finder.matches == full() && vp.finder.matches.count == 5)
  #expect(vp.finder.match == Finder.Match(line: 0, col: 3, end: 4))  // still the same one
  for _ in 0..<8 {
    host.write("ab\r\n")  // the ring drops the oldest lines: matches move up or go
  }
  show()
  #expect(vp.finder.matches == full() && s.base() > 0)
  s.resize(rows: 4, cols: 20)  // renumbered: searched again from scratch
  show()
  #expect(vp.finder.matches == full())
  // more matches than the limit: the newest survive and the count says so
  let f = Finder()
  _ = f.key([UInt8(ascii: "a")])
  let big = Feed()
  let m2 = try Session(transport: big, rows: 24, cols: 80, history: 1000)
  m2.start()
  let line = String(repeating: "a", count: 60)
  big.write([String](repeating: line, count: 1023).joined(separator: "\r\n"))
  f.refresh(m2, restart: true)
  #expect(f.matches.count == Finder.limit && f.truncated)
  #expect(f.match == Finder.Match(line: 1022, col: 59, end: 59))
  big.write("\r\nbbb\r\nccc")  // the ring is full: the oldest line goes
  f.refresh(m2, restart: false)
  #expect(f.matches.count == Finder.limit && f.truncated)
  #expect(f.match == Finder.Match(line: 1021, col: 59, end: 59))  // the ring dropped one line
  #expect(f.matches.last == f.match)
}

/// A search already past the limit that gets a dense new line: the
/// incremental pass keeps the newest matches, the same ones a fresh search
/// of everything keeps.
@MainActor @Test func saturatedSearchStaysOnTheNewest() throws {
  let host = Feed()
  let s = try Session(transport: host, rows: 24, cols: 80, history: 1000)
  s.start()
  let line = String(repeating: "a", count: 60)
  host.write([String](repeating: line, count: 1023).joined(separator: "\r\n"))
  let f = Finder()
  _ = f.key([UInt8(ascii: "a")])
  f.refresh(s, restart: true)
  func fresh() -> [Finder.Match] {
    let g = Finder()
    _ = g.key([UInt8(ascii: "a")])
    g.refresh(s, restart: true)
    return g.matches
  }
  for _ in 0..<3 {
    host.write("\r\n" + line)
    f.refresh(s, restart: false)
    #expect(f.matches == fresh() && f.truncated)
    #expect(f.match?.col == 59 && f.matches.contains(f.match!))  // still the one it was on
  }
  host.write("\r\n" + [String](repeating: line, count: 200).joined(separator: "\r\n"))
  f.refresh(s, restart: false)  // the new region alone is past the limit
  #expect(f.matches == fresh() && f.matches.count == Finder.limit)
  host.write("\u{1B}[2J\u{1B}[H")  // the screen cleared: older matches come back up to the limit
  f.refresh(s, restart: false)
  #expect(f.matches == fresh() && f.matches.count == Finder.limit && f.truncated)
}

/// FOSFORO_BENCH=1 swift test -c release --filter ptyThroughput: a child
/// writing 200 MB through the pty into the terminal, end to end, no
/// rendering: what `cat bigfile` costs the reader thread and the core.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FOSFORO_BENCH"] == "1"))
func ptyThroughput() throws {
  for (name, script) in [
    ("yes", "yes | head -c 200000000"),
    ("seq", "seq 1 20000000"),
  ] {
    let s = try Session(
      executable: "/bin/sh", argv: ["sh", "-c", script],
      environment: ["PATH": "/bin:/usr/bin"], directory: nil, rows: 50, cols: 200, history: 1000)
    let t = Date()
    s.start()
    while !s.hasExited {
      Thread.sleep(forTimeInterval: 0.05)
    }
    let seconds = Date().timeIntervalSince(t)
    print("pty \(name): \(String(format: "%.2f", seconds)) s")  // bound by the child's writes
  }
}

/// A binary sent to the screen is thousands of BELs and OSC notices: the
/// session passes one bell per interval and one notice per interval, the
/// next notice saying how many went by; spaced ones all get through.
@Test func bellsAndNoticesAreRateLimited() throws {
  let host = Feed()
  let s = try Session(transport: host, rows: 2, cols: 10, history: 0)
  nonisolated(unsafe) var bells = 0
  nonisolated(unsafe) var notices: [String] = []
  s.onBell = { bells += 1 }
  s.onNotify = { notices.append($0) }
  s.start()
  host.write(String(repeating: "\u{07}", count: 10_000))
  #expect(bells == 1)
  Thread.sleep(forTimeInterval: Session.bellEvery + 0.05)
  host.write("\u{07}")
  #expect(bells == 2)
  for i in 0..<50 {
    host.write("\u{1B}]777;notify;t;n\(i)\u{07}")
  }
  #expect(notices == ["t: n0"])
  Thread.sleep(forTimeInterval: Session.noticeEvery + 0.05)
  host.write("\u{1B}]9;later\u{07}")
  #expect(notices == ["t: n0", "later (+49 more)"])
}

/// The core composes what it shows (c + U+0327 is one ç cell), so the
/// search composes what it looks for: either spelling finds either.
@Test func searchFindsAccentsInEitherNormalization() throws {
  let s = try Session(
    transport: Canned("ac\u{327}a\u{303}o cafe\u{301} Sa\u{303}o\r\n"), rows: 2, cols: 30,
    history: 0)
  s.start()
  for q in ["ação", "ac\u{327}a\u{303}o", "ação".decomposedStringWithCanonicalMapping] {
    let m = s.find(q, back: true, from: nil)
    #expect(m?.line == 0 && m?.col == 0 && m?.end == 3, "\(q)")
  }
  #expect(s.find("café", back: false, from: nil)?.col == 5)
  #expect(s.find("cafe\u{301}", back: false, from: nil)?.col == 5)
  #expect(s.findAll("São", back: false, from: nil, limit: 9).count == 1)
  #expect(s.findAll("Sa\u{303}o", back: true, from: nil, limit: 9).first?.col == 10)
  #expect(s.findAll("ç", back: false, from: nil, limit: 9).count == 1)
}

/// A double click picks the word under the pointer and nothing else: a
/// separator stays alone, both halves of a wide glyph select the same.
@MainActor @Test func wordSelectionRespectsBoundariesAndWideGlyphs() throws {
  let s = try Session(
    transport: Canned("foo|bar abc中def 日本 😀x\r\n"), rows: 2, cols: 40, history: 0)
  s.start()
  let vp = Viewport(session: s)
  s.snapshot(into: &vp.screen)
  vp.selectWord(at: (0, 3))
  #expect(vp.selectedText() == "|")
  vp.selectWord(at: (0, 1))
  #expect(vp.selectedText() == "foo")
  vp.selectWord(at: (0, 5))
  #expect(vp.selectedText() == "bar")
  vp.selectWord(at: (0, 11))  // 中, first half
  #expect(vp.selectedText() == "abc中def")
  vp.selectWord(at: (0, 12))  // second half
  #expect(vp.selectedText() == "abc中def")
  vp.selectWord(at: (0, 18))  // 日's tail
  #expect(vp.selectedText() == "日本")
  vp.selectWord(at: (0, 23))  // the emoji's tail; is no word: both its cells, and only them
  #expect(vp.selectedText() == "😀")
  vp.selectWord(at: (0, 7))
  #expect(vp.selectsOneCell)
}

/// The copy-mode mark treats a wide glyph as one cell: left onto its tail
/// lands on the head, right from the head passes it; Space on it selects
/// the glyph, and y copies it.
@MainActor @Test func copyMarkSkipsWideTails() throws {
  let host = Canned("中A")
  let s = try Session(transport: host, rows: 2, cols: 6, history: 0)
  s.start()
  let vp = Viewport(session: s)
  s.snapshot(into: &vp.screen)
  nonisolated(unsafe) var copied = ""
  vp.onCopy = { copied = $0 }
  vp.enterCopyMode()  // at the cursor, column 3
  s.send("h")
  #expect(vp.visibleMark()?.col == 2)
  s.send("h")
  #expect(vp.visibleMark()?.col == 0)  // the head, not the tail at 1
  s.send("l")
  #expect(vp.visibleMark()?.col == 2)  // past the glyph
  s.send("h")
  s.send("v")
  #expect(vp.selectedText() == "中")
  s.send("y")
  #expect(copied == "中" && !vp.copying)
}

/// ⌘F while in copy mode: the search takes the keys and the bar, the mark
/// goes; afterwards the shell gets the keys and nothing says COPY.
@MainActor @Test func searchEndsCopyMode() throws {
  let host = Canned("$ ")
  let s = try Session(transport: host, rows: 2, cols: 10, history: 0)
  s.start()
  let vp = Viewport(session: s)
  s.snapshot(into: &vp.screen)
  vp.enterCopyMode()
  #expect(vp.copying)
  vp.find()
  #expect(!vp.copying && vp.visibleMark() == nil && vp.finding && vp.finder.editing)
  s.send("x")
  #expect(vp.finder.text == "x" && host.sent.isEmpty)
  vp.apply(.close)
  s.send("y")
  #expect(host.sent == [UInt8(ascii: "y")] && !vp.copying)
  // and the other way round, as before: copy mode takes over from the field
  vp.find()
  vp.enterCopyMode()
  #expect(vp.copying && !vp.finder.editing)
  s.send([0x1B])
  #expect(!vp.copying && host.sent == [UInt8(ascii: "y")])
  // a click on the field, not ⌘F: the same as ⌘F
  vp.find()
  vp.enterCopyMode()
  vp.apply(.edit)
  #expect(!vp.copying && vp.visibleMark() == nil && vp.finder.editing)
  vp.apply(.close)
  s.send("z")
  #expect(host.sent == Array("yz".utf8) && !vp.copying)
  // the bar's close while in copy mode: the search goes, copy mode keeps the keys
  vp.find()
  vp.enterCopyMode()
  vp.apply(.close)
  #expect(vp.copying && !vp.finding)
  s.send("j")
  #expect(host.sent == Array("yz".utf8))  // a copy-mode key: moved the mark, never the shell's
  s.send([0x1B])
  #expect(!vp.copying && s.intercept == nil)
}

/// FOSFORO_BENCH=1 swift test -c release --filter searchCost: the cost of
/// a search over a deep history, the whole of it and then after one more
/// line of output, in the worst case (a query that almost matches
/// everywhere and never does).
@Test(.enabled(if: ProcessInfo.processInfo.environment["FOSFORO_BENCH"] == "1"))
func searchCost() throws {
  for history in [1000, 10000, 100_000] {
    let host = Feed()
    let s = try Session(transport: host, rows: 24, cols: 80, history: history)
    s.start()
    let line = String(repeating: "a", count: 79)
    for _ in 0..<(history / 100) {
      host.write([String](repeating: line, count: 100).joined(separator: "\r\n") + "\r\n")
    }
    let f = Finder()
    _ = f.key(Array((String(repeating: "a", count: 60) + "b").utf8))
    var t = Date()
    f.refresh(s, restart: true)
    let full = Date().timeIntervalSince(t)
    host.write("more\r\n")
    t = Date()
    f.refresh(s, restart: false)
    let more = Date().timeIntervalSince(t)
    print(
      "search \(history) lines: whole \(Int(full * 1000)) ms, after output \(Int(more * 1000)) ms")
  }
}

/// Focus reports (mode 1004) are for the program: they reach the host even
/// while the search or the copy mode take the keys.
@MainActor @Test func focusEventsBypassTheSearch() throws {
  let host = Canned("\u{1B}[?1004h$ ")
  let s = try Session(transport: host, rows: 2, cols: 10, history: 0)
  s.start()
  let vp = Viewport(session: s)
  s.snapshot(into: &vp.screen)
  vp.find()
  s.focus(false)
  s.focus(true)
  #expect(host.sent == Array("\u{1B}[O\u{1B}[I".utf8))
  #expect(vp.finder.text.isEmpty)
  vp.apply(.close)
  vp.enterCopyMode()
  let before = vp.visibleMark()
  s.focus(false)
  #expect(host.sent == Array("\u{1B}[O\u{1B}[I\u{1B}[O".utf8))
  #expect(vp.visibleMark()?.row == before?.row && vp.visibleMark()?.col == before?.col)
  vp.exitCopyMode()
}

@Test func keysAreEncodedForTheCurrentModes() throws {
  let s = try shell(
    "stty -echo -icanon min 1; printf '\\033[?1h'; x=$(dd bs=3 count=1 2>/dev/null); printf '%s' \"${x#?}\""
  )
  #expect(eventually { s.generation() > 0 })
  Thread.sleep(forTimeInterval: 0.2)
  s.input { t, out in vt_key(t, Int32(VT_KEY_UP), 0, out) }
  #expect(eventually { s.hasExited })
  var screen = Screen()
  s.snapshot(into: &screen)
  #expect(text(screen, row: 0) == "OA")
}

@Test func loginShellIsDashed() {
  let (path, argv) = Shell.login()
  #expect(path.hasPrefix("/"))
  #expect(argv.count == 1 && argv[0].hasPrefix("-"))
  let env = Shell.environment(base: [:])
  #expect(env["TERM"] == "xterm-256color")
  #expect(env["LANG"]?.hasSuffix(".UTF-8") == true)
}

@Test func hangupEndsTheChild() throws {
  let s = try shell("sleep 30")
  s.hangup()
  #expect(eventually { s.hasExited })
}

@Test func composingTextIsDrawnAtTheCursor() throws {
  let term = try Terminal(rows: 2, cols: 8, history: 0)
  term.write("$ ")
  var screen = Screen()
  term.snapshot(into: &screen)
  screen.compose("a\u{301}日本")  // the combining accent takes no cell
  #expect(screen.cell(0, 2).cp == 0x61)
  #expect(screen.cell(0, 3).cp == 0x65E5)
  #expect(screen.cell(0, 3).flags == UInt8(VT_CELL_WIDE))
  #expect(screen.cell(0, 4).flags == UInt8(VT_CELL_WIDE_TAIL))
  #expect(screen.cell(0, 5).cp == 0x672C)
  #expect(screen.cell(0, 2).attr & UInt16(VT_ATTR_UL_MASK) != 0)
  #expect(screen.cursor.col == 7)
  screen.compose("日本語")  // from col 7 nothing wide fits: cut, not wrapped
  #expect(screen.cell(1, 0).cp == 0)
}

/// Plays back fixed output, as a remote host would send it.
private final class Canned: Transport, @unchecked Sendable {
  let bytes: [UInt8]
  var sent: [UInt8] = []
  init(_ text: String) { bytes = Array(text.utf8) }
  func start(
    output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void
  ) {
    output(bytes)
  }
  func send(_ bytes: [UInt8]) { sent += bytes }
  func resize(rows: Int, cols: Int) {}
  func hangup() {}
}

@Test func onlyWebAndMailLinksOpen() throws {
  let links = [
    "https://example.com/", "mailto:a@b.c", "file:///Applications/Calculator.app", "x-app:run",
  ]
  let text = links.map { "\u{1b}]8;;\($0)\u{7}L\u{1b}]8;;\u{7}" }.joined()
  let s = try Session(transport: Canned(text), rows: 2, cols: 10, history: 0)
  s.start()
  var screen = Screen()
  s.snapshot(into: &screen)
  #expect(s.link(screen.cell(0, 0).link)?.absoluteString == links[0])
  #expect(s.link(screen.cell(0, 1).link)?.absoluteString == links[1])
  #expect(s.link(screen.cell(0, 2).link) == nil)
  #expect(s.link(screen.cell(0, 3).link) == nil)
  #expect(screen.cell(0, 2).link != 0)  // still a link, just not one we open
}

private func rowText(_ row: [vt_cell]) -> String {
  String(
    String.UnicodeScalarView(
      row.filter { UInt32($0.flags) & UInt32(VT_CELL_WIDE_TAIL) == 0 }.map {
        Unicode.Scalar($0.cp == 0 ? 32 : $0.cp)!
      }))
}

@Test func statusLineCutsTheLeftToKeepTheRight() {
  let left = [StatusLine.Piece("~/Projects/demos", color: StatusLine.color(13))]
  let right = [StatusLine.Piece("2/3", color: StatusLine.color(14))]
  #expect(
    rowText(StatusLine.cells(left: left, right: right, cols: 24)) == "~/Projects/demos     2/3")
  #expect(rowText(StatusLine.cells(left: left, right: right, cols: 10)) == "~/Proj 2/3")
  let wide = StatusLine.cells(left: [StatusLine.Piece("日本", color: 0)], right: [], cols: 5)
  #expect(wide[0].flags == UInt8(VT_CELL_WIDE) && wide[1].flags == UInt8(VT_CELL_WIDE_TAIL))
  #expect(StatusLine.cells(left: left, right: right, cols: 24)[0].fg == StatusLine.color(13))
}

@Test func gitBranchIsReadWithoutGit() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: root) }
  let sub = root.appendingPathComponent("repo/a/b")
  try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
  let git = root.appendingPathComponent("repo/.git")
  try FileManager.default.createDirectory(at: git, withIntermediateDirectories: true)
  try "ref: refs/heads/trunk\n".write(
    to: git.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
  #expect(GitBranch.at(sub.path) == "trunk")
  // a worktree: .git is a file naming the real directory
  let wt = root.appendingPathComponent("wt")
  let wtGit = git.appendingPathComponent("worktrees/wt")
  try FileManager.default.createDirectory(at: wt, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: wtGit, withIntermediateDirectories: true)
  try "gitdir: \(wtGit.path)\n".write(
    to: wt.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
  try "adf99f3d0c1e2b3a4f5e6d7c8b9a0f1e2d3c4b5a\n".write(
    to: wtGit.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
  #expect(GitBranch.at(wt.path) == "adf99f3")  // detached
  #expect(GitBranch.at(root.path) == nil)

  // the push mark: no upstream, or a different commit there
  let a = "1111111111111111111111111111111111111111"
  let b = "2222222222222222222222222222222222222222"
  try FileManager.default.createDirectory(
    at: git.appendingPathComponent("refs/remotes/origin"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: git.appendingPathComponent("refs/heads"), withIntermediateDirectories: true)
  try (a + "\n").write(
    to: git.appendingPathComponent("refs/heads/trunk"), atomically: true, encoding: .utf8)
  #expect(GitBranch.status(sub.path)?.unpushed == true)  // no upstream in config
  try "[branch \"trunk\"]\n\tremote = origin\n\tmerge = refs/heads/trunk\n".write(
    to: git.appendingPathComponent("config"), atomically: true, encoding: .utf8)
  #expect(GitBranch.status(sub.path)?.unpushed == true)  // never pushed
  try (b + "\n").write(
    to: git.appendingPathComponent("refs/remotes/origin/trunk"), atomically: true, encoding: .utf8)
  #expect(GitBranch.status(sub.path)?.unpushed == true)  // the remote is elsewhere
  #expect(GitBranch.status(sub.path)?.tips == a + " " + b)  // what the counts depend on
  try FileManager.default.removeItem(at: git.appendingPathComponent("refs/remotes/origin/trunk"))
  try "# pack-refs with: peeled\n\(a) refs/remotes/origin/trunk\n".write(
    to: git.appendingPathComponent("packed-refs"), atomically: true, encoding: .utf8)
  #expect(GitBranch.status(sub.path)?.unpushed == false)  // the same commit, packed
}

@Test func localHostNames() {
  #expect(Session.isLocal(""))
  #expect(Session.isLocal("localhost"))
  #expect(!Session.isLocal("some-remote-host.example"))
}

@Test func statusFollowsTheForegroundProcessThenOSC7() throws {
  // exec: without job control a child shares the shell's process group
  let s = try shell("cd /usr/bin && exec sleep 2")
  var st = s.status()
  #expect(
    eventually {
      st = s.status()
      return st.directory == "/usr/bin" && st.title == "sleep"
    }, "\(st)")
  #expect(st.local)
  let t = try shell("printf '\\033]7;file://elsewhere.example/srv/app\\a'; sleep 2")
  #expect(eventually { t.status().directory == "/srv/app" })
  #expect(!t.status().local)
}

@Test func finderTakesTheKeysAndWalksTheMatches() throws {
  let host = Canned("\u{1B}[?2004hone foo\r\ntwo\r\nfoo foo\r\n")  // bracketed paste on
  let s = try Session(transport: host, rows: 4, cols: 10, history: 10)
  s.start()
  let f = Finder()
  var got: [[UInt8]] = []
  s.intercept = { bytes in
    got.append(bytes)
    _ = f.key(bytes)
  }
  s.send("fop")
  s.send([0x7F])
  s.send("o")
  #expect(f.text == "foo")
  #expect(got.count == 3)
  f.refresh(s, restart: true)
  #expect(f.matches.count == 3)
  #expect(f.match == Finder.Match(line: 2, col: 4, end: 6))  // the newest first
  f.step(back: true)
  #expect(f.match?.col == 0 && f.match?.line == 2)
  f.step(back: true)
  #expect(f.match?.line == 0)
  f.step(back: true)  // wraps around
  #expect(f.match == Finder.Match(line: 2, col: 4, end: 6))
  #expect(f.key([0x1B, 0x5B, 0x42]) == .newer)
  #expect(f.key([0x1B, 0x5B, 0x41]) == .older)
  #expect(f.key([0x1B]) == .close)
  #expect(f.key([0x1B, 0x5B, 0x3C, 0x30]) == .none)  // a mouse report
  // a paste lands in the search as text, not as the host's bracketed packet
  s.paste(" bar")
  #expect(f.text == "foo bar")
  #expect(host.sent.isEmpty)
  s.intercept = nil
  s.paste("x")
  #expect(host.sent == Array("\u{1B}[200~x\u{1B}[201~".utf8))
}

/// OSC 133;A is a mark for ⌘↑ and the on-prompt event; the other subcommands
/// are neither.
@Test func promptMarksReachTheSession() throws {
  let s = try Session(
    transport: Canned("\u{1B}]133;A\u{07}$ ls\r\u{1B}]133;C\u{07}\nout\r\n\u{1B}]133;A\u{1B}\\$ "),
    rows: 6, cols: 20, history: 10)
  nonisolated(unsafe) var prompts = 0
  s.onPrompt = { prompts += 1 }
  s.start()
  #expect(prompts == 2)
  #expect(s.prompt(from: s.lines(), back: true) != nil)
}

/// Option with an arrow or Backspace works by the word, as in Terminal.app
/// (OptionArrows "word"); any other key composes as usual.
@Test func optionArrowsMoveByTheWord() {
  #expect(Keys.optionWord(Int32(VT_KEY_LEFT)) == [0x1B, 0x62])
  #expect(Keys.optionWord(Int32(VT_KEY_RIGHT)) == [0x1B, 0x66])
  #expect(Keys.optionWord(Int32(VT_KEY_BACKSPACE)) == [0x1B, 0x7F])
  #expect(Keys.optionWord(Int32(VT_KEY_UP)) == nil)
  #expect(Keys.optionWord(Int32(VT_KEY_DELETE)) == nil)
}

/// LANG is a locale the system has: macOS names one it has no files for
/// (en_BR), and perl and Python choke on it; the fallback goes through the
/// preferred languages to en_US.
@Test func langIsAnInstalledLocale() {
  let have: Set<String> = ["pt_BR.UTF-8", "en_US.UTF-8", "de_DE.UTF-8"]
  #expect(
    Shell.lang(locale: "en_BR", preferred: ["en-BR", "pt-BR"]) { have.contains($0) }
      == "pt_BR.UTF-8")
  #expect(Shell.lang(locale: "pt_BR", preferred: ["pt-BR"]) { have.contains($0) } == "pt_BR.UTF-8")
  #expect(
    Shell.lang(locale: "de_DE@rg=brzzzz", preferred: []) { have.contains($0) } == "de_DE.UTF-8")
  #expect(Shell.lang(locale: "xx_YY", preferred: ["zz"]) { have.contains($0) } == "en_US.UTF-8")
  #expect(Shell.lang(locale: "xx_YY", preferred: []) { _ in false } == "en_US.UTF-8")
  let real = Shell.lang()
  #expect(FileManager.default.fileExists(atPath: "/usr/share/locale/\(real)"), "\(real)")
  #expect(Shell.environment(base: [:])["LANG"] == real)
  #expect(Shell.environment(base: ["LC_ALL": "C"])["LANG"] == nil)
}

/// Output that lands between the search refresh and the snapshot is not
/// passed off as seen: the next frame refreshes it.
@MainActor @Test func outputBetweenRefreshAndSnapshotIsSeenNextFrame() throws {
  let host = Feed()
  let s = try Session(transport: host, rows: 2, cols: 10, history: 1000)
  s.start()
  host.write("hit")
  let vp = Viewport(session: s)
  vp.beforeFrame()
  s.snapshot(into: &vp.screen)
  vp.find()
  s.send("hit")
  #expect(vp.finder.matches.count == 1)
  vp.beforeFrame()  // the frame's refresh: nothing new
  host.write("\r\nhit")  // ...and output right after it, before the snapshot
  s.snapshot(into: &vp.screen)
  #expect(vp.finder.matches.count == 1)
  vp.beforeFrame()  // next frame: the generation moved since the refresh
  #expect(vp.finder.matches.count == 2)
  vp.beforeFrame()
  #expect(vp.finder.matches.count == 2)
}

@Test func shellQuotesPathsAndKnowsItself() {
  #expect(Shell.quoted("/Users/me/Projects") == "/Users/me/Projects")
  #expect(Shell.quoted("/tmp/a b") == "'/tmp/a b'")
  #expect(Shell.quoted("/tmp/it's") == "'/tmp/it'\\''s'")
  #expect(Shell.isShell("-zsh") && Shell.isShell("/bin/bash") && !Shell.isShell("vim"))
  #expect(Session.notice(9, Array("done".utf8)) == "done")
  #expect(Session.notice(777, Array("notify;build;ok".utf8)) == "build: ok")
  #expect(Session.notice(777, Array("x;y".utf8)) == nil)
}

/// The viewport, shared by the Mac and iOS views: a word and a line under a
/// point, the search selecting its match, the keyboard given back to the
/// host while the matches stay.
@MainActor @Test func viewportSelectsAndSearches() throws {
  let s = try Session(
    transport: Canned("foo bar-baz\r\nqux foo\r\n"), rows: 3, cols: 20, history: 0)
  s.start()
  let vp = Viewport(session: s)
  s.snapshot(into: &vp.screen)
  vp.selectWord(at: (0, 5))
  #expect(vp.selectedText() == "bar-baz")
  vp.selectLine(at: (1, 3))
  #expect(vp.selectedText() == "qux foo")
  vp.anchorSelection(at: (0, 0))
  #expect(vp.selectsOneCell)
  vp.extendSelection(to: (0, 2))
  #expect(vp.selectedText() == "foo" && !vp.selectsOneCell)
  vp.clearSelection()
  #expect(!vp.hasSelection && vp.visibleSelection() == nil)

  vp.find()
  #expect(vp.finding && vp.finder.editing && s.intercept != nil)
  s.send("foo")  // typed into the field, not to the host
  #expect(vp.finder.text == "foo" && vp.finder.matches.count == 2)
  #expect(vp.selectedText() == "foo" && vp.visibleMatches().count == 2)
  s.send([0x0D])  // Return: the host has the keyboard again
  #expect(!vp.finder.editing && s.intercept == nil && vp.finding)
  #expect(vp.visibleMatches().count == 2)
  vp.apply(.close)
  #expect(!vp.finding && vp.visibleMatches().isEmpty)
}

@MainActor @Test func tripleClickTakesTheWholeWrappedLine() throws {
  let s = try Session(
    transport: Canned("abcdefghijklmnopqrstuvwxyz\r\nshort"), rows: 4, cols: 10, history: 0)
  s.start()
  let vp = Viewport(session: s)
  s.snapshot(into: &vp.screen)
  vp.selectLine(at: (1, 3))  // the middle row of a line wrapped over three
  #expect(vp.selectedText() == "abcdefghijklmnopqrstuvwxyz", "\(vp.selectedText() ?? "nil")")
  vp.selectLine(at: (0, 9))
  #expect(vp.selectedText() == "abcdefghijklmnopqrstuvwxyz")
  vp.selectLine(at: (3, 0))
  #expect(vp.selectedText() == "short")
}

/// n/N on the left, the title on the right, the band under everything: a
/// title like the prompt ("user@host: ~") cannot be taken for one.
@Test func statusBarKeepsTheTitleApartFromThePrompt() throws {
  let s = try Session(
    transport: Canned("\u{1b}]2;user@host: ~\u{7}"), rows: 2, cols: 40, history: 0)
  s.start()
  let band = StatusLine.rgb(0x1C1C1C)
  let row = StatusBar().cells(s, position: (1, 2), cols: 40, rows: 2, background: band)
  let text = rowText(row)
  #expect(text.hasPrefix(" 1/2"))
  #expect(text.hasSuffix("40×2 │ user@host: ~ "))
  #expect(row.allSatisfy { $0.bg == band })
}

@Test func statusBarButtonsAnswerWhereTheyAre() throws {
  let s = try Session(transport: Canned("foo foo"), rows: 2, cols: 40, history: 0)
  s.start()
  let f = Finder()
  _ = f.key(Array("foo".utf8))
  f.refresh(s, restart: true)
  let bar = StatusBar()
  let row = bar.cells(s, position: (1, 2), cols: 40, finder: f)
  let text = String(String.UnicodeScalarView(row.map { Unicode.Scalar($0.cp == 0 ? 32 : $0.cp)! }))
  let older = text.distance(from: text.startIndex, to: text.firstIndex(of: "‹")!)
  let newer = text.distance(from: text.startIndex, to: text.firstIndex(of: "›")!)
  let close = text.distance(from: text.startIndex, to: text.firstIndex(of: "×")!)
  #expect(text.contains("2/2"))
  #expect(bar.action(at: older) == .older && bar.action(at: older - 1) == .older)  // padded
  #expect(bar.action(at: newer) == .newer)
  #expect(bar.action(at: close) == .close)
  #expect(bar.action(at: 2) == .edit)  // the field itself: the keyboard comes back to it
  #expect(f.key([0x0D]) == .leave)  // Return hands the keyboard to the host
  f.editing = false
  let idle = bar.cells(s, position: (1, 2), cols: 40)
  #expect(!rowText(idle).contains("foo_"))  // no caret while the host has the keyboard
  _ = bar.cells(s, position: (1, 2), cols: 40)
  #expect(bar.action(at: older) == .none)  // no buttons outside the search
}

/// OSC 52 (vim's "+y over ssh) hands its text to the clipboard; the "?"
/// query, which would read the clipboard, is never answered.
/// The config's Clipboard key: "deny" keeps OSC 52 out; and when a program
/// does set it, the bar says so for a while.
@Test func clipboardCanBeDeniedAndIsAnnounced() throws {
  let host = Feed()
  let s = try Session(transport: host, rows: 2, cols: 40, history: 0)
  nonisolated(unsafe) var got: [String] = []
  s.onClipboard = { got.append($0) }
  s.start()
  let osc = "\u{1B}]52;c;\(Data("hi".utf8).base64EncodedString())\u{07}"
  s.clipboardAllowed = false
  host.write(osc)
  #expect(got.isEmpty)
  s.clipboardAllowed = true
  host.write(osc)
  #expect(got == ["hi"])
  let bar = StatusBar()
  let cells = bar.cells(s, position: (1, 1), cols: 40, rows: 2, notice: "clipboard ← program")
  #expect(rowText(cells).contains("clipboard ← program │ 40×2"))
  #expect(!rowText(bar.cells(s, position: (1, 1), cols: 40, rows: 2)).contains("clipboard"))
}

@Test func osc52GivesTextButNeverReads() throws {
  final class Got: @unchecked Sendable {
    let lock = NSLock()
    var texts: [String] = []
  }
  let got = Got()
  let s = try Session(
    executable: "/bin/sh",
    argv: ["sh", "-c", "printf '\\033]52;c;?\\007\\033]52;c;b2zDoSBkbyBudmlt\\007'; sleep 1"],
    environment: ["PATH": "/bin:/usr/bin"], directory: nil, rows: 5, cols: 30, history: 10)
  s.onClipboard = { t in
    got.lock.lock()
    got.texts.append(t)
    got.lock.unlock()
  }
  s.start()
  #expect(
    eventually {
      got.lock.lock()
      defer { got.lock.unlock() }
      return !got.texts.isEmpty
    })
  got.lock.lock()
  #expect(got.texts == ["olá do nvim"])
  got.lock.unlock()
}

/// Copy mode: the keys move a mark and never reach the host; v anchors,
/// the mark drags the selection, y hands the text over and leaves.
@MainActor @Test func copyModeSelectsWithTheKeyboard() throws {
  let s = try Session(transport: Canned("alpha beta\r\ngamma\r\n"), rows: 3, cols: 12, history: 0)
  s.start()
  let vp = Viewport(session: s)
  s.snapshot(into: &vp.screen)
  var copied = ""
  vp.onCopy = { copied = $0 }
  vp.enterCopyMode()
  #expect(vp.copying && s.intercept != nil && vp.visibleMark()?.row == 2)
  s.send([0x1B, 0x5B, 0x41])  // up: on "gamma"
  s.send("0")
  #expect(vp.visibleMark()! == (1, 0))
  s.send("v")
  s.send("$")
  #expect(vp.selectedText() == "gamma")
  s.send("0")
  s.send([0x1B, 0x5B, 0x31, 0x3B, 0x32, 0x41])  // shift+up: the line above joins
  #expect(vp.selectedText()?.hasPrefix("alpha") == true)
  s.send([0x0D])  // Return is no key here
  #expect(vp.copying)
  s.send("y")
  #expect(!vp.copying && s.intercept == nil && copied.hasPrefix("alpha"))
}

/// As in iTerm2: output that rewrites or scrolls the screen under the
/// selection takes it away (Enter, clear); output elsewhere on the screen,
/// or a selection that lies all in the history, leaves it.
@MainActor @Test func selectionGoesWhenOutputTouchesIt() throws {
  let host = Feed()
  let s = try Session(transport: host, rows: 3, cols: 8, history: 10)
  s.start()
  host.write("A\r\nB\r\nC")
  let vp = Viewport(session: s)
  func show() {
    vp.outputChanged()
    s.snapshot(into: &vp.screen, back: vp.scrollBack)
  }
  show()
  vp.selectLine(at: (0, 0))
  host.write("\u{1B}[3;2Hz")  // C becomes Cz: not under it
  show()
  #expect(vp.selectedText() == "A")
  host.write("\r\n")  // Enter scrolls it up
  show()
  #expect(!vp.hasSelection)
  vp.selectLine(at: (1, 0))
  host.write("\u{1B}[H\u{1B}[2J")  // clear
  show()
  #expect(!vp.hasSelection)
  host.write("1\r\n2\r\n3\r\n4\r\n5")
  vp.scrollBack = 2
  show()
  vp.selectLine(at: (0, 0))  // in the history
  host.write("\r\n6")
  show()
  #expect(vp.selectedText() == "1")
}
