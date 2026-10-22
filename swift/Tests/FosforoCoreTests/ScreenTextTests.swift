import CFosforo
import FosforoCore
import Testing

private let wideHead = UInt8(VT_CELL_WIDE)
private let wideTail = UInt8(VT_CELL_WIDE_TAIL)

private func cell(_ cp: UInt32, _ flags: UInt8 = 0) -> vt_cell {
  var c = vt_cell()
  c.cp = cp
  c.flags = flags
  return c
}

private func screen(_ rows: [[vt_cell]]) -> Screen {
  var s = Screen()
  s.rows = rows.count
  s.cols = rows.first?.count ?? 0
  s.cells = rows.flatMap { $0 }
  return s
}

private func row(_ text: String) -> [vt_cell] {
  text.unicodeScalars.map { cell($0 == " " ? 0 : $0.value) }
}

@Test func screenTextIsALinePerRow() {
  #expect(screen([row("abc"), row("def")]).text == "abc\ndef")
}

@Test func screenTextDropsTrailingBlanksOnly() {
  #expect(screen([row(" a b  "), row("c     ")]).text == " a b\nc")
  #expect(screen([[cell(0x61), cell(0x20), cell(0)]]).text == "a")
}

@Test func anEmptyRowIsAnEmptyLine() {
  #expect(screen([row("ab"), row("  "), row("cd")]).text == "ab\n\ncd")
  #expect(screen([row("  "), row("  ")]).text == "\n")
}

@Test func aWideGlyphCountsOnceAndItsTailIsSkipped() {
  let wide = [cell(0x4E2D, wideHead), cell(0, wideTail), cell(0x78)]
  #expect(screen([wide]).text == "中x")
  let tailWithText = [cell(0x4E2D, wideHead), cell(0x79, wideTail), cell(0x78)]
  #expect(screen([tailWithText]).text == "中x")
}

@Test func aZeroSizeScreenHasNoText() {
  #expect(Screen().text == "")
  var noCols = Screen()
  noCols.rows = 3
  #expect(noCols.text == "")
}
