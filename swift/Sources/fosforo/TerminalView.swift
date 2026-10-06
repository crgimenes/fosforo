#if os(macOS)
  import AppKit
  import CFosforo
  import FosforoCore
  import FosforoRender
  import Metal
  import QuartzCore

  /// The window's content: a CAMetalLayer the renderer draws the session into,
  /// and the keyboard/mouse path back to the child.
  @MainActor
  final class TerminalView: NSView, @preconcurrency NSTextInputClient {
    let session: Session
    let renderer: Renderer
    /// Frame, scrolling, selection and search, shared with the iOS view.
    private let vp: Viewport
    private var screen: Screen { vp.screen }
    private var dirty: Bool {
      get { vp.dirty }
      set { vp.dirty = newValue }
    }
    private var scrollBack: Int { vp.scrollBack }
    private var scrollRemainder = 0.0
    private var marked = NSAttributedString() {
      didSet { dirty = true }
    }
    private var caret = vt_cursor()  // where composition starts, for the candidate window
    private var syncSince: Date?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private var link: CADisplayLink?
    private var blink: Timer?
    var onExit: (() -> Void)?
    var onTitle: ((String) -> Void)?
    /// A two-finger horizontal swipe: the next session (true) or the previous.
    var onSwipe: ((Bool) -> Void)?
    private var title = ""
    private let statusBar = StatusBar()
    /// Which of the window's sessions this is, for the status bar.
    var position = (index: 1, count: 1) {
      didSet { dirty = true }
    }

    init(session: Session, renderer: Renderer) {
      self.session = session
      self.renderer = renderer
      vp = Viewport(session: session)
      defaultFontSize = renderer.theme.fontSize
      super.init(frame: .zero)
      vp.onCopy = { text in
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
      }
      wantsLayer = true
      layerContentsRedrawPolicy = .never
      renderer.statusBar = renderer.theme.statusBar
      registerForDraggedTypes([.fileURL])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    /// Files dropped on the terminal: their paths, quoted for the shell, as
    /// if pasted.
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
      let urls =
        sender.draggingPasteboard.readObjects(
          forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
      guard !urls.isEmpty else { return false }
      session.paste(urls.map { Shell.quoted($0.path) }.joined(separator: " "))
      return true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no coder") }

    override func makeBackingLayer() -> CALayer {
      let l = CAMetalLayer()
      l.device = renderer.device
      l.pixelFormat = .bgra8Unorm
      l.framebufferOnly = true
      l.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
      return l
    }

    override func viewDidUnhide() {
      super.viewDidUnhide()
      dirty = true
      link?.isPaused = false  // even if dirty already was: no transition to wake it
    }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    func start() {
      let link = displayLink(target: self, selector: #selector(tick))
      link.add(to: .main, forMode: .common)
      self.link = link
      // the link sleeps when nothing changed (tick pauses it) and wakes on
      // anything to draw or any output; nothing else ticks a quiet window
      vp.onDirty = { [weak self] in self?.link?.isPaused = false }
      session.onOutput = { [weak self] in
        DispatchQueue.main.async { self?.link?.isPaused = false }
      }
      blink = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.renderer.blink()
          self.dirty = true
        }
      }
      session.onExit = { [weak self] _ in
        DispatchQueue.main.async { self?.onExit?() }
      }
      session.onBell = { [weak self] in
        DispatchQueue.main.async { self?.bell() }
      }
      session.onNotify = { [weak self] text in
        DispatchQueue.main.async { self?.notify(text) }
      }
      session.onPrompt = { Hooks.fire("prompt") }
      session.clipboardAllowed = renderer.theme.clipboard != "deny"
      session.onClipboard = { [weak self] text in
        DispatchQueue.main.async {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
          self?.notice("clipboard ← program")  // a program changed it: never in silence
        }
      }
      session.start()
    }

    /// A word on the status bar for a few seconds.
    private var noticeUntil = (text: "", until: Date.distantPast)
    private var currentNotice: String? {
      Date() < noticeUntil.until ? noticeUntil.text : nil
    }

    private func notice(_ text: String) {
      noticeUntil = (text, Date().addingTimeInterval(4))
      dirty = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 4.05) { [weak self] in self?.dirty = true }
    }

    /// BEL as the config says: a flash of the frame, the system's alert, or
    /// nothing.
    private func bell() {
      Hooks.fire("bell")
      switch renderer.theme.bell {
      case "sound":
        NSSound.beep()
      case "none":
        break
      default:
        renderer.flash()
        dirty = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Renderer.flashLength + 0.02) {
          [weak self] in self?.dirty = true
        }
      }
    }

    /// Names this session to a notification, so a click on it comes back here.
    let id = UUID()

    /// OSC 9/777 from a program (a build that ended): a notification, when
    /// this session is not the one being looked at (another app, another
    /// window, or another session of this window in front).
    private func notify(_ text: String) {
      Hooks.fire("notify", text)
      guard !NSApp.isActive || !(window?.isKeyWindow ?? false) || isHidden else { return }
      AppDelegate.post(text, session: id)
    }

    /// Cmd+K: screen and history gone, the prompt line kept at the top.
    @objc func clearBuffer(_ sender: Any?) {
      session.clear()
      vp.scroll(by: 0)
    }

    /// The display link and the timer hold the view; without this the window
    /// would close and leave the shell running behind it.
    func stop() {
      link?.invalidate()
      link = nil
      blink?.invalidate()
      blink = nil
      session.hangup()
    }

    // MARK: - layout

    override func viewDidChangeBackingProperties() {
      super.viewDidChangeBackingProperties()
      if let s = window?.backingScaleFactor {
        try? renderer.setScale(Double(s))
      }
      layoutGrid()
    }

    override func setFrameSize(_ size: NSSize) {
      super.setFrameSize(size)
      layoutGrid()
    }

    /// The size last given to the session: the screen it is compared with
    /// comes back a tick later, too late for a resize that undoes another.
    private var asked = (rows: 0, cols: 0)

    private var defaultFontSize: Double

    /// A config read again: font, colors, status bar. Rows, Cols and
    /// History belong to a new window.
    func apply(_ theme: Theme) {
      renderer.theme = theme
      renderer.statusBar = theme.statusBar
      session.clipboardAllowed = theme.clipboard != "deny"
      defaultFontSize = theme.fontSize
      fontSize(theme.fontSize)
      theme.apply { session.configure(color: $0, rgb: $1) }
      dirty = true
    }

    @objc func biggerFont(_ sender: Any?) { fontSize(renderer.theme.fontSize + fontStep) }
    @objc func smallerFont(_ sender: Any?) { fontSize(renderer.theme.fontSize - fontStep) }
    /// About a tenth: one point at 18 hardly shows, and the first press seems lost.
    private var fontStep: Double { max(1, (renderer.theme.fontSize / 10).rounded()) }
    @objc func defaultFont(_ sender: Any?) { fontSize(defaultFontSize) }

    private var pinch = 0.0

    /// A pinch on the trackpad is Cmd +/- in steps, as in iTerm2: the font
    /// changes, not the picture (the iPad zooms the picture).
    override func magnify(with event: NSEvent) {
      if event.phase == .began {
        pinch = 0
      }
      pinch += event.magnification
      while pinch >= 0.1 {
        pinch -= 0.1
        biggerFont(nil)
      }
      while pinch <= -0.1 {
        pinch += 0.1
        smallerFont(nil)
      }
    }

    /// Cmd +/-: the window keeps its size, the grid gets more or fewer rows.
    private func fontSize(_ size: Double) {
      guard (6...80).contains(size), (try? renderer.setFontSize(size)) != nil else { return }
      let scale = window?.backingScaleFactor ?? 2
      window?.contentResizeIncrements = NSSize(
        width: CGFloat(renderer.metrics.width) / scale,
        height: CGFloat(renderer.metrics.height) / scale)
      layoutGrid()
    }

    private func layoutGrid() {
      let scale = window?.backingScaleFactor ?? 2
      metalLayer.contentsScale = scale
      let w = Int(bounds.width * scale)
      let h = Int(bounds.height * scale)
      guard w > 0, h > 0 else { return }
      metalLayer.drawableSize = CGSize(width: w, height: h)
      let (rows, cols) = renderer.gridSize(width: w, height: h)
      if rows != asked.rows || cols != asked.cols {
        asked = (rows, cols)
        // dragging the window edge is a resize every few pixels, and each
        // one reflows the whole history (100k lines: ~100 ms): with a deep
        // one, the grid follows a few times a second and settles at the end
        if inLiveResize && session.lines() > TerminalView.reflowEagerly {
          if reflowTimer == nil {
            let timer = Timer(timeInterval: 0.1, repeats: false) { [weak self] _ in
              MainActor.assumeIsolated { self?.reflowNow() }
            }
            // the drag keeps the run loop in event tracking, where default-mode timers wait
            RunLoop.main.add(timer, forMode: .common)
            reflowTimer = timer
          }
        } else {
          session.resize(rows: rows, cols: cols)
        }
      }
      dirty = true
    }

    /// Lines (history and screen) past which a live resize reflows a few
    /// times a second instead of at every pixel.
    static let reflowEagerly = 5000
    private var reflowTimer: Timer?

    private func reflowNow() {
      reflowTimer?.invalidate()
      reflowTimer = nil
      session.resize(rows: asked.rows, cols: asked.cols)
      dirty = true
    }

    override func viewDidEndLiveResize() {
      super.viewDidEndLiveResize()
      if reflowTimer != nil {
        reflowNow()
      }
    }

    // MARK: - drawing

    @objc private func tick() {
      guard !isHidden else {  // another session of the window is showing
        link?.isPaused = true
        return
      }
      vp.beforeFrame()
      guard dirty else {
        link?.isPaused = true  // until something marks the view dirty, or output comes
        return
      }
      session.snapshot(into: &vp.screen, back: scrollBack)
      // DEC mode 2026: the app is mid-update; hold the last frame (at most 1 s)
      if screen.modes & UInt32(VT_MODE_SYNC_OUTPUT) != 0 {
        let since = syncSince ?? Date()
        syncSince = since
        if Date().timeIntervalSince(since) < 1 {
          return
        }
      }
      syncSince = nil
      caret = screen.cursor
      if scrollBack == 0 && marked.length > 0 {
        vp.screen.compose(marked.string)
      }
      let t = session.title()
      if t != title {
        title = t
        onTitle?(t)
        Hooks.fire("title", t)
      }
      guard let drawable = metalLayer.nextDrawable(), let cb = renderer.makeCommandBuffer() else {
        return
      }
      renderer.selection = vp.visibleSelection()
      renderer.matches = vp.visibleMatches()
      renderer.mark = vp.visibleMark()
      if renderer.statusBar {
        renderer.status = statusBar.cells(
          session, position: position, cols: screen.cols, rows: screen.rows,
          finder: vp.finding ? vp.finder : nil, copying: vp.copying, notice: currentNotice,
          background: StatusLine.rgb(renderer.theme.statusBackground))
      }
      renderer.encode(
        screen, into: drawable.texture, commandBuffer: cb,
        cursorVisible: scrollBack == 0 && !vp.copying && !reportedDrag)
      cb.present(drawable)
      cb.commit()
      dirty = false
    }

    // MARK: - keyboard

    private static let special: [Int: Int32] = [
      NSUpArrowFunctionKey: Int32(VT_KEY_UP), NSDownArrowFunctionKey: Int32(VT_KEY_DOWN),
      NSRightArrowFunctionKey: Int32(VT_KEY_RIGHT), NSLeftArrowFunctionKey: Int32(VT_KEY_LEFT),
      NSHomeFunctionKey: Int32(VT_KEY_HOME), NSEndFunctionKey: Int32(VT_KEY_END),
      NSInsertFunctionKey: Int32(VT_KEY_INSERT), NSDeleteFunctionKey: Int32(VT_KEY_DELETE),
      NSPageUpFunctionKey: Int32(VT_KEY_PAGE_UP), NSPageDownFunctionKey: Int32(VT_KEY_PAGE_DOWN),
      0x0D: Int32(VT_KEY_ENTER), 0x03: Int32(VT_KEY_KP_ENTER), 0x09: Int32(VT_KEY_TAB),
      0x19: Int32(VT_KEY_TAB), 0x7F: Int32(VT_KEY_BACKSPACE), 0x1B: Int32(VT_KEY_ESCAPE),
    ]

    private func mods(_ flags: NSEvent.ModifierFlags) -> UInt32 {
      var m: UInt32 = 0
      if flags.contains(.shift) { m |= UInt32(VT_MOD_SHIFT) }
      if flags.contains(.control) { m |= UInt32(VT_MOD_CTRL) }
      return m
    }

    override func keyDown(with event: NSEvent) {
      renderer.typed()
      vp.live()
      let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
      let m = mods(flags)
      if let chars = event.charactersIgnoringModifiers?.unicodeScalars, chars.count == 1,
        !hasMarkedText()
      {
        let v = Int(chars.first!.value)
        var key = TerminalView.special[v]
        if key == nil && v >= NSF1FunctionKey && v <= NSF12FunctionKey {
          key = Int32(VT_KEY_F1) + Int32(v - NSF1FunctionKey)
        }
        if let key, flags.contains(.option), renderer.theme.optionArrows == "word",
          let word = Keys.optionWord(key)
        {
          session.send(word)  // ⌥← ⌥→ ⌥⌫: by the word, as Terminal.app sends them
          return
        }
        if let key {
          let km = flags.contains(.option) ? m | UInt32(VT_MOD_ALT) : m
          session.input { t, out in vt_key(t, key, km, out) }
          return
        }
        if flags.contains(.control) {
          session.input { t, out in vt_text(t, UInt32(v), m, out) }
          return
        }
      }
      // Option composes characters (iTerm2 "Option sends: Normal") and dead
      // keys (´ then e) go through the input method.
      interpretKeyEvents([event])
    }

    override func doCommand(by selector: Selector) {}

    func insertText(_ string: Any, replacementRange: NSRange) {
      let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
      marked = NSAttributedString()
      if !s.isEmpty {
        session.send(s)
      }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
      marked =
        (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
    }

    func unmarkText() { marked = NSAttributedString() }
    func selectedRange() -> NSRange { NSRange(location: NSNotFound, length: 0) }
    func markedRange() -> NSRange {
      marked.length > 0
        ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0)
    }
    func hasMarkedText() -> Bool { marked.length > 0 }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?)
      -> NSAttributedString?
    { nil }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Where the input method pops its candidate window: under the cursor.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
      let scale = window?.backingScaleFactor ?? 2
      let x = CGFloat(Int(caret.col) * renderer.metrics.width) / scale
      let y = CGFloat(Int(caret.row + 1) * renderer.metrics.height) / scale
      let local = NSRect(x: x, y: y, width: 1, height: CGFloat(renderer.metrics.height) / scale)
      return window?.convertToScreen(convert(local, to: nil)) ?? .zero
    }

    @objc func paste(_ sender: Any?) {
      if let s = NSPasteboard.general.string(forType: .string) {
        session.paste(s)
      }
    }

    // MARK: - find and prompts: the viewport's, reached from the menu
    // (Cmd+F, Cmd+G, Shift+Cmd+G, Cmd+Up, Cmd+Down)

    @objc func find(_ sender: Any?) { vp.find() }
    @objc func copyMode(_ sender: Any?) { vp.enterCopyMode() }
    @objc func findNext(_ sender: Any?) { step(back: true) }
    @objc func findPrevious(_ sender: Any?) { step(back: false) }
    @objc func previousPrompt(_ sender: Any?) { vp.jumpPrompt(back: true) }
    @objc func nextPrompt(_ sender: Any?) { vp.jumpPrompt(back: false) }

    private func step(back: Bool) {
      if !vp.step(back: back) {
        NSSound.beep()
      }
    }

    // MARK: - mouse: to the application when it asked, else local

    private var lastMotion = (row: -1, col: -1)
    /// A drag handed to the program (tmux selecting): no cursor, as in our
    /// own selection; a block over its reverse-video end undid the highlight.
    private var reportedDrag = false {
      didSet { dirty = true }
    }

    private func startSelection(_ event: NSEvent) {
      let at = cell(at: event)
      switch event.clickCount {
      case 2: vp.selectWord(at: at)
      case 3...: vp.selectLine(at: at)
      default: vp.anchorSelection(at: at)
      }
    }

    private func finishSelection(_ event: NSEvent) {
      if event.clickCount == 1 && vp.selectsOneCell {
        vp.clearSelection()
        return
      }
      copy(nil)
    }

    /// Copy on select (iTerm2's default), and Cmd+C.
    @objc func copy(_ sender: Any?) {
      guard let text = vp.selectedText() else { return }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(text, forType: .string)
    }

    private var tracking: Bool {
      let bits = VT_MODE_MOUSE_X10 | VT_MODE_MOUSE_BUTTON | VT_MODE_MOUSE_DRAG | VT_MODE_MOUSE_ANY
      return screen.modes & UInt32(bits) != 0
    }

    /// The column of a click on the status bar, nil when it is on the grid.
    private func statusColumn(_ event: NSEvent) -> Int? {
      let p = convert(event.locationInWindow, from: nil)
      let scale = window?.backingScaleFactor ?? 2
      guard renderer.statusBar, Int(p.y * scale) / renderer.metrics.height >= screen.rows else {
        return nil
      }
      return Int(p.x * scale) / renderer.metrics.width
    }

    private func cell(at event: NSEvent) -> (row: Int, col: Int) {
      let p = convert(event.locationInWindow, from: nil)
      let scale = window?.backingScaleFactor ?? 2
      let col = Int(p.x * scale) / renderer.metrics.width
      let row = Int(p.y * scale) / renderer.metrics.height
      return (max(0, min(screen.rows - 1, row)), max(0, min(screen.cols - 1, col)))
    }

    /// Sends the event when the application tracks the mouse; Shift keeps it
    /// local (selection), as in xterm and iTerm2.
    @discardableResult
    private func report(_ kind: Int32, _ button: Int32, _ event: NSEvent) -> Bool {
      guard tracking, !event.modifierFlags.contains(.shift) else {
        return false
      }
      let at = cell(at: event)
      if kind == Int32(VT_MOUSE_MOTION) {
        if at == lastMotion {
          return true
        }
        lastMotion = at
      }
      var m: UInt32 = 0
      if event.modifierFlags.contains(.option) { m |= UInt32(VT_MOD_ALT) }
      if event.modifierFlags.contains(.control) { m |= UInt32(VT_MOD_CTRL) }
      let mods = m
      session.input { t, out in
        vt_mouse(t, kind, button, Int32(at.row), Int32(at.col), mods, out)
      }
      return true
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      for area in trackingAreas {
        removeTrackingArea(area)
      }
      addTrackingArea(
        NSTrackingArea(
          rect: .zero,
          options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
          owner: self))
    }

    override func mouseDown(with event: NSEvent) {
      if let col = statusColumn(event) {
        if vp.finding && !vp.apply(statusBar.action(at: col)) {
          NSSound.beep()
        }
        return
      }
      if vp.finding && vp.finder.editing {
        vp.focusField(false)
      }
      if event.modifierFlags.contains(.command) {
        let at = cell(at: event)
        if let url = session.link(screen.cell(at.row, at.col).link) {
          NSWorkspace.shared.open(url)
        }
        return
      }
      if !report(Int32(VT_MOUSE_PRESS), Int32(VT_BUTTON_LEFT), event) {
        startSelection(event)
      }
    }
    override func mouseUp(with event: NSEvent) {
      autoscroll(0)
      reportedDrag = false
      if !report(Int32(VT_MOUSE_RELEASE), Int32(VT_BUTTON_LEFT), event) {
        finishSelection(event)
      }
    }
    override func mouseDragged(with event: NSEvent) {
      if report(Int32(VT_MOUSE_MOTION), Int32(VT_BUTTON_LEFT), event) {
        reportedDrag = true
        return
      }
      let at = cell(at: event)
      dragCol = at.col
      let p = convert(event.locationInWindow, from: nil)
      autoscroll(p.y < 0 ? 1 : (p.y > bounds.height ? -1 : 0))
      if autoscrolling == nil {
        vp.extendSelection(to: at)
      }
    }

    private var autoscrolling: Timer?
    private var dragCol = 0

    /// Dragging past the top or the bottom scrolls that way while the
    /// selection follows, as editors do: direction 1 is older, -1 newer,
    /// 0 stops.
    private func autoscroll(_ direction: Int) {
      autoscrolling?.invalidate()
      autoscrolling = nil
      guard direction != 0 else { return }
      autoscrolling = Timer.scheduledTimer(withTimeInterval: 0.04, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self else { return }
          self.vp.scroll(by: direction)
          self.vp.extendSelection(to: (direction > 0 ? 0 : self.screen.rows - 1, self.dragCol))
        }
      }
    }
    override func rightMouseDown(with event: NSEvent) {
      report(Int32(VT_MOUSE_PRESS), Int32(VT_BUTTON_RIGHT), event)
    }
    override func rightMouseUp(with event: NSEvent) {
      report(Int32(VT_MOUSE_RELEASE), Int32(VT_BUTTON_RIGHT), event)
    }
    override func rightMouseDragged(with event: NSEvent) {
      report(Int32(VT_MOUSE_MOTION), Int32(VT_BUTTON_RIGHT), event)
    }
    override func otherMouseDown(with event: NSEvent) {
      report(Int32(VT_MOUSE_PRESS), Int32(VT_BUTTON_MIDDLE), event)
    }
    override func otherMouseUp(with event: NSEvent) {
      report(Int32(VT_MOUSE_RELEASE), Int32(VT_BUTTON_MIDDLE), event)
    }
    override func otherMouseDragged(with event: NSEvent) {
      report(Int32(VT_MOUSE_MOTION), Int32(VT_BUTTON_MIDDLE), event)
    }
    override func mouseMoved(with event: NSEvent) {
      report(Int32(VT_MOUSE_MOTION), Int32(VT_BUTTON_NONE), event)
      let at = cell(at: event)
      let link = screen.cell(at.row, at.col).link
      hover(session.link(link) == nil ? 0 : link)
    }

    override func mouseExited(with event: NSEvent) {
      hover(0)
    }

    /// Only links that would open are shown as such (and get the hand).
    private func hover(_ link: UInt8) {
      guard link != renderer.hoverLink else { return }
      renderer.hoverLink = link
      (link == 0 ? NSCursor.iBeam : NSCursor.pointingHand).set()
      dirty = true
    }

    /// Wheel: to a tracking application as wheel buttons; on the alternate
    /// screen of one that does not track (less, man) as arrow keys; otherwise
    /// through the scrollback.
    private var swipeX = 0.0
    private var swiped = false
    private var sideways: Bool?  // the gesture's axis, fixed by its first movement
    private var began = false  // the gesture started on this session
    static let swipeDistance = 80.0  // points of a trackpad gesture that make a switch

    /// Two fingers sideways on a trackpad switch sessions, once per gesture,
    /// as iTerm2 does with tabs; up and down scroll as ever.
    private func swipe(_ event: NSEvent) -> Bool {
      guard event.hasPreciseScrollingDeltas else { return false }
      if event.phase == .began {
        swipeX = 0
        swiped = false
        sideways = nil
        began = true
      }
      if event.momentumPhase != [] {
        return sideways == true  // the glide after a sideways gesture
      }
      // the rest of a gesture that switched to this session is not ours
      guard began || event.phase == [] else { return true }
      if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
        began = false
      }
      if sideways == nil && (event.scrollingDeltaX != 0 || event.scrollingDeltaY != 0) {
        sideways = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
      }
      guard sideways == true else { return false }
      swipeX += event.scrollingDeltaX * (event.isDirectionInvertedFromDevice ? 1 : -1)
      if !swiped && abs(swipeX) > TerminalView.swipeDistance {
        swiped = true
        onSwipe?(swipeX < 0)  // fingers to the left: the next session, like pages
      }
      return true
    }

    override func scrollWheel(with event: NSEvent) {
      if swipe(event) {
        return
      }
      scrollRemainder += event.scrollingDeltaY / (event.hasPreciseScrollingDeltas ? 16 : 1)
      let lines = Int(scrollRemainder)
      guard lines != 0 else { return }
      scrollRemainder -= Double(lines)
      let up = lines > 0
      if tracking && !event.modifierFlags.contains(.shift) {
        let button = Int32(up ? VT_BUTTON_WHEEL_UP : VT_BUTTON_WHEEL_DOWN)
        for _ in 0..<abs(lines) {
          report(Int32(VT_MOUSE_PRESS), button, event)
        }
        return
      }
      if screen.modes & UInt32(VT_MODE_ALT_SCREEN) != 0 {
        let key = Int32(up ? VT_KEY_UP : VT_KEY_DOWN)
        for _ in 0..<abs(lines) {
          session.input { t, out in vt_key(t, key, 0, out) }
        }
        return
      }
      vp.scroll(by: lines)
    }
  }
#endif
