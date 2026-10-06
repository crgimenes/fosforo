import CFosforo
import FosforoCore
import Foundation
import Testing

@testable import FosforoMosh

private func blank(_ rows: Int = 2, _ cols: Int = 10) -> Screen {
  var s = Screen()
  s.rows = rows
  s.cols = cols
  s.cells = [vt_cell](repeating: vt_cell(), count: rows * cols)
  return s
}

private func text(_ s: Screen, row: Int = 0) -> String {
  let line = s.cells[(row * s.cols)..<((row + 1) * s.cols)]
  return String(String.UnicodeScalarView(line.map { Unicode.Scalar($0.cp == 0 ? 32 : $0.cp)! }))
}

private func shown(_ p: Predictor) -> Screen {
  var s = blank()
  p.overlay(&s)
  return s
}

@Test func predictionsWaitForAConfirmation() {
  var p = Predictor()
  p.mode = .always
  let now = Date()
  p.typed(Array("a".utf8), index: 1, echoed: 0, real: (0, 2), cols: 10, now: now)
  #expect(text(shown(p)) == "          ")  // a fresh epoch is tentative
  p.check(echoed: 1, cell: { _, c in c == 2 ? 0x61 : 0 }, real: (0, 3))
  #expect(!p.pending)
  p.typed(Array("bc".utf8), index: 2, echoed: 1, real: (0, 3), cols: 10, now: now)
  let s = shown(p)
  #expect(text(s) == "   bc     ")
  #expect(s.cursor.col == 5)
  p.check(echoed: 2, cell: { _, c in c == 3 ? 0x62 : c == 4 ? 0x63 : 0 }, real: (0, 5))
  #expect(!p.pending)
}

@Test func aWrongGuessDropsEverything() {
  var p = Predictor()
  p.mode = .always
  let now = Date()
  p.typed(Array("a".utf8), index: 1, echoed: 0, real: (0, 0), cols: 10, now: now)
  p.check(echoed: 1, cell: { _, c in c == 0 ? 0x61 : 0 }, real: (0, 1))
  p.typed(Array("b".utf8), index: 2, echoed: 1, real: (0, 1), cols: 10, now: now)
  p.typed(Array("c".utf8), index: 3, echoed: 1, real: (0, 1), cols: 10, now: now)
  #expect(text(shown(p)) == " bc       ")
  p.check(echoed: 2, cell: { _, _ in 0 }, real: (0, 1))  // "b" never came back
  #expect(!p.pending)
  #expect(text(shown(p)) == "          ")
  // until the server has echoed everything typed so far, nothing is guessed
  p.typed(Array("d".utf8), index: 4, echoed: 2, real: (0, 1), cols: 10, now: now)
  #expect(!p.pending)
}

@Test func afterReturnNothingShowsUntilConfirmed() {
  var p = Predictor()
  p.mode = .always
  let now = Date()
  p.typed(Array("a".utf8), index: 1, echoed: 0, real: (0, 0), cols: 10, now: now)
  p.check(echoed: 1, cell: { _, c in c == 0 ? 0x61 : 0 }, real: (0, 1))
  p.typed([0x0D], index: 2, echoed: 1, real: (0, 1), cols: 10, now: now)
  // a password prompt: the keys are typed, the server echoes nothing
  p.typed(Array("s".utf8), index: 3, echoed: 2, real: (1, 0), cols: 10, now: now)
  p.typed(Array("e".utf8), index: 4, echoed: 2, real: (1, 0), cols: 10, now: now)
  #expect(p.pending)
  #expect(text(shown(p), row: 1) == "          ")
  p.check(echoed: 4, cell: { _, _ in 0 }, real: (1, 0))
  #expect(!p.pending)
  #expect(text(shown(p), row: 1) == "          ")
}

@Test func adaptiveModeFollowsTheRoundTrip() {
  var p = Predictor()
  let now = Date()
  p.typed(Array("a".utf8), index: 1, echoed: 0, real: (0, 0), cols: 10, now: now)
  p.check(echoed: 1, cell: { _, c in c == 0 ? 0x61 : 0 }, real: (0, 1))
  p.typed(Array("b".utf8), index: 2, echoed: 1, real: (0, 1), cols: 10, now: now)
  p.rtt(0.005)
  #expect(text(shown(p)) == "          ")  // a fast link: the echo beats any guess
  for _ in 0..<40 { p.rtt(0.2) }
  let s = shown(p)
  #expect(text(s) == " b        ")
  #expect(s.cells[1].attr & UInt16(VT_ATTR_UL_MASK) != 0)  // slow enough to flag
  for _ in 0..<40 { p.rtt(0.001) }
  #expect(text(shown(p)) == "          ")
}

@Test func backspaceAndArrowsMoveTheGuess() {
  var p = Predictor()
  p.mode = .always
  let now = Date()
  p.typed(Array("a".utf8), index: 1, echoed: 0, real: (0, 0), cols: 10, now: now)
  p.check(echoed: 1, cell: { _, c in c == 0 ? 0x61 : 0 }, real: (0, 1))
  p.typed(Array("xy".utf8), index: 2, echoed: 1, real: (0, 1), cols: 10, now: now)
  p.typed([0x7F], index: 3, echoed: 1, real: (0, 1), cols: 10, now: now)
  p.typed([0x1B, 0x5B, 0x44], index: 4, echoed: 1, real: (0, 1), cols: 10, now: now)
  let s = shown(p)
  #expect(text(s) == " x        ")
  #expect(s.cursor.col == 1)
}
