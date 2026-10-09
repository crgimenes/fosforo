import CFosforo
import Foundation

public struct ConfigError: Error, CustomStringConvertible {
  public let description: String
}

/// init.filo: a Filo script that `set`s the keys below. Unknown names are
/// errors (the globals are sealed), so a typo is reported, not ignored.
extension Theme {
  /// The user's home as fosforo sees it: on iOS the app's Documents (the
  /// shell's ~, shown in the Files app), on the Mac the real one.
  public static var home: URL {
    #if os(iOS)
      return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory())
    #else
      return URL(fileURLWithPath: NSHomeDirectory())
    #endif
  }

  /// ~/.config/fosforo/init.filo, where a Unix tool keeps its config.
  public static var configURL: URL {
    home.appendingPathComponent(".config/fosforo/init.filo")
  }

  /// A path from the config, ~ meaning home.
  public static func expand(_ path: String) -> URL {
    if path == "~" || path.hasPrefix("~/") {
      return home.appendingPathComponent(String(path.dropFirst(2)))
    }
    return URL(fileURLWithPath: path)
  }

  public static let defaultConfig = """
    ;; init.filo — fosforo configuration
    ;;
    ;; Executed at startup and for every new window; Reload Config (Cmd+R, or
    ;; the touch menu) applies it to the open ones too, except Rows, Cols and
    ;; History, which only a new window takes. Each (set Key value)
    ;; overrides the built-in default. Booleans are #t and #f; colors are
    ;; "#rrggbb". Uncomment and edit as needed:
    ;;
    ;; settings.filo, beside this file, is what the config screen writes
    ;; (`config` in the shell, on iPad and iPhone). It runs first: what this
    ;; file sets wins over it.
    ;;
    ;; (set FontName "3270-Regular") ; PostScript name; Menlo when missing
    ;; (set FontSize 25)             ; points (default 25 on the Mac, 18 on iOS)
    ;; (set Rows 25)                 ; size of a new window
    ;; (set Cols 80)
    ;; (set History 1000)            ; scrollback lines
    ;; (set BrightBold #t)           ; bold text in colors 0-7 uses 8-15
    ;; (set StatusBar #t)            ; directory, branch, title and n/N at the bottom
    ;;
    ;; (theme "default")             ; themes/default.filo (beside this file) runs
    ;;                               ; first, this file over it; phosphor is another
    ;; (set KeyDelay 300)            ; ms before a held key repeats (iPad, iPhone)
    ;; (set KeyRepeat 30)            ; ms between repeats
    ;; (set Clipboard "allow")       ; programs may set the clipboard (OSC 52; the
    ;;                               ; bar says when one did); "deny" to refuse
    ;; (set OptionArrows "xterm")    ; Option+arrows as iTerm2 (tmux M-Left/M-Right);
    ;;                               ; "word": ESC b / ESC f, by the word in zsh
    ;;
    ;; DEVICE says where this runs: "iphone", "ipad" or "mac". For example,
    ;; a smaller font on the phone:
    ;; (if (= DEVICE "iphone") (set FontSize 16) (set FontSize 18))
    ;;
    ;; The shell (rocchetto, on iPad and iPhone):
    ;; (set User "")                 ; the prompt's user; "" is the device's
    ;; (set HostName "")             ; the prompt's host; "" is the device's name
    ;; (set Banner "~/.config/fosforo/banner.ans") ; shown when a shell opens, if
    ;;                               ; it fits; any text or ANSI art; "" for none
    ;; (set BannerNarrow "~/.config/fosforo/banner-narrow.ans") ; in its place
    ;;                               ; when it does not fit; "" for none
    ;; (set Greeting "help      what each command does\\nedt FILE  ...")
    ;;                               ; lines under it, on any screen, "\\n"
    ;;                               ; between them; "" for none
    ;;
    ;; (set Foreground "#bbbbbb")
    ;; (set Background "#000000")
    ;; (set Bold "#ffffff")          ; bold text in the default color
    ;; (set Cursor "#bbbbbb")        ; bar and underline cursors; a block shows
    ;;                               ; the cell under it in reverse video
    ;; (set Selection "#b5d5ff")
    ;; (set SelectionText "#000000")
    ;; (set Match "#ffff55")         ; search matches (the current one: Selection)
    ;; (set MatchText "#000000")
    ;;
    ;; The 16 ANSI colors, Color0 (black) to Color15 (bright white):
    ;; (set Color0 "#000000") (set Color8 "#666666")
    ;; (set Color1 "#bb0000") (set Color9 "#ff5555")
    ;; (set Color2 "#00bb00") (set Color10 "#55ff55")
    ;; (set Color3 "#bbbb00") (set Color11 "#ffff55")
    ;; (set Color4 "#0000bb") (set Color12 "#5555ff")
    ;; (set Color5 "#bb00bb") (set Color13 "#ff55ff")
    ;; (set Color6 "#00bbbb") (set Color14 "#55ffff")
    ;; (set Color7 "#bbbbbb") (set Color15 "#ffffff")
    ;;
    ;; getEnv reads an environment variable, with a fallback:
    ;; (set FontName (getEnv "FOSFORO_FONT" "3270-Regular"))
    ;;
    ;; Hooks: a function set on one of these runs when the event happens,
    ;; with one argument (the title, the notice text; "" otherwise). What
    ;; it sets applies at once to every window; (theme "name") switches the
    ;; theme; (notify "text") shows a notification. Events: on-open and
    ;; on-close (a session), on-bell, on-title, on-prompt (the shell's OSC
    ;; 133 mark), on-focus and on-blur (the window), on-notify (OSC 9/777
    ;; from a program). Nothing runs for an event without a handler.
    ;; (set on-bell (fn (arg) (notify "bell")))
    ;; (set on-blur (fn (arg) (theme "phosphor")))
    ;; (set on-focus (fn (arg) (theme "default")))

    """

  /// The colors a theme file sets: the built-in ones, to start one from.
  static var defaultTheme: String {
    let d = Theme()
    var lines = [
      ";; default: the built-in colors. (theme \"default\") in init.filo; a copy",
      ";; under another name is a new theme. What init.filo sets wins over it.",
      "(set Foreground \"\(hex(d.foreground))\")", "(set Background \"\(hex(d.background))\")",
      "(set Bold \"\(hex(d.bold))\")", "(set Cursor \"\(hex(d.cursor))\")",
      "(set Selection \"\(hex(d.selection))\")",
      "(set SelectionText \"\(hex(d.selectionText))\")",
      "(set Match \"\(hex(d.match))\")", "(set MatchText \"\(hex(d.matchText))\")",
      "(set StatusBackground \"\(hex(d.statusBackground))\")",
    ]
    for (i, c) in d.palette.enumerated() {
      lines.append("(set Color\(i) \"\(hex(c))\")")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  static let phosphorTheme = """
    ;; phosphor: green on black, as a P1 tube glows. (theme "phosphor")
    (set Foreground "#33ff66")
    (set Background "#050f07")
    (set Bold "#b4ffc8")
    (set Cursor "#33ff66")
    (set Selection "#1e6b33")
    (set SelectionText "#d9ffe3")
    (set Match "#ffcc33")
    (set MatchText "#000000")
    (set StatusBackground "#0b1f10")
    ;; one phosphor: the 16 colors are greens, lit as bright as the color
    ;; they stand for (red dim, yellow bright; the brights paler)
    (set Color0 "#050f07") (set Color8 "#135724")
    (set Color1 "#1e923b") (set Color9 "#5aff83")
    (set Color2 "#27bf4c") (set Color10 "#6cff91")
    (set Color3 "#30ed5f") (set Color11 "#7fffa0")
    (set Color4 "#19752f") (set Color12 "#4eff7a")
    (set Color5 "#21a342") (set Color13 "#61ff89")
    (set Color6 "#2ad054") (set Color14 "#74ff97")
    (set Color7 "#33ff66") (set Color15 "#b4ffc8")

    """

  static let sunTheme = """
    ;; sol: black on white, for a screen in the sun. (theme "sol")
    (set Foreground "#000000")
    (set Background "#ffffff")
    (set Bold "#000000")
    (set Cursor "#000000")
    (set Selection "#b5d5ff")
    (set SelectionText "#000000")
    (set Match "#ffcc33")
    (set MatchText "#000000")
    (set StatusBackground "#d8d8d8")
    ;; dark enough to read on white; the brights a shade stronger
    (set Color0 "#000000") (set Color8 "#555555")
    (set Color1 "#b21818") (set Color9 "#d01b1b")
    (set Color2 "#11780e") (set Color10 "#16930f")
    (set Color3 "#8a6a00") (set Color11 "#a07a00")
    (set Color4 "#1a3fb8") (set Color12 "#2552d8")
    (set Color5 "#9a1fa0") (set Color13 "#b528bd")
    (set Color6 "#0d7480") (set Color14 "#0f8a98")
    (set Color7 "#bbbbbb") (set Color15 "#ffffff")

    """

  /// Reads the config file, writing the documented default on first run
  /// (and the default banner beside it, from the app's bundle). Sample
  /// themes go in themes/ when there is no such directory yet.
  public static func load(from url: URL = configURL) throws -> Theme {
    let (source, themes) = try prepare(url)
    let base = try settings(beside: url, themes: themes)
    do {
      return try parse(source, themes: themes, base: base)
    } catch let e as ConfigError {
      throw ConfigError(description: "\(url.path): \(e.description)")
    }
  }

  /// As load, keeping the interpreter for the on-* hooks.
  public static func open(from url: URL = configURL) throws -> (Theme, Hooks) {
    let (source, themes) = try prepare(url)
    let base = try settings(beside: url, themes: themes)
    do {
      return try Hooks.open(source, themes: themes, base: base)
    } catch let e as ConfigError {
      throw ConfigError(description: "\(url.path): \(e.description)")
    }
  }

  static func prepare(_ url: URL) throws -> (source: String, themes: URL) {
    if !FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try defaultConfig.write(to: url, atomically: true, encoding: .utf8)
      for name in ["banner", "banner-narrow"] {
        let banner = url.deletingLastPathComponent().appendingPathComponent(name + ".ans")
        if let art = Bundle.main.url(forResource: name, withExtension: "ans"),
          !FileManager.default.fileExists(atPath: banner.path)
        {
          try? FileManager.default.copyItem(at: art, to: banner)
        }
      }
    }
    let themes = url.deletingLastPathComponent().appendingPathComponent("themes")
    if !FileManager.default.fileExists(atPath: themes.path) {
      try FileManager.default.createDirectory(at: themes, withIntermediateDirectories: true)
      try defaultTheme.write(
        to: themes.appendingPathComponent("default.filo"), atomically: true, encoding: .utf8)
      try phosphorTheme.write(
        to: themes.appendingPathComponent("phosphor.filo"), atomically: true, encoding: .utf8)
    }
    // came later than the others: written where it is missing, never over
    // a file of that name
    let sun = themes.appendingPathComponent("sol.filo")
    if !FileManager.default.fileExists(atPath: sun.path) {
      try? sunTheme.write(to: sun, atomically: true, encoding: .utf8)
    }
    return (try String(contentsOf: url, encoding: .utf8), themes)
  }

  /// settings.filo beside init.filo, what the config screen writes: run
  /// first, so init.filo starts from it and what init.filo sets wins.
  static func settings(beside url: URL, themes: URL?) throws -> Theme {
    let file = url.deletingLastPathComponent().appendingPathComponent("settings.filo")
    guard let source = try? String(contentsOf: file, encoding: .utf8) else { return Theme() }
    do {
      return try parse(source, themes: themes)
    } catch let e as ConfigError {
      throw ConfigError(description: "\(file.path): \(e.description)")
    }
  }

  /// themes: where (theme "name") finds name.filo; nil, none. base: the
  /// values the script starts from.
  public static func parse(_ source: String, themes: URL? = nil, base: Theme = Theme()) throws
    -> Theme
  {
    let keys = Theme.keys()
    var vars = variables(keys, of: base)
    defer { freeNames(vars) }
    let bytes = Array(source.utf8)
    var err = [CChar](repeating: 0, count: 512)
    let rc = cfg_run(bytes, bytes.count, themes?.path, &vars, vars.count, &err, err.count)
    guard rc == 0 else {
      throw ConfigError(description: cString(err))
    }
    return try theme(from: vars, keys: keys)
  }

  static func cString(_ buf: [CChar]) -> String {
    String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
  }

  /// The config's variables, as the core declares them to the script.
  static func variables(_ keys: [(String, Key)], of t: Theme) -> [cfg_var] {
    // DEVICE comes after the keys and is never read back: what a script
    // sets there changes nothing
    var device = cfg_var()
    device.name = UnsafePointer(strdup("DEVICE"))
    device.kind = Int32(CFG_STR)
    setString(&device, Theme.device)
    return keys.map { name, key in variable(name, key, of: t) } + [device]
  }

  /// "iphone", "ipad" or "mac": for an (if (= DEVICE "iphone") ...) in the
  /// config. From the model's name, not UIKit, so any thread may ask.
  public static var device: String {
    #if os(iOS)
      var model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
      if model.isEmpty {
        var size = 0
        sysctlbyname("hw.machine", nil, &size, nil, 0)
        var name = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.machine", &name, &size, nil, 0)
        model = cString(name)
      }
      return model.hasPrefix("iPad") ? "ipad" : "iphone"
    #else
      return "mac"
    #endif
  }

  static func freeNames(_ vars: [cfg_var]) {
    for v in vars {
      free(UnsafeMutablePointer(mutating: v.name))
    }
  }

  /// A theme from what the script left in the variables; a value out of
  /// range is an error.
  static func theme(from vars: [cfg_var], keys: [(String, Key)]) throws -> Theme {
    var t = Theme()
    for (i, (name, key)) in keys.enumerated() {
      try assign(vars[i], name, key, to: &t)
    }
    return t
  }

  static func keys() -> [(String, Key)] {
    var keys: [(String, Key)] = [
      ("FontName", .text(\.fontName)), ("FontSize", .number(\.fontSize, 4...200)),
      ("Rows", .count(\.rows, 2...VT_MAX_ROWS)), ("Cols", .count(\.cols, 2...VT_MAX_COLS)),
      ("History", .count(\.history, 0...VT_MAX_HISTORY)), ("BrightBold", .flag(\.brightBold)),
      ("StatusBar", .flag(\.statusBar)), ("Bell", .text(\.bell)), ("User", .text(\.user)),
      ("Clipboard", .text(\.clipboard)), ("OptionArrows", .text(\.optionArrows)),
      ("HostName", .text(\.hostName)), ("Banner", .text(\.banner)),
      ("BannerNarrow", .text(\.bannerNarrow)),
      ("Greeting", .text(\.greeting)),
      ("KeyDelay", .count(\.keyDelay, 50...2000)), ("KeyRepeat", .count(\.keyRepeat, 10...500)),
      ("Foreground", .color(\.foreground)), ("Background", .color(\.background)),
      ("Bold", .color(\.bold)), ("Cursor", .color(\.cursor)),
      ("Selection", .color(\.selection)), ("SelectionText", .color(\.selectionText)),
      ("Match", .color(\.match)), ("MatchText", .color(\.matchText)),
      ("StatusBackground", .color(\.statusBackground)),
    ]
    for i in 0..<16 {
      keys.append(("Color\(i)", .palette(i)))
    }
    return keys
  }

  enum Key {
    case text(WritableKeyPath<Theme, String>)
    case number(WritableKeyPath<Theme, Double>, ClosedRange<Double>)
    case count(WritableKeyPath<Theme, Int>, ClosedRange<Int>)
    case flag(WritableKeyPath<Theme, Bool>)
    case color(WritableKeyPath<Theme, UInt32>)
    case palette(Int)
  }

  private static func hex(_ rgb: UInt32) -> String {
    "#" + String(format: "%06x", rgb)
  }

  private static func variable(_ name: String, _ key: Key, of t: Theme) -> cfg_var {
    var v = cfg_var()
    v.name = UnsafePointer(strdup(name))
    switch key {
    case .text(let p):
      v.kind = Int32(CFG_STR)
      setString(&v, t[keyPath: p])
    case .number(let p, _):
      v.kind = Int32(CFG_NUM)
      v.num = t[keyPath: p]
    case .count(let p, _):
      v.kind = Int32(CFG_NUM)
      v.num = Double(t[keyPath: p])
    case .flag(let p):
      v.kind = Int32(CFG_BOOL)
      v.b = t[keyPath: p]
    case .color(let p):
      v.kind = Int32(CFG_STR)
      setString(&v, hex(t[keyPath: p]))
    case .palette(let i):
      v.kind = Int32(CFG_STR)
      setString(&v, hex(t.palette[i]))
    }
    return v
  }

  private static func setString(_ v: inout cfg_var, _ s: String) {
    withUnsafeMutableBytes(of: &v.str) { raw in
      let bytes = Array(s.utf8.prefix(raw.count - 1))
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
  }

  private static func string(_ v: cfg_var) -> String {
    withUnsafeBytes(of: v.str) { raw in
      String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
    }
  }

  static func parseColor(_ s: String) -> UInt32? {
    guard s.count == 7, s.hasPrefix("#"), let v = UInt32(s.dropFirst(), radix: 16) else {
      return nil
    }
    return v
  }

  private static func assign(_ v: cfg_var, _ name: String, _ key: Key, to t: inout Theme) throws {
    switch key {
    case .text(let p):
      t[keyPath: p] = string(v)
    case .number(let p, let range):
      guard range.contains(v.num) else {
        throw ConfigError(description: "\(name) must be in \(range), not \(v.num)")
      }
      t[keyPath: p] = v.num
    case .count(let p, let range):
      // Int(exactly:) is nil for a fraction, nan, inf or a number past Int:
      // Int(_:) would trap on those
      guard let n = Int(exactly: v.num), range.contains(n) else {
        throw ConfigError(description: "\(name) must be a whole number in \(range), not \(v.num)")
      }
      t[keyPath: p] = n
    case .flag(let p):
      t[keyPath: p] = v.b
    case .color(let p):
      t[keyPath: p] = try color(v, name)
    case .palette(let i):
      t.palette[i] = try color(v, name)
    }
  }

  private static func color(_ v: cfg_var, _ name: String) throws -> UInt32 {
    let s = string(v)
    guard let c = parseColor(s) else {
      throw ConfigError(description: "\(name) must be a color like \"#rrggbb\", not \"\(s)\"")
    }
    return c
  }
}
