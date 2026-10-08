import CFosforo

/// Font and colors. The default is an iTerm2-like "Default" profile; the Filo
/// config will override it.
public struct Theme: Sendable, Equatable {
  public var fontName = "3270-Regular"
  #if os(iOS)
    public var fontSize = 18.0  // an iPhone keeps ~39 columns; 25 leaves ~29
  #else
    public var fontSize = 25.0
  #endif
  public var palette: [UInt32] = [
    0x000000, 0xBB0000, 0x00BB00, 0xBBBB00, 0x0000BB, 0xBB00BB, 0x00BBBB, 0xBBBBBB,
    0x666666, 0xFF5555, 0x55FF55, 0xFFFF55, 0x5555FF, 0xFF55FF, 0x55FFFF, 0xFFFFFF,
  ]
  public var foreground: UInt32 = 0xBBBBBB
  public var background: UInt32 = 0x000000
  public var bold: UInt32 = 0xFFFFFF
  public var cursor: UInt32 = 0xBBBBBB
  public var selection: UInt32 = 0xB5D5FF
  public var selectionText: UInt32 = 0x000000
  public var match: UInt32 = 0xFFFF55  // search matches; the current one uses selection
  public var matchText: UInt32 = 0x000000
  /// iTerm2 "Use Bright Bold": bold text in colors 0-7 uses 8-15.
  public var brightBold = true
  public var rows = 25
  public var cols = 80
  public var history = 1000
  /// The row under the grid: session n/N, where the shell is, title.
  public var statusBar = true
  /// The bar's own band, so it reads as a bar and not as output.
  public var statusBackground: UInt32 = 0x1C1C1C
  /// BEL: "flash" the screen, "sound" the system's alert, or "none".
  public var bell = "flash"
  /// OSC 52: "allow" programs to set the clipboard (the bar says when one
  /// did), or "deny". Reading it is never allowed.
  public var clipboard = "allow"
  /// Option with ← →: "xterm" sends ESC[1;3D and ESC[1;3C, as iTerm2 does
  /// (tmux's M-Left, M-Right); "word" sends ESC b and ESC f, as Terminal.app.
  public var optionArrows = "xterm"
  /// The prompt's user@host in the shell (rocchetto); empty: the device's own.
  public var user = ""
  public var hostName = ""
  /// Shown when a shell opens, if it fits the window; "" for none.
  public var banner = "~/.config/fosforo/banner.ans"
  /// In its place when it does not fit (a phone held upright).
  public var bannerNarrow = "~/.config/fosforo/banner-narrow.ans"
  /// Lines under it, on any screen (a phone has no room for the banner):
  /// the first things to type. 36 columns at most: a phone upright, a larger font.
  public var greeting = """
    help      what each command does
    config    servers, keys, looks
    edt FILE  the text editor
    ~/.config/fosforo/init.filo  the rest
    """
  /// A held key on a hardware keyboard (iPad, iPhone; the Mac repeats as
  /// the system does): first repeat after keyDelay ms, then every keyRepeat.
  public var keyDelay = 300
  public var keyRepeat = 30

  public init() {}

  /// The palette lives in the core so OSC 4/10/11 queries answer with it.
  public func apply(_ configure: (Int, UInt32) -> Void) {
    for (i, rgb) in palette.enumerated() {
      configure(i, rgb)
    }
    configure(Int(VT_SLOT_FG), foreground)
    configure(Int(VT_SLOT_BG), background)
    configure(Int(VT_SLOT_CURSOR), cursor)
  }
}
