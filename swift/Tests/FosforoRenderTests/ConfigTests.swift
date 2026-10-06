import Foundation
import Testing

@testable import FosforoRender

@Test func theDefaultFileChangesNothing() throws {
  let t = try Theme.parse(Theme.defaultConfig)
  let d = Theme()
  #expect(t.fontName == d.fontName && t.fontSize == d.fontSize && t.palette == d.palette)
  #expect(t.foreground == d.foreground && t.rows == d.rows && t.brightBold == d.brightBold)
}

@Test func settingsOverrideTheDefaults() throws {
  let t = try Theme.parse(
    """
    (set FontName "Menlo-Regular")
    (set FontSize 14.5)
    (set Rows 40) (set Cols 132)
    (set BrightBold #f)
    (set Background "#102030")
    (set Color1 "#FF0000")
    (set KeyDelay 250) (set KeyRepeat 20)
    """)
  #expect(t.fontName == "Menlo-Regular" && t.fontSize == 14.5)
  #expect(t.rows == 40 && t.cols == 132 && !t.brightBold)
  #expect(t.background == 0x102030 && t.palette[1] == 0xFF0000)
  #expect(t.keyDelay == 250 && t.keyRepeat == 20)
}

@Test func mistakesAreReported() throws {
  let cases = [
    "(set Colour1 \"#ff0000\")",
    "(set Color1 \"red\")",
    "(set Rows 2.5)",
    "(set Rows 0)",
    "(set FontSize \"big\")",
    "(set FontSize",
    "(set KeyRepeat 0)",
    // past Int, in both directions, and not finite: an error, never a trap
    "(set History 1000000000000000000000000000000)",
    "(set Rows -1000000000000000000000000000000)",
    "(set Cols (/ 1 0))",
    "(set History (- (/ 1 0)))",
    "(set KeyDelay (/ 0 0))",
  ]
  for src in cases {
    #expect(throws: ConfigError.self, "\(src)") { try Theme.parse(src) }
  }
  #expect(try Theme.parse("(set History 0) (set Rows 2)").history == 0)
  #expect(Theme().clipboard == "allow")
  #expect(try Theme.parse("(set Clipboard \"deny\")").clipboard == "deny")
  #expect(Theme().optionArrows == "xterm")
  #expect(try Theme.parse("(set OptionArrows \"word\")").optionArrows == "word")
}

@Test func firstRunWritesTheDocumentedDefault() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("fosforo/init.filo")
  _ = try Theme.load(from: url)
  let text = try String(contentsOf: url, encoding: .utf8)
  #expect(text == Theme.defaultConfig)
  try "(set Rows 30)".write(to: url, atomically: true, encoding: .utf8)
  #expect(try Theme.load(from: url).rows == 30)
}

/// The sample themes are written beside it and load: default changes
/// nothing, phosphor turns the screen green, init.filo still wins.
@Test func sampleThemesLoad() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  let url = dir.appendingPathComponent("fosforo/init.filo")
  let d = try Theme.load(from: url)
  try "(theme \"default\")".write(to: url, atomically: true, encoding: .utf8)
  let t = try Theme.load(from: url)
  #expect(t.palette == d.palette && t.foreground == d.foreground && t.selection == d.selection)
  try "(theme \"phosphor\") (set Bold \"#ffffff\")".write(
    to: url, atomically: true, encoding: .utf8)
  let p = try Theme.load(from: url)
  #expect(p.foreground == 0x33FF66 && p.bold == 0xFFFFFF)
  // every ANSI color is a green: more green than red or blue, red at most
  // half the green; black stays the background and bright white the pale peak
  #expect(p.palette[0] == 0x050F07 && p.palette[15] == 0xB4FFC8)
  for i in 1..<15 {
    let c = p.palette[i]
    let r = (c >> 16) & 0xFF
    let g = (c >> 8) & 0xFF
    let b = c & 0xFF
    #expect(g > r * 2 && g > b, "Color\(i) is not a green: \(String(c, radix: 16))")
  }
  // red dimmer than yellow, blue the dimmest
  #expect(p.palette[1] < p.palette[3] && p.palette[4] < p.palette[1])
}

/// A handler set in the config runs on its event: what it sets comes back
/// as a theme, what it notifies comes back as text; the rest stays quiet.
@MainActor @Test func hooksRunOnEvents() throws {
  let (t, hooks) = try Hooks.open(
    "(set on-bell (fn (a) (set FontSize 30) (notify a)))", themes: nil)
  #expect(t.fontSize == Theme().fontSize && hooks.has == ["bell"])
  var got: Theme?
  var note = ""
  hooks.onTheme = { got = $0 }
  hooks.onNotice = { note = $0 }
  hooks.fire("bell", "ding")
  #expect(got?.fontSize == 30 && note == "ding")
  got = nil
  hooks.fire("bell", "again")  // the same theme: not applied twice
  #expect(got == nil && note == "again")
  hooks.fire("title", "x")  // nothing listens
  Hooks.install(hooks)
  #expect(Hooks.wants("bell") && !Hooks.wants("title"))
  Hooks.install(nil)
  #expect(!Hooks.wants("bell"))
}

/// A handler may switch the theme long after open() returned, so the
/// session keeps its own copy of the themes path.
@MainActor @Test func hooksSwitchThemesAfterOpen() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  try "(set Foreground \"#123456\")".write(
    to: dir.appendingPathComponent("dim.filo"), atomically: true, encoding: .utf8)
  let (_, hooks) = try Hooks.open("(set on-blur (fn (a) (theme \"dim\")))", themes: dir)
  var got: Theme?
  hooks.onTheme = { got = $0 }
  hooks.onNotice = { Issue.record("notice: \($0)") }
  hooks.fire("blur")
  #expect(got?.foreground == 0x123456)
}
