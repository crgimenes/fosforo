import CFosforo
import Darwin
import Foundation

public struct SessionError: Error, CustomStringConvertible {
  public let description: String
}

/// What the renderer needs from one frame, copied out under the lock so
/// drawing never holds up the reader.
public struct Screen: Sendable {
  public var rows = 0
  public var cols = 0
  public var cells: [vt_cell] = []
  public var cursor = vt_cursor()
  public var modes: UInt32 = 0
  public var generation: UInt64 = 0
  public var colors: [UInt32] = []

  public init() {}

  public func cell(_ row: Int, _ col: Int) -> vt_cell {
    cells[row * cols + col]
  }

  /// Text the input method is still composing, underlined at the cursor,
  /// which moves to its end; none of it reaches the host until committed.
  /// yagni: what does not fit on the cursor's row is cut, not wrapped.
  public mutating func compose(_ text: String) {
    guard rows > 0, cols > 0 else { return }
    let row = Int(cursor.row)
    var col = Int(cursor.col)
    let underline = UInt16(UInt32(VT_UL_SINGLE) << VT_ATTR_UL_SHIFT)
    for s in text.unicodeScalars {
      let w = Int(vt_width(s.value))
      guard w > 0 else { continue }
      guard col + w <= cols else { break }
      let i = row * cols + col
      cells[i].cp = s.value
      cells[i].attr = cells[i].attr & ~UInt16(VT_ATTR_UL_MASK) | underline
      cells[i].flags = UInt8(w == 2 ? VT_CELL_WIDE : 0)
      if w == 2 {
        cells[i + 1].cp = 0
        cells[i + 1].attr = cells[i].attr
        cells[i + 1].flags = UInt8(VT_CELL_WIDE_TAIL)
      }
      col += w
    }
    cursor.col = Int32(min(col, cols - 1))
  }
}

/// A transport feeding a vt core. The transport's reader thread owns the
/// writes into the core; everyone else goes through the lock.
public final class Session: @unchecked Sendable {
  private let lock = NSLock()
  private let terminal: Terminal
  private var term: OpaquePointer { terminal.raw }
  public let transport: Transport
  private var exited = false

  /// Called once on the reader thread with the exit status.
  public var onExit: (@Sendable (Int32) -> Void)?
  /// OSC 52 from the remote side (vim's "+y over ssh): text for the
  /// clipboard, on the reader thread. Reading the clipboard is never
  /// answered: the remote side gets to give, not to look.
  public var onClipboard: (@Sendable (String) -> Void)?
  /// OSC 9 (iTerm2) or 777 (urxvt): a program asking the user to look, on
  /// the reader thread; the app decides whether the window needs it.
  public var onNotify: (@Sendable (String) -> Void)?
  /// BEL, on the reader thread: at most one per `bellEvery`, as iTerm2
  /// suppresses them, since a binary sent to the screen is thousands of
  /// BELs and each one would be a flash, a hook run and a sound.
  public var onBell: (@Sendable () -> Void)? {
    didSet {
      terminal.onBell = onBell.map { f in { [weak self] in self?.bell(f) } }
    }
  }
  public static let bellEvery: TimeInterval = 0.1
  public static let noticeEvery: TimeInterval = 0.5
  private var lastBell = Date.distantPast  // reader thread only
  private var lastNotice = Date.distantPast
  private var noticesDropped = 0
  /// Output reached the terminal, on the reader thread: a view that sleeps
  /// between frames wakes up on it.
  public var onOutput: (@Sendable () -> Void)?

  private func bell(_ f: @Sendable () -> Void) {
    let now = Date()
    guard now.timeIntervalSince(lastBell) >= Session.bellEvery else { return }
    lastBell = now
    f()
  }

  /// OSC 9/777: one per `noticeEvery`; the next one says how many went by.
  private func notice(_ text: String) {
    let now = Date()
    guard now.timeIntervalSince(lastNotice) >= Session.noticeEvery else {
      noticesDropped += 1
      return
    }
    lastNotice = now
    let dropped = noticesDropped
    noticesDropped = 0
    onNotify?(dropped > 0 ? "\(text) (+\(dropped) more)" : text)
  }
  /// OSC 133;A, the shell marking a prompt, on the reader thread.
  public var onPrompt: (@Sendable () -> Void)?

  /// Whether a program may set the clipboard (OSC 52); the config's
  /// Clipboard key, set by the view. Read on the reader thread.
  public var clipboardAllowed = true

  private func osc(_ id: UInt32, _ data: [UInt8]) {
    switch id {
    case 52:
      if clipboardAllowed, let text = Session.clipboardText(data) {
        onClipboard?(text)
      }
    case 9, 777:
      if let text = Session.notice(id, data) {
        notice(text)
      }
    case 133:
      if data.first == UInt8(ascii: "A") {
        onPrompt?()
      }
    default:
      break
    }
  }

  /// OSC 9 is the message; OSC 777 is "notify;title;body".
  static func notice(_ id: UInt32, _ data: [UInt8]) -> String? {
    let text = String(decoding: data, as: UTF8.self)
    if id == 9 {
      return text.isEmpty ? nil : text
    }
    let parts = text.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count == 3, parts[0] == "notify" else { return nil }
    return parts[2].isEmpty ? String(parts[1]) : "\(parts[1]): \(parts[2])"
  }

  /// "c;BASE64" (any selection letters before the ';'): the text; nil for
  /// the "?" query or a payload that is not base64 UTF-8.
  static func clipboardText(_ data: [UInt8]) -> String? {
    guard let semi = data.firstIndex(of: UInt8(ascii: ";")) else { return nil }
    let b64 = String(decoding: data[(semi + 1)...], as: UTF8.self)
    guard b64 != "?", let raw = Data(base64Encoded: b64, options: .ignoreUnknownCharacters) else {
      return nil
    }
    return String(data: raw, encoding: .utf8)
  }

  public init(transport: Transport, rows: Int, cols: Int, history: Int) throws {
    terminal = try Terminal(rows: rows, cols: cols, history: history)
    self.transport = transport
    terminal.onOSC = { [weak self] id, data in self?.osc(id, data) }
  }

  #if os(macOS)
    /// A local process on a pty; argv[0] is what the child sees as its name.
    public convenience init(
      executable: String, argv: [String], environment: [String: String], directory: String?,
      rows: Int, cols: Int, history: Int
    ) throws {
      let pty = try PTYTransport(
        executable: executable, argv: argv, environment: environment, directory: directory,
        rows: rows, cols: cols)
      try self.init(transport: pty, rows: rows, cols: cols, history: history)
    }
  #endif

  /// Cmd+K: screen and history gone, the cursor's line kept at the top.
  public func clear() {
    lock.lock()
    terminal.clear()
    lock.unlock()
  }

  public func start() {
    transport.start(
      output: { [weak self] bytes in self?.received(bytes) },
      exit: { [weak self] status in
        guard let self else { return }
        self.lock.lock()
        self.exited = true
        self.lock.unlock()
        self.onExit?(status)
      })
  }

  private func received(_ bytes: [UInt8]) {
    var reply = [UInt8](repeating: 0, count: 4096)
    lock.lock()
    bytes.withUnsafeBytes { vt_write(term, $0.baseAddress, $0.count) }
    let r = reply.withUnsafeMutableBytes { vt_reply(term, $0.baseAddress, $0.count) }
    lock.unlock()
    if r > 0 {
      transport.send(Array(reply[0..<r]))  // the terminal's answers, never intercepted
    }
    onOutput?()
  }

  public func hangup() {
    transport.hangup()
  }

  public var hasExited: Bool {
    lock.lock()
    defer { lock.unlock() }
    return exited
  }

  /// While set, what the user types goes here instead of the host: the
  /// search in the status bar. Set and used on the main thread.
  public var intercept: (([UInt8]) -> Void)?

  public func send(_ bytes: [UInt8]) {
    if let i = intercept {
      i(bytes)
      return
    }
    transport.send(bytes)
  }

  public func send(_ text: String) {
    send(Array(text.utf8))
  }

  public func resize(rows: Int, cols: Int) {
    lock.lock()
    let ok = vt_resize(term, Int32(rows), Int32(cols)) == 0
    lock.unlock()
    if ok {
      transport.resize(rows: rows, cols: cols)
    }
  }

  /// Copies the screen into `screen`, reusing its storage.
  public func snapshot(into screen: inout Screen, back: Int = 0) {
    lock.lock()
    defer { lock.unlock() }
    terminal.snapshot(into: &screen, back: back)
    screen.generation &+= transport.overlayGeneration
    if back == 0 {
      transport.overlay(&screen)
    }
  }

  public func generation() -> UInt64 {
    lock.lock()
    defer { lock.unlock() }
    return vt_generation(term) &+ transport.overlayGeneration
  }

  public func history() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return Int(vt_history(term))
  }

  /// History plus screen: the address space of a selection.
  /// How many lines the history has dropped (a reflow counts them all): an
  /// address kept from before is now that much smaller.
  public func base() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return Int(vt_base(term))
  }

  public func lines() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return Int(vt_lines(term))
  }

  public func copyText(from start: (line: Int, col: Int), to end: (line: Int, col: Int)) -> String {
    lock.lock()
    defer { lock.unlock() }
    var r: Int32 = 0
    var c: Int32 = 0
    vt_size(term, &r, &c)
    let span = abs(end.line - start.line) + 1
    var out = [UInt8](repeating: 0, count: span * (Int(c) * 4 + 1))
    let n = out.withUnsafeMutableBufferPointer {
      vt_copy_text(
        term, Int32(start.line), Int32(start.col), Int32(end.line), Int32(end.col),
        $0.baseAddress, $0.count)
    }
    return String(decoding: out[0..<n], as: UTF8.self)
  }

  /// The query as the core compares it: composed, since the core composes
  /// what it shows (c + U+0327 is one ç cell), so a name pasted from the
  /// Finder in decomposed form finds the same text it printed.
  static func needle(_ text: String) -> [UInt32] {
    text.precomposedStringWithCanonicalMapping.unicodeScalars.map(\.value)
  }

  /// The match nearest `from` (exclusive) going back (older) or forward, in
  /// the address space of lines(); from nil starts at the far end.
  public func find(_ text: String, back: Bool, from: (line: Int, col: Int)?)
    -> (line: Int, col: Int, end: Int)?
  {
    let needle = Session.needle(text)
    lock.lock()
    defer { lock.unlock() }
    var line = Int32(from?.line ?? (back ? Int(vt_lines(term)) : -1))
    var col = Int32(from?.col ?? 0)
    var end: Int32 = 0
    let hit = needle.withUnsafeBufferPointer {
      vt_find(term, $0.baseAddress, Int32($0.count), back ? 1 : 0, &line, &col, &end)
    }
    return hit == 1 ? (Int(line), Int(col), Int(end)) : nil
  }

  /// Every match from `from` (exclusive; nil: the far end) on, oldest first
  /// going forward and newest first going back, at most `limit`: the needle
  /// is prepared once and the core is locked once for the whole pass.
  public func findAll(_ text: String, back: Bool, from: (line: Int, col: Int)?, limit: Int)
    -> [(line: Int, col: Int, end: Int)]
  {
    let needle = Session.needle(text)
    guard !needle.isEmpty, limit > 0 else { return [] }
    lock.lock()
    defer { lock.unlock() }
    var line = Int32(from?.line ?? (back ? Int(vt_lines(term)) : -1))
    var col = Int32(from?.col ?? 0)
    var end: Int32 = 0
    var out: [(line: Int, col: Int, end: Int)] = []
    needle.withUnsafeBufferPointer { p in
      while out.count < limit,
        vt_find(term, p.baseAddress, Int32(p.count), back ? 1 : 0, &line, &col, &end) == 1
      {
        out.append((Int(line), Int(col), Int(end)))
      }
    }
    return out
  }

  /// The nearest prompt (OSC 133;A) before or after `line`, in the address
  /// space of lines().
  /// Whether autowrap joined `line` to the next: both are one line of text.
  public func wrapped(_ line: Int) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return vt_wrapped(term, Int32(line)) != 0
  }

  public func prompt(from line: Int, back: Bool) -> Int? {
    lock.lock()
    defer { lock.unlock() }
    let l = Int(vt_prompt(term, Int32(line), back ? 1 : 0))
    return l < 0 ? nil : l
  }

  /// A cell's hyperlink (OSC 8), when it is safe to hand to the system.
  /// The remote program picks the URI, so only web and mail links open:
  /// file: or an app's scheme could run something local on a click.
  public func link(_ id: UInt8) -> URL? {
    guard id != 0 else { return nil }
    lock.lock()
    let raw = vt_link(term, Int32(id)).map { String(cString: $0) }
    lock.unlock()
    guard let raw, let url = URL(string: raw),
      ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
    else {
      return nil
    }
    return url
  }

  /// What the status bar tells about this session: the directory (from
  /// OSC 7, else the foreground process's), whether it is on this machine,
  /// and the title (set by the program, else the process name).
  public func status() -> (directory: String?, local: Bool, title: String, label: String?) {
    lock.lock()
    let reported = String(cString: vt_cwd(term))
    var title = String(cString: vt_title(term))
    lock.unlock()
    let fg = transport.foreground()
    if title.isEmpty {
      title = fg.name ?? ""
    }
    if let url = URL(string: reported), url.scheme == "file", !url.path.isEmpty {
      return (url.path, Session.isLocal(url.host ?? ""), title, transport.label)
    }
    return (fg.cwd, fg.cwd != nil, title, transport.label)
  }

  static func isLocal(_ host: String) -> Bool {
    var buf = [CChar](repeating: 0, count: 256)
    gethostname(&buf, buf.count)
    let name = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let me = name.split(separator: ".").first.map(String.init) ?? ""
    let short = host.split(separator: ".").first.map(String.init) ?? ""
    return host.isEmpty || host == "localhost" || short.lowercased() == me.lowercased()
  }

  public func title() -> String {
    lock.lock()
    defer { lock.unlock() }
    return String(cString: vt_title(term))
  }

  public func configure(color slot: Int, rgb: UInt32) {
    lock.lock()
    vt_config_color(term, Int32(slot), rgb)
    lock.unlock()
  }

  /// Runs an input encoder against the current modes and sends its bytes.
  public func input(_ encode: (OpaquePointer, UnsafeMutablePointer<UInt8>) -> Int) {
    let bytes = encoded(encode)
    if !bytes.isEmpty {
      send(bytes)
    }
  }

  private func encoded(_ encode: (OpaquePointer, UnsafeMutablePointer<UInt8>) -> Int) -> [UInt8] {
    var out = [UInt8](repeating: 0, count: Int(VT_INPUT_MAX))
    lock.lock()
    let n = out.withUnsafeMutableBufferPointer { encode(term, $0.baseAddress!) }
    lock.unlock()
    return Array(out[0..<max(0, n)])
  }

  /// The window came to the front or left it: programs that asked (mode
  /// 1004, vim and tmux's focus-events) hear about it. An event for the
  /// program, not a key: it never goes to the search or the copy mode.
  public func focus(_ on: Bool) {
    let bytes = encoded { vt_focus($0, on ? 1 : 0, $1) }
    if !bytes.isEmpty {
      transport.send(bytes)
    }
  }

  public func size() -> (rows: Int, cols: Int) {
    lock.lock()
    defer { lock.unlock() }
    var r: Int32 = 0
    var c: Int32 = 0
    vt_size(term, &r, &c)
    return (Int(r), Int(c))
  }

  public func paste(_ text: String) {
    let bytes = Array(text.utf8)
    if let i = intercept {  // the search wants the text, not the host's bracketed form
      i(bytes)
      return
    }
    var out = [UInt8](repeating: 0, count: bytes.count + 12)
    lock.lock()
    let n = out.withUnsafeMutableBufferPointer { o in
      bytes.withUnsafeBufferPointer { vt_paste(term, $0.baseAddress, bytes.count, o.baseAddress) }
    }
    lock.unlock()
    send(Array(out[0..<n]))
  }
}
