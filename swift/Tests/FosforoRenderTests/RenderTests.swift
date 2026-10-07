import CFosforo
import CoreText
import FosforoCore
import Metal
import Testing

@testable import FosforoRender

/// A frame the GPU has not drawn yet keeps its glyphs when the next frame
/// resets the atlas: frame A is held back by an event while frame B is
/// encoded over a reset atlas; released, A still shows A. Menlo 200 pt at 3x
/// leaves the atlas ten slots, so every frame resets it.
@Test func pendingFrameSurvivesAnAtlasReset() throws {
  var theme = Theme()
  theme.fontName = "Menlo-Regular"
  theme.fontSize = 200
  let r = try Renderer(theme: theme, scale: 3)
  let w = 2 * r.metrics.width
  let h = r.metrics.height
  func screen(_ text: String) throws -> Screen {
    let term = try Terminal(rows: 1, cols: 2, history: 0)
    theme.apply { term.configure(color: $0, rgb: $1) }
    term.write(text)
    var s = Screen()
    term.snapshot(into: &s)
    return s
  }
  func target() throws -> MTLTexture {
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
    d.usage = [.renderTarget, .shaderRead]
    d.storageMode = .shared
    guard let t = r.device.makeTexture(descriptor: d) else { throw RenderError(description: "t") }
    return t
  }
  func bytes(_ t: MTLTexture) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: w * h * 4)
    t.getBytes(&out, bytesPerRow: w * 4, from: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0)
    return out
  }
  let alone = try r.pixels(try screen("ab"), width: w, height: h, cursorVisible: false)
  guard let event = r.device.makeSharedEvent(), let cbA = r.makeCommandBuffer(),
    let cbB = r.makeCommandBuffer()
  else {
    throw RenderError(description: "event")
  }
  let a = try target()
  let b = try target()
  cbA.encodeWaitForEvent(event, value: 1)  // the GPU holds A until told
  r.encode(try screen("ab"), into: a, commandBuffer: cbA, cursorVisible: false)
  cbA.commit()
  r.encode(try screen("cd"), into: b, commandBuffer: cbB, cursorVisible: false)  // resets the atlas
  cbB.commit()
  event.signaledValue = 1
  cbA.waitUntilCompleted()
  cbB.waitUntilCompleted()
  #expect(bytes(a) == alone)
  #expect(bytes(b) != alone)
}

/// A frame with more distinct glyphs than the atlas holds (a big font, a
/// dense screen): every slot stays inside the texture and no two glyphs get
/// the same one; the surplus is blank until the next frame starts afresh.
/// Menlo 80 pt at 3x makes 144x280 cells: 14 per row, 7 rows, 98 slots.
/// A wide glyph that found no room in the atlas draws nothing at all, in
/// both of its cells and in the next frame too (slots 0 and 1 stay blank
/// for it); its neighbours keep their ink.
@Test func wideGlyphWithoutRoomIsBlank() throws {
  var theme = Theme()
  theme.fontName = "Menlo-Regular"
  theme.fontSize = 80  // 144x280 cells at 3x: 98 slots
  theme.background = 0x000000
  let r = try Renderer(theme: theme, scale: 3)
  let rows = 6
  let cols = 20
  let term = try Terminal(rows: rows, cols: cols, history: 0)
  theme.apply { term.configure(color: $0, rgb: $1) }
  var text = ""
  for cp in UInt32(0x21)...0x7E {
    text.unicodeScalars.append(Unicode.Scalar(cp)!)
  }
  term.write(text + "\u{1B}[1m¡¢中")  // bold: a style the atlas has not seen
  var screen = Screen()
  term.snapshot(into: &screen)
  let w = r.metrics.width
  let h = r.metrics.height
  func ink(_ px: [UInt8], row: Int, col: Int, cells: Int) -> Int {
    var n = 0
    for y in row * h..<(row + 1) * h {
      for x in col * w..<(col + cells) * w {
        let i = (y * cols * w + x) * 4
        if px[i] != 0 || px[i + 1] != 0 || px[i + 2] != 0 {
          n += 1
        }
      }
    }
    return n
  }
  for _ in 0..<2 {
    let px = try r.pixels(screen, width: cols * w, height: rows * h, cursorVisible: false)
    #expect(ink(px, row: 0, col: 0, cells: 1) > 0)  // "!"
    #expect(ink(px, row: 4, col: 15, cells: 1) > 0)  // "¢"
    #expect(ink(px, row: 4, col: 16, cells: 2) == 0)  // 中, no room: both halves blank
  }
}

@Test func atlasNeverWritesPastItsTexture() throws {
  guard let device = MTLCreateSystemDefaultDevice() else { return }
  let font = CTFontCreateWithName("Menlo-Regular" as CFString, 80, nil)
  let atlas = try Atlas(device: device, font: font, scale: 3)
  let w = atlas.metrics.width
  let h = atlas.metrics.height
  var taken: Set<SIMD2<UInt16>> = []
  var blank = 0
  func use(_ cp: UInt32, wide: Bool) {
    let g = atlas.glyph(cp, style: .regular, wide: wide)
    if g.slot == .zero {
      blank += 1
      return
    }
    #expect((Int(g.slot.x) + (wide ? 2 : 1)) * w <= Atlas.size, "\(cp) x")
    #expect((Int(g.slot.y) + 1) * h <= Atlas.size, "\(cp) y")
    #expect(taken.insert(g.slot).inserted, "\(cp) shares a slot")
    if wide {
      #expect(taken.insert(g.slot &+ SIMD2(1, 0)).inserted, "\(cp) tail shares a slot")
    }
  }
  for cp in UInt32(0x21)...0x7E {
    use(cp, wide: false)
  }
  for cp in [UInt32(0xA1), 0xA2] {
    use(cp, wide: false)
  }
  for cp in [UInt32(0x4E2D), 0x4E2E, 0x4E2F] {
    use(cp, wide: true)
  }
  #expect(blank == 3)  // the atlas was full: the wide ones found no room
  #expect(atlas.nearlyFull)
  atlas.reset()
  taken.removeAll()
  use(0x4E2D, wide: true)
  #expect(blank == 3)
}

/// Offscreen frames of a terminal fed `text`, read back as pixels. Scale 2
/// is a Retina display; 1 is a plain one.
private struct Frame {
  let px: [UInt8]
  let width: Int
  let metrics: CellMetrics

  init(
    _ text: String, rows: Int = 3, cols: Int = 6, scale: Double = 2,
    selection: (start: (row: Int, col: Int), end: (row: Int, col: Int))? = nil,
    matches: [(row: Int, start: Int, end: Int)] = [],
    hoverLink: UInt8 = 0, zoom: Float = 1, shift: SIMD2<Float> = .zero, cursor: Bool = false
  ) throws {
    var theme = Theme()
    theme.fontSize = 14
    let renderer = try Renderer(theme: theme, scale: scale)
    let term = try Terminal(rows: rows, cols: cols, history: 0)
    theme.apply { term.configure(color: $0, rgb: $1) }
    term.write(text)
    var screen = Screen()
    term.snapshot(into: &screen)
    renderer.selection = selection
    renderer.matches = matches
    renderer.hoverLink = hoverLink
    renderer.zoom = zoom
    renderer.shift = shift
    metrics = renderer.metrics
    width = cols * metrics.width
    px = try renderer.pixels(
      screen, width: width, height: rows * metrics.height, cursorVisible: cursor)
  }

  func rgb(_ x: Int, _ y: Int) -> UInt32 {
    let i = (y * width + x) * 4
    return UInt32(px[i + 2]) << 16 | UInt32(px[i + 1]) << 8 | UInt32(px[i])
  }

  /// Every pixel of cells [c0, c1) in `row`.
  func all(row: Int, cols c0: Int, _ c1: Int, _ want: UInt32) -> Bool {
    for y in row * metrics.height..<(row + 1) * metrics.height {
      for x in c0 * metrics.width..<c1 * metrics.width where rgb(x, y) != want {
        return false
      }
    }
    return true
  }
}

@Test(arguments: [1.0, 2.0])
func blocksHaveNoSeams(scale: Double) throws {
  let f = try Frame("\u{1b}[97m██████\r\n▀▀▀▀▀▀\r\n", scale: scale)
  #expect(f.metrics.width > 0 && f.metrics.height > 0)
  #expect(f.all(row: 0, cols: 0, 6, 0xFFFFFF))
  let half = f.metrics.height - (f.metrics.height * 4 + 4) / 8
  for x in 0..<(6 * f.metrics.width) {
    #expect(f.rgb(x, f.metrics.height + half - 1) == 0xFFFFFF)
    #expect(f.rgb(x, f.metrics.height + half) == 0x000000)
  }
}

@Test(arguments: [1.0, 2.0])
func boxLinesRunAcrossCells(scale: Double) throws {
  let f = try Frame("\u{1b}[97m──────\r\n", scale: scale)
  let rows = (0..<f.metrics.height).filter { f.rgb(0, $0) == 0xFFFFFF }
  #expect(!rows.isEmpty)
  for x in 0..<(6 * f.metrics.width) {
    for y in rows {
      #expect(f.rgb(x, y) == 0xFFFFFF)
    }
  }
}

@Test func backgroundFillsTheWholeCell() throws {
  let f = try Frame("\u{1b}[41m  \u{1b}[0m")
  #expect(f.all(row: 0, cols: 0, 2, 0xBB0000))
  #expect(f.all(row: 0, cols: 2, 3, 0x000000))
}

@Test func textLeavesInkInsideItsCell() throws {
  let f = try Frame("\u{1b}[32mA")
  var ink = 0
  for y in 0..<f.metrics.height {
    for x in 0..<f.metrics.width where f.rgb(x, y) != 0 {
      ink += 1
    }
  }
  #expect(ink > 0)
  #expect(f.all(row: 0, cols: 1, 6, 0x000000))
  #expect(f.all(row: 1, cols: 0, 6, 0x000000))
}

@Test func boldUsesTheBrightColor() throws {
  let f = try Frame("\u{1b}[1;41;31m█")
  #expect(f.all(row: 0, cols: 0, 1, 0xFF5555))
}

@Test func cellMetricsAreWholePixels() {
  let font = Renderer.font(Theme())
  let one = CellMetrics(font: font, scale: 1)
  let two = CellMetrics(font: font, scale: 2)
  #expect(one.width > 0 && one.height > one.width)
  #expect(two.baseline > 0 && two.baseline <= two.height)
}

/// FOSFORO_BENCH=1 swift test -c release --filter highlightCost: a 200x60
/// frame with no match and with ten thousand, as the whole picture to
/// pixels (GPU included, the same in both).
@Test(.enabled(if: ProcessInfo.processInfo.environment["FOSFORO_BENCH"] == "1"))
func highlightCost() throws {
  var theme = Theme()
  theme.fontSize = 14
  let r = try Renderer(theme: theme, scale: 2)
  let term = try Terminal(rows: 60, cols: 200, history: 0)
  term.write([String](repeating: String(repeating: "a", count: 200), count: 60).joined())
  var screen = Screen()
  term.snapshot(into: &screen)
  var many: [(row: Int, start: Int, end: Int)] = []
  for row in 0..<50 {
    for c in 0..<200 {
      many.append((row, c, c))
    }
  }
  for (name, matches) in [("none", []), ("10000", many)] {
    r.matches = matches
    _ = try r.pixels(screen, width: 200 * r.metrics.width, height: 60 * r.metrics.height)
    let t = Date()
    for _ in 0..<8 {
      _ = try r.pixels(screen, width: 200 * r.metrics.width, height: 60 * r.metrics.height)
    }
    print("highlight \(name): \(Int(Date().timeIntervalSince(t) * 1000 / 8)) ms a frame")
  }
}

/// FOSFORO_BENCH=1 swift test -c release --filter frameCPUCost: the CPU
/// side of a frame alone (build + encode, no GPU wait), at 80x25 and
/// 200x60 full of text, as the window pays it per output change.
@Test(.enabled(if: ProcessInfo.processInfo.environment["FOSFORO_BENCH"] == "1"))
func frameCPUCost() throws {
  var theme = Theme()
  theme.fontSize = 14
  let r = try Renderer(theme: theme, scale: 2)
  for (rows, cols) in [(25, 80), (60, 200)] {
    let term = try Terminal(rows: rows, cols: cols, history: 0)
    term.write([String](repeating: String(repeating: "a", count: cols), count: rows).joined())
    var screen = Screen()
    term.snapshot(into: &screen)
    let d = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: .bgra8Unorm, width: cols * r.metrics.width, height: rows * r.metrics.height,
      mipmapped: false)
    d.usage = [.renderTarget]
    guard let target = r.device.makeTexture(descriptor: d) else { return }
    var buffers: [MTLCommandBuffer] = []
    let t = Date()
    for _ in 0..<60 {
      guard let cb = r.makeCommandBuffer() else { return }
      r.encode(screen, into: target, commandBuffer: cb)
      cb.commit()
      buffers.append(cb)
    }
    let cpu = Date().timeIntervalSince(t)
    buffers.last?.waitUntilCompleted()
    print("frame \(cols)x\(rows): \(String(format: "%.2f", cpu * 1000 / 60)) ms CPU a frame")
  }
}

/// Matches light exactly their cells, overlapping ones and a wide glyph
/// included; the cells between stay as they were.
@Test func matchesLightTheirCellsOnly() throws {
  let f = try Frame(
    "ab中cd ef\r\nab", cols: 10,
    matches: [(0, 7, 8), (0, 0, 2), (0, 1, 5), (1, 0, 0)])
  let lit = Theme().match
  for c in 0..<10 {
    let want = (c <= 5 || c == 7 || c == 8) ? lit : 0x000000
    #expect(f.rgb(c * f.metrics.width, 0) == want, "column \(c)")
  }
  #expect(f.rgb(0, f.metrics.height) == lit && f.rgb(f.metrics.width, f.metrics.height) == 0)
}

@Test func selectionSpansRowsInReadingOrder() throws {
  let f = try Frame("", selection: ((0, 4), (1, 1)))
  #expect(f.all(row: 0, cols: 0, 4, 0x000000))
  #expect(f.all(row: 0, cols: 4, 6, 0xB5D5FF))
  #expect(f.all(row: 1, cols: 0, 2, 0xB5D5FF))
  #expect(f.all(row: 1, cols: 2, 6, 0x000000))
}

/// Without the font every private-use rune is the same LastResort box.
@Test(
  .enabled(
    if: CTFontCopyPostScriptName(CTFontCreateWithName("SymbolsNFM" as CFString, 12, nil))
      as String == "SymbolsNFM"))
func nerdFontIconsComeFromTheSymbolsFont() throws {
  let bolt = try Frame("\u{1b}[37m\u{F0E7}")
  let folder = try Frame("\u{1b}[37m\u{F07B}")
  #expect(bolt.px != folder.px)
}

/// An icon followed by a space spreads into it; followed by text, it keeps
/// to its own cell. Powerline separators never spread.
@Test func iconsTakeTheSpaceAfterThem() throws {
  let spread = try Frame("\u{1b}[37m\u{F0E7} ")
  #expect(!spread.all(row: 0, cols: 1, 2, 0x000000))
  let kept = try Frame("\u{1b}[37m\u{F0E7}x")
  let x = try Frame("\u{1b}[37m x")
  for y in 0..<kept.metrics.height {
    for c in kept.metrics.width..<(2 * kept.metrics.width) {
      #expect(kept.rgb(c, y) == x.rgb(c, y))
    }
  }
  #expect(try Frame("\u{1b}[37m\u{E0B0} ").all(row: 0, cols: 1, 2, 0x000000))
}

@Test func emojiKeepsItsColors() throws {
  let f = try Frame("\u{1b}[37m\u{1F600}")
  var colored = 0
  for y in 0..<f.metrics.height {
    for x in 0..<(2 * f.metrics.width) {
      let c = f.rgb(x, y)
      let r = c >> 16
      let g = (c >> 8) & 0xFF
      let b = c & 0xFF
      if r != g || g != b {
        colored += 1
      }
    }
  }
  #expect(colored > 0)
  #expect(f.all(row: 0, cols: 2, 6, 0x000000))
}

/// An emoji behaves like text under SGR 8 (hidden) and under the cursor:
/// invisible leaves the cell blank, a bar or underline cursor shows over it.
@Test func emojiHidesAndTakesTheCursor() throws {
  func colored(_ f: Frame) -> Int {
    var n = 0
    for y in 0..<f.metrics.height {
      for x in 0..<(2 * f.metrics.width) {
        let c = f.rgb(x, y)
        if (c >> 16) != ((c >> 8) & 0xFF) || ((c >> 8) & 0xFF) != (c & 0xFF) {
          n += 1
        }
      }
    }
    return n
  }
  #expect(colored(try Frame("\u{1F600}")) > 0)
  #expect(colored(try Frame("\u{1b}[8m\u{1F600}")) == 0)
  #expect(try Frame("\u{1b}[8m\u{1F600}").all(row: 0, cols: 0, 2, 0x000000))
  for style in [4, 6] {  // underline, bar
    let plain = try Frame("\u{1b}[\(style) q\u{1F600}\u{1b}[1;1H", cursor: false)
    let cursor = try Frame("\u{1b}[\(style) q\u{1F600}\u{1b}[1;1H", cursor: true)
    #expect(plain.px != cursor.px, "cursor style \(style) over an emoji")
  }
}

@Test func underlineStylesLookDifferent() throws {
  // SGR 4:1 single, 4:3 curly, 4:4 dotted, 4:5 dashed, on blank cells
  let f = try Frame(
    "\u{1b}[97;4:1m      \r\n\u{1b}[4:3m      \r\n\u{1b}[4:4m      \r\n\u{1b}[4:5m      ",
    rows: 4)
  let w = 6 * f.metrics.width
  func lit(_ row: Int) -> [(x: Int, y: Int)] {
    var out: [(Int, Int)] = []
    for y in row * f.metrics.height..<(row + 1) * f.metrics.height {
      for x in 0..<w where f.rgb(x, y) == 0xFFFFFF {
        out.append((x, y))
      }
    }
    return out
  }
  let single = lit(0)
  let rows = Set(single.map(\.y))
  #expect(single.count == rows.count * w)  // solid lines, edge to edge
  let curly = lit(1)
  #expect(Set(curly.map(\.y)).count > rows.count + 2)  // it waves
  #expect(Set(curly.map(\.x)).count == w)  // with no gaps
  for (row, name) in [(2, "dotted"), (3, "dashed")] {
    let cols = Set(lit(row).map(\.x)).count
    #expect(cols > w / 4 && cols < w * 3 / 4, "\(name)")
  }
}

@Test func hyperlinksAreUnderlined() throws {
  let plain = try Frame("\u{1b}[97m      ")
  let linked = try Frame("\u{1b}[97m\u{1b}]8;;https://x.io\u{7}      \u{1b}]8;;\u{7}")
  #expect(plain.all(row: 0, cols: 0, 6, 0x000000))
  #expect(!linked.all(row: 0, cols: 0, 6, 0x000000))
  // under the pointer the dashes join into a solid line
  let hovered = try Frame(
    "\u{1b}[97m\u{1b}]8;;https://x.io\u{7}      \u{1b}]8;;\u{7}", hoverLink: 1)
  func inkColumns(_ f: Frame) -> Int {
    (0..<(6 * f.metrics.width)).filter { x in
      (0..<f.metrics.height).contains { f.rgb(x, $0) != 0 }
    }.count
  }
  #expect(inkColumns(hovered) == 6 * hovered.metrics.width)
  #expect(inkColumns(linked) < inkColumns(hovered))
}

/// Pinch zoom enlarges the picture: one red cell at 2x covers four cells'
/// worth of pixels, and the shift moves it.
@Test func zoomEnlargesThePicture() throws {
  let f = try Frame("\u{1b}[41m \u{1b}[0m", zoom: 2)
  #expect(f.all(row: 0, cols: 0, 2, 0xBB0000))
  #expect(f.all(row: 1, cols: 0, 2, 0xBB0000))
  #expect(f.all(row: 0, cols: 2, 3, 0x000000))
  let m = f.metrics
  let g = try Frame("\u{1b}[41m \u{1b}[0m", zoom: 2, shift: SIMD2(-Float(m.width), 0))
  #expect(g.all(row: 0, cols: 0, 1, 0xBB0000))  // half of it slid off the left edge
  #expect(g.all(row: 0, cols: 1, 2, 0x000000))
}

/// The faces of a font at a size go to CoreText once per process: a second
/// renderer with the same theme makes none.
@Test func fontFacesAreMadeOnce() throws {
  var theme = Theme()
  theme.fontSize = 13.5
  _ = try Renderer(theme: theme, scale: 2)
  let made = Atlas.facesMade
  _ = try Renderer(theme: theme, scale: 2)
  #expect(Atlas.facesMade == made)
  _ = try Renderer(theme: theme, scale: 3)  // another scale is another set
  #expect(Atlas.facesMade == made + 1)
}

@Test func fontSizeChangesTheCells() throws {
  var theme = Theme()
  theme.fontSize = 14
  let r = try Renderer(theme: theme, scale: 2)
  let small = r.metrics
  try r.setFontSize(28)
  #expect(r.metrics.width > small.width && r.metrics.height > small.height)
  #expect(r.theme.fontSize == 28)
}

/// The block cursor shows its cell in reverse video: red on black becomes
/// a red block.
@Test func blockCursorIsReverseVideo() throws {
  let f = try Frame("\u{1b}[31;44mA\u{1b}[D", cursor: true)
  #expect(f.rgb(0, 0) == 0xBB0000)
  #expect(f.rgb(f.metrics.width, 0) == 0x000000)
  let d = try Frame("A\u{1b}[D", cursor: true)  // default colors
  #expect(d.rgb(0, 0) == 0xBBBBBB)
  let e = try Frame("", cursor: true)  // an empty cell still shows the block
  #expect(e.rgb(0, 0) == 0xBBBBBB)
}

@Test func typingHoldsTheCursorLit() throws {
  let r = try Renderer(theme: Theme(), scale: 1)
  r.blink()
  #expect(!r.cursorOn)
  r.typed()
  r.blink()
  r.blink()
  #expect(r.cursorOn)
}
