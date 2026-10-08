#if os(iOS)
  import CFosforo
  import FosforoCore
  import FosforoRender
  import Metal
  import QuartzCore
  import AudioToolbox
  import GameController
  import UIKit

  /// The terminal on iOS: the same renderer as the Mac, keys from the
  /// on-screen keyboard (UIKeyInput) and from a hardware one (presses).
  @MainActor
  final class TerminalView: UIView, UITextInput {
    let session: Session
    private let renderer: Renderer
    private let statusBar = StatusBar()
    /// Which of the window's sessions this is, for the status bar.
    var position = (index: 1, count: 1) {
      didSet { dirty = true }
    }
    override var isHidden: Bool {
      didSet {
        dirty = true
        link?.isPaused = isHidden  // shown again: the link wakes even if dirty already was
      }
    }
    /// Frame, scrolling, selection and search, shared with the Mac view.
    private let vp: Viewport
    private var screen: Screen { vp.screen }
    private var dirty: Bool {
      get { vp.dirty }
      set { vp.dirty = newValue }
    }
    private var scrollBack: Int { vp.scrollBack }
    private var syncSince: Date?  // DEC 2026: since when the app asked to hold the frame
    private var title = ""
    private var link: CADisplayLink?
    private var blink: Timer?
    /// Its bottom follows the keyboard's top (or the safe area when there
    /// is none), as UIKit keeps it in this view's own coordinates: right in
    /// a resized iPad window too, where a frame from the keyboard
    /// notification measured once goes stale.
    private let keyboardTop = UIView()
    fileprivate var marked = "" {  // what an input method is composing, not yet sent
      didSet { dirty = true }
    }
    private var caret = vt_cursor()  // where composition starts, for the candidate window
    weak var inputDelegate: UITextInputDelegate?
    lazy var tokenizer: UITextInputTokenizer = UITextInputStringTokenizer(textInput: self)
    private var panCarry: CGFloat = 0
    private var coastSpeed: CGFloat = 0  // points a second, after a flick
    private var coastLink: CADisplayLink?
    private var sideways = false  // the drag's axis, fixed when it starts
    private var swipeX: CGFloat = 0
    static let swipeDistance: CGFloat = 60
    var onExit: (() -> Void)?
    /// A sideways swipe: the next session (true) or the previous.
    var onSwipe: ((Bool) -> Void)?
    private var ctrlLatched = false
    private var repeatTimer: Timer?
    private var repeating: UIKeyboardHIDUsage?
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    override class var layerClass: AnyClass { CAMetalLayer.self }

    init(session: Session, renderer: Renderer) {
      self.session = session
      self.renderer = renderer
      vp = Viewport(session: session)
      defaultFontSize = renderer.theme.fontSize
      super.init(frame: .zero)
      vp.onCopy = { UIPasteboard.general.string = $0 }
      renderer.statusBar = renderer.theme.statusBar
      metalLayer.device = renderer.device
      metalLayer.pixelFormat = .bgra8Unorm
      metalLayer.framebufferOnly = true
      backgroundColor = .black
      let finger = [UITouch.TouchType.direct, .pencil].map { NSNumber(value: $0.rawValue) }
      let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
      tap.allowedTouchTypes = finger
      addGestureRecognizer(tap)
      // a pointer's double click takes the word and a triple the line, as
      // in editors; its single click waits to see which it is
      let pointer = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
      let click = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
      let double = UITapGestureRecognizer(target: self, action: #selector(doubleClicked(_:)))
      let triple = UITapGestureRecognizer(target: self, action: #selector(tripleClicked(_:)))
      for (g, taps) in [(click, 1), (double, 2), (triple, 3)] {
        g.numberOfTapsRequired = taps
        g.allowedTouchTypes = pointer
        addGestureRecognizer(g)
      }
      click.require(toFail: double)
      double.require(toFail: triple)
      let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
      pan.maximumNumberOfTouches = 1  // two fingers pinch
      pan.allowedTouchTypes = finger
      pan.allowedScrollTypesMask = .all  // a trackpad's two-finger scroll
      addGestureRecognizer(pan)
      // a pointer's click and drag selects, as on the Mac
      let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
      drag.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
      addGestureRecognizer(drag)
      addGestureRecognizer(UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:))))
      let press = UILongPressGestureRecognizer(target: self, action: #selector(pressed(_:)))
      press.allowedTouchTypes = finger
      addGestureRecognizer(press)
      let secondary = UITapGestureRecognizer(target: self, action: #selector(menuClick(_:)))
      secondary.buttonMaskRequired = .secondary  // a right click: the touch menu
      addGestureRecognizer(secondary)
      addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
      addInteraction(editMenu)
      // the text system's undo/redo/paste strip means nothing in a terminal
      inputAssistantItem.leadingBarButtonGroups = []
      inputAssistantItem.trailingBarButtonGroups = []
      keyboardTop.isHidden = true
      keyboardTop.translatesAutoresizingMaskIntoConstraints = false
      addSubview(keyboardTop)
      NSLayoutConstraint.activate([
        keyboardTop.topAnchor.constraint(equalTo: topAnchor),
        keyboardTop.leadingAnchor.constraint(equalTo: leadingAnchor),
        keyboardTop.widthAnchor.constraint(equalToConstant: 1),
        keyboardTop.bottomAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
      ])
      for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect] {
        NotificationCenter.default.addObserver(
          self, selector: #selector(keyboardsChanged(_:)), name: name, object: nil)
      }
      let twoFingers = UITapGestureRecognizer(target: self, action: #selector(twoFingerTap))
      twoFingers.numberOfTouchesRequired = 2
      addGestureRecognizer(twoFingers)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no coder") }

    /// The display link and the timer hold the view: without this a closed
    /// session would keep drawing, and its connection open.
    func stop() {
      stopCoasting()
      link?.invalidate()
      link = nil
      blink?.invalidate()
      blink = nil
      session.hangup()
    }

    func start() {
      guard link == nil else { return }
      let l = CADisplayLink(target: self, selector: #selector(tick))
      l.add(to: .main, forMode: .common)
      link = l
      // the link sleeps when nothing changed (tick pauses it) and wakes on
      // anything to draw or any output: a quiet session costs the battery nothing
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
          UIPasteboard.general.string = text
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

    /// OSC 9/777 from a program (a build that ended): a notification, when
    /// this window is not the one being looked at.
    /// Names this session to a notification, so a tap on it comes back here.
    let id = UUID()

    private func notify(_ text: String) {
      Hooks.fire("notify", text)
      guard window?.windowScene?.activationState != .foregroundActive || isHidden else { return }
      AppDelegate.post(text, session: id)
    }

    /// BEL as the config says: a flash of the frame, a short sound, or
    /// nothing.
    private func bell() {
      Hooks.fire("bell")
      switch renderer.theme.bell {
      case "sound":
        AudioServicesPlaySystemSound(1057)
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

    /// Cmd+K: screen and history gone, the prompt line kept at the top.
    @objc func clearBuffer() {
      session.clear()
      vp.scroll(by: 0)
    }

    /// Dragging moves through the scrollback; on the alternate screen of a
    /// program that has one (less, man, vim) it sends arrows instead, as the
    /// wheel does on the Mac.
    @objc private func panned(_ g: UIPanGestureRecognizer) {
      if g.state == .began {
        stopCoasting()
        let v = g.velocity(in: self)
        sideways = abs(v.x) > abs(v.y)
        swipeX = 0
      }
      if sideways {
        // a sideways drag switches sessions once it ends far enough over
        swipeX += g.translation(in: self).x
        g.setTranslation(.zero, in: self)
        if g.state == .ended && abs(swipeX) > TerminalView.swipeDistance {
          onSwipe?(swipeX < 0)  // to the left: the next session, like pages
        }
        return
      }
      move(by: g.translation(in: self).y)
      g.setTranslation(.zero, in: self)
      if g.state == .ended {
        coast(from: g.velocity(in: self).y)
      }
    }

    /// A finger's travel in points, as lines: the screen of a program that
    /// owns it (less, vim) gets arrows, the shell's history scrolls.
    private func move(by points: CGFloat) {
      let scale = window?.screen.scale ?? UIScreen.main.scale
      panCarry += points / (CGFloat(renderer.metrics.height) / scale)
      let lines = Int(panCarry)
      guard lines != 0 else { return }
      panCarry -= CGFloat(lines)
      if screen.modes & UInt32(VT_MODE_ALT_SCREEN) != 0 {
        let key = Int32(lines > 0 ? VT_KEY_UP : VT_KEY_DOWN)
        for _ in 0..<abs(lines) {
          session.input { t, out in vt_key(t, key, 0, out) }
        }
        return
      }
      vp.scroll(by: lines)
    }

    /// After a flick the text goes on and slows as a UIScrollView does
    /// (its normal deceleration, 0.998 a millisecond); a slow release stops.
    private func coast(from speed: CGFloat) {
      guard abs(speed) > 200 else { return }
      coastSpeed = speed
      let l = CADisplayLink(target: self, selector: #selector(coasting(_:)))
      l.add(to: .main, forMode: .common)
      coastLink = l
    }

    @objc private func coasting(_ l: CADisplayLink) {
      let dt = CGFloat(l.targetTimestamp - l.timestamp)
      move(by: coastSpeed * dt)
      coastSpeed *= pow(0.998, dt * 1000)
      if abs(coastSpeed) < 20 {
        stopCoasting()
      }
    }

    private func stopCoasting() {
      coastLink?.invalidate()
      coastLink = nil
      coastSpeed = 0
    }

    /// Any key brings the view back to the live screen, cursor lit.
    private func live() {
      stopCoasting()
      renderer.typed()
      dirty = true
      vp.live()
    }

    /// A trackpad or pencil over a hyperlink that would open underlines it.
    @objc private func hovered(_ g: UIHoverGestureRecognizer) {
      var link: UInt8 = 0
      if g.state == .began || g.state == .changed {
        let at = cell(at: g.location(in: self))
        link = screen.cell(at.row, at.col).link
        if session.link(link) == nil {
          link = 0
        }
      }
      if link != renderer.hoverLink {
        renderer.hoverLink = link
        dirty = true
      }
    }

    private var pinchAt = SIMD2<Float>(0, 0)

    /// The picture grows under the fingers and follows them; rows and
    /// columns stay (the font size is Cmd +/-). Back to 1, it is undone.
    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
      let scale = Float(window?.screen.scale ?? UIScreen.main.scale)
      let p = g.location(in: self)
      let at = SIMD2(Float(p.x), Float(p.y)) * scale
      switch g.state {
      case .began:
        pinchAt = at
      case .changed:
        let under = (pinchAt - renderer.shift) / renderer.zoom  // the grid point the fingers hold
        let z = min(6, max(1, renderer.zoom * Float(g.scale)))
        g.scale = 1
        let view = SIMD2(Float(bounds.width), Float(bounds.height)) * scale
        renderer.zoom = z
        renderer.shift = (at - under * z).clamped(
          lowerBound: view * (1 - z), upperBound: SIMD2(0, 0))
        pinchAt = at
        dirty = true
      default:
        break
      }
    }

    private var defaultFontSize: Double

    /// A config read again: font, colors, status bar, keys. Rows, Cols and
    /// History belong to a new session.
    func apply(_ theme: Theme) {
      session.clipboardAllowed = theme.clipboard != "deny"
      renderer.theme = theme
      renderer.statusBar = theme.statusBar
      defaultFontSize = theme.fontSize
      try? renderer.setFontSize(theme.fontSize)
      theme.apply { session.configure(color: $0, rgb: $1) }
      setNeedsLayout()
      dirty = true
    }

    @objc func biggerFont() { fontSize(renderer.theme.fontSize + fontStep) }
    @objc func smallerFont() { fontSize(renderer.theme.fontSize - fontStep) }
    /// About a tenth: one point at 18 hardly shows, and the first press seems lost.
    private var fontStep: Double { max(1, (renderer.theme.fontSize / 10).rounded()) }
    @objc func defaultFont() { fontSize(defaultFontSize) }

    /// Cmd +/-: the cells change size, so the grid gets more or fewer rows.
    private func fontSize(_ size: Double) {
      guard (6...80).contains(size), (try? renderer.setFontSize(size)) != nil else { return }
      setNeedsLayout()
      dirty = true
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
      stopCoasting()  // a touch stops a flick, as anywhere in iOS
      let p = grid(g.location(in: self))
      let row = (p.y - renderer.inset.y) / renderer.metrics.height
      if renderer.statusBar && row >= screen.rows {
        if vp.finding {
          vp.apply(statusBar.action(at: (p.x - renderer.inset.x) / renderer.metrics.width))
        }
        return
      }
      if vp.finding && vp.finder.editing {
        vp.focusField(false)
      }
      if vp.hasSelection {
        vp.clearSelection()
      }
      becomeFirstResponder()
    }

    // MARK: - selection: long press picks the word, dragging extends it

    private lazy var editMenu = UIEditMenuInteraction(delegate: self)

    /// A point of the view in the grid's device pixels, through the zoom.
    private func grid(_ point: CGPoint) -> SIMD2<Int> {
      let scale = Float(window?.screen.scale ?? UIScreen.main.scale)
      let p = (SIMD2(Float(point.x), Float(point.y)) * scale - renderer.shift) / renderer.zoom
      return SIMD2(Int(p.x), Int(p.y))
    }

    private func cell(at point: CGPoint) -> (row: Int, col: Int) {
      let m = renderer.metrics
      let p = grid(point)
      let col = (p.x - renderer.inset.x) / m.width
      let row = (p.y - renderer.inset.y) / m.height
      return (max(0, min(screen.rows - 1, row)), max(0, min(screen.cols - 1, col)))
    }

    @objc private func pressed(_ g: UILongPressGestureRecognizer) {
      let at = cell(at: g.location(in: self))
      switch g.state {
      case .began:
        vp.selectWord(at: at)
      case .changed:
        vp.extendSelection(to: at)
      case .ended:
        editMenu.presentEditMenu(
          with: UIEditMenuConfiguration(identifier: nil, sourcePoint: g.location(in: self)))
      default:
        break
      }
    }

    @objc private func menuClick(_ g: UITapGestureRecognizer) {
      menu(at: g.location(in: self))
    }

    private func menu(at p: CGPoint) {
      editMenu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: p))
    }

    @objc private func doubleClicked(_ g: UITapGestureRecognizer) {
      vp.selectWord(at: cell(at: g.location(in: self)))
      menu(at: g.location(in: self))
    }

    @objc private func tripleClicked(_ g: UITapGestureRecognizer) {
      vp.selectLine(at: cell(at: g.location(in: self)))
      menu(at: g.location(in: self))
    }

    @objc private func dragged(_ g: UIPanGestureRecognizer) {
      let p = g.location(in: self)
      let at = cell(at: p)
      switch g.state {
      case .began:
        // the drag is known only some points in: it began where the click was
        let t = g.translation(in: self)
        vp.anchorSelection(at: cell(at: CGPoint(x: p.x - t.x, y: p.y - t.y)))
        vp.extendSelection(to: at)
      case .changed:
        dragCol = at.col
        autoscroll(p.y < 0 ? 1 : (p.y > bounds.height ? -1 : 0))
        if autoscrolling == nil {
          vp.extendSelection(to: at)
        }
      case .ended:
        autoscroll(0)
        menu(at: p)
      default:
        autoscroll(0)
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

    fileprivate func copySelection() {
      if let text = vp.selectedText() {
        UIPasteboard.general.string = text
      }
      vp.clearSelection()
    }

    /// The size last given to the session: the screen it is compared with
    /// comes back a tick later, too late for a layout that undoes another.
    private var asked = (rows: 0, cols: 0)

    override func layoutSubviews() {
      super.layoutSubviews()
      let scale = window?.screen.scale ?? UIScreen.main.scale
      contentScaleFactor = scale
      let w = Int(bounds.width * scale)
      let h = Int(bounds.height * scale)
      guard w > 0, h > 0 else { return }
      metalLayer.drawableSize = CGSize(width: w, height: h)
      var safe = safeAreaInsets
      if #available(iOS 26, *) {
        // a resizable iPad window: its rounded corners and window controls
        // cost a row at the top, not columns down the side
        safe = edgeInsets(for: .safeArea(cornerAdaptation: .vertical))
      }
      renderer.inset = SIMD2(Int(safe.left * scale), Int(safe.top * scale))
      let usableH = Int(
        (min(keyboardTop.frame.maxY, bounds.height - safe.bottom) - safe.top) * scale)
      let usableW = Int((bounds.width - safe.left - safe.right) * scale)
      let (rows, cols) = renderer.gridSize(
        width: max(usableW, renderer.metrics.width), height: max(usableH, renderer.metrics.height))
      if rows != asked.rows || cols != asked.cols {
        asked = (rows, cols)
        session.resize(rows: rows, cols: cols)
      }
      dirty = true
    }

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
      let t = session.title()
      if t != title {
        title = t
        Hooks.fire("title", t)
      }
      if scrollBack == 0 && !marked.isEmpty {
        vp.screen.compose(marked)
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
        cursorVisible: scrollBack == 0 && !vp.copying)
      cb.present(drawable)
      cb.commit()
      dirty = false
    }

    // MARK: - on-screen keyboard

    override var canBecomeFirstResponder: Bool { true }
    var hasText: Bool { true }
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no

    func insertText(_ text: String) {
      live()
      marked = ""  // the input method's final text replaces what it was composing
      if ctrlLatched, let cp = text.unicodeScalars.first?.value {
        ctrlLatched = false
        updateBar()
        session.input { t, out in vt_text(t, cp, UInt32(VT_MOD_CTRL), out) }
        return
      }
      session.send(text == "\n" ? "\r" : text)
    }

    func deleteBackward() {
      live()
      session.send([0x7F])
    }

    // MARK: - hardware keyboard

    private static let special: [UIKeyboardHIDUsage: Int32] = [
      .keyboardUpArrow: Int32(VT_KEY_UP), .keyboardDownArrow: Int32(VT_KEY_DOWN),
      .keyboardRightArrow: Int32(VT_KEY_RIGHT), .keyboardLeftArrow: Int32(VT_KEY_LEFT),
      .keyboardHome: Int32(VT_KEY_HOME), .keyboardEnd: Int32(VT_KEY_END),
      .keyboardPageUp: Int32(VT_KEY_PAGE_UP), .keyboardPageDown: Int32(VT_KEY_PAGE_DOWN),
      .keyboardDeleteForward: Int32(VT_KEY_DELETE), .keyboardEscape: Int32(VT_KEY_ESCAPE),
      .keyboardTab: Int32(VT_KEY_TAB), .keyboardReturnOrEnter: Int32(VT_KEY_ENTER),
      .keypadEnter: Int32(VT_KEY_KP_ENTER), .keyboardDeleteOrBackspace: Int32(VT_KEY_BACKSPACE),
      .keyboardF1: Int32(VT_KEY_F1), .keyboardF2: Int32(VT_KEY_F1) + 1,
      .keyboardF3: Int32(VT_KEY_F1) + 2, .keyboardF4: Int32(VT_KEY_F1) + 3,
      .keyboardF5: Int32(VT_KEY_F1) + 4, .keyboardF6: Int32(VT_KEY_F1) + 5,
      .keyboardF7: Int32(VT_KEY_F1) + 6, .keyboardF8: Int32(VT_KEY_F1) + 7,
      .keyboardF9: Int32(VT_KEY_F1) + 8, .keyboardF10: Int32(VT_KEY_F1) + 9,
      .keyboardF11: Int32(VT_KEY_F1) + 10, .keyboardF12: Int32(VT_KEY_F12),
    ]

    private static let textual: Set<UIKeyboardHIDUsage> = [
      .keyboardReturnOrEnter, .keyboardTab, .keyboardDeleteOrBackspace,
    ]

    /// Keys the text system does not turn into text (arrows, Esc, Ctrl
    /// combinations) are encoded here; the rest go on to insertText. Every
    /// held key repeats here: the text system does not do it for this view.
    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      live()
      var rest = Set<UIPress>()
      for press in presses {
        guard let key = press.key, !key.modifierFlags.contains(.command) else {
          rest.insert(press)
          continue
        }
        var mods: UInt32 = 0
        if key.modifierFlags.contains(.shift) { mods |= UInt32(VT_MOD_SHIFT) }
        if key.modifierFlags.contains(.control) { mods |= UInt32(VT_MOD_CTRL) }
        let m = mods
        // Keys that are text (Return, Tab, Backspace) stay in the text
        // system's queue: intercepted here they would overtake the letters
        // typed just before them, which arrive later through insertText.
        let plain = !key.modifierFlags.contains(.control) && !key.modifierFlags.contains(.shift)
        if plain && TerminalView.textual.contains(key.keyCode) {
          rest.insert(press)
          startRepeat(key.keyCode) { [weak self] in self?.retype(key) }
          continue
        }
        if let code = TerminalView.special[key.keyCode] {
          let alt = key.modifierFlags.contains(.alternate)
          let word = alt && renderer.theme.optionArrows == "word" ? Keys.optionWord(code) : nil
          let km = alt ? m | UInt32(VT_MOD_ALT) : m
          let send: @MainActor @Sendable () -> Void = { [weak self] in
            if let word {
              self?.session.send(word)  // ⌥← ⌥→ ⌥⌫ by the word, as on the Mac
              return
            }
            self?.session.input { t, out in vt_key(t, code, km, out) }
            return
          }
          send()
          startRepeat(key.keyCode, send)
          continue
        }
        if key.modifierFlags.contains(.control),
          let cp = key.charactersIgnoringModifiers.unicodeScalars.first?.value
        {
          let send: @MainActor @Sendable () -> Void = { [weak self] in
            self?.session.input { t, out in vt_text(t, cp, m, out) }
            return
          }
          send()
          startRepeat(key.keyCode, send)
          continue
        }
        rest.insert(press)
        if !key.characters.isEmpty {
          startRepeat(key.keyCode) { [weak self] in self?.retype(key) }
        }
      }
      if !rest.isEmpty {
        super.pressesBegan(rest, with: event)
      }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      stopRepeat(presses)
      super.pressesEnded(presses, with: event)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      stopRepeat(presses)
      super.pressesCancelled(presses, with: event)
    }

    /// A held key that the text system typed once: typed again the same
    /// way, unless an input method is composing (a dead key, kana).
    private func retype(_ key: UIKey) {
      guard marked.isEmpty else { return }
      switch key.keyCode {
      case .keyboardDeleteOrBackspace: deleteBackward()
      case .keyboardReturnOrEnter: insertText("\n")
      case .keyboardTab: insertText("\t")
      default: insertText(key.characters)
      }
    }

    private func startRepeat(
      _ usage: UIKeyboardHIDUsage, _ send: @escaping @MainActor @Sendable () -> Void
    ) {
      repeatTimer?.invalidate()
      repeating = usage
      let delay = Double(renderer.theme.keyDelay) / 1000
      let every = Double(renderer.theme.keyRepeat) / 1000
      repeatTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          guard let self, self.repeating == usage else { return }
          self.repeatTimer = Timer.scheduledTimer(withTimeInterval: every, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
              self?.live()
              send()
            }
          }
        }
      }
    }

    private func stopRepeat(_ presses: Set<UIPress>) {
      guard let r = repeating, presses.contains(where: { $0.key?.keyCode == r }) else { return }
      repeatTimer?.invalidate()
      repeatTimer = nil
      repeating = nil
    }

    // MARK: - key bar over the on-screen keyboard

    private lazy var bar: UIView = makeBar()
    private var ctrlButton: UIButton?

    /// Only for the on-screen keyboard: a hardware one has all of these.
    override var inputAccessoryView: UIView? {
      GCKeyboard.coalesced == nil || keysWanted ? bar : nil
    }
    private var keysWanted = false  // asked for from the context menu

    /// The on-screen keyboard, or with a hardware one only the bar, is up.
    fileprivate var keyboardShown: Bool {
      isFirstResponder && (GCKeyboard.coalesced == nil || keysWanted)
    }

    /// From the context menu: with a hardware keyboard attached iPadOS keeps
    /// its own keyboard away, but the bar of extra keys can still come up.
    fileprivate func toggleKeyboard() {
      if keyboardShown {
        keysWanted = false
        if GCKeyboard.coalesced != nil {
          reloadInputViews()  // the bar goes; typing on the hardware keyboard goes on
          return
        }
        resignFirstResponder()
        return
      }
      keysWanted = true
      reloadInputViews()
      becomeFirstResponder()
    }

    @objc private func keyboardsChanged(_ note: Notification) {
      reloadInputViews()
      // a keyboard just connected is there to type in the session in front
      if note.name == .GCKeyboardDidConnect, !isHidden, window?.isKeyWindow == true {
        becomeFirstResponder()
      }
    }

    private static let allBarKeys: [(String, [UInt8]?)] = [
      ("esc", [0x1B]), ("ctrl", nil), ("tab", [0x09]), ("←", nil), ("↓", nil), ("↑", nil),
      ("→", nil), ("|", Array("|".utf8)), ("~", Array("~".utf8)), ("/", Array("/".utf8)),
      ("-", Array("-".utf8)), ("find", nil),
    ]
    /// The iPad's on-screen keyboard has tab and these symbols already;
    /// the bar carries only what it lacks.
    private static let barKeys = allBarKeys.filter { key in
      UIDevice.current.userInterfaceIdiom != .pad || !["tab", "|", "~", "/", "-"].contains(key.0)
    }
    private static let arrows: [String: Int32] = [
      "←": Int32(VT_KEY_LEFT), "↓": Int32(VT_KEY_DOWN), "↑": Int32(VT_KEY_UP),
      "→": Int32(VT_KEY_RIGHT),
    ]

    /// Keys of fixed width in a strip that scrolls when the screen is too
    /// narrow for all of them (a phone), instead of squeezing the labels.
    private func makeBar() -> UIView {
      let stack = UIStackView()
      stack.axis = .horizontal
      stack.spacing = 4
      for (title, _) in TerminalView.barKeys {
        var config = UIButton.Configuration.gray()
        config.title = title
        let b = UIButton(
          configuration: config,
          primaryAction: UIAction { [weak self] _ in
            self?.barKey(title)
          })
        if title == "ctrl" {
          ctrlButton = b
        }
        b.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
        stack.addArrangedSubview(b)
      }
      let bar = UIInputView(
        frame: CGRect(x: 0, y: 0, width: 0, height: 44), inputViewStyle: .keyboard)
      let scroll = UIScrollView()
      scroll.showsHorizontalScrollIndicator = false
      scroll.translatesAutoresizingMaskIntoConstraints = false
      stack.translatesAutoresizingMaskIntoConstraints = false
      bar.addSubview(scroll)
      scroll.addSubview(stack)
      let fill = stack.widthAnchor.constraint(
        equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -8)
      fill.priority = .defaultLow  // spread out when there is room, scroll when not
      NSLayoutConstraint.activate([
        scroll.leadingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.leadingAnchor),
        scroll.trailingAnchor.constraint(equalTo: bar.safeAreaLayoutGuide.trailingAnchor),
        scroll.topAnchor.constraint(equalTo: bar.topAnchor),
        scroll.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        stack.leadingAnchor.constraint(
          equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 4),
        stack.trailingAnchor.constraint(
          equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -4),
        stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 4),
        stack.bottomAnchor.constraint(
          equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -4),
        stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -8),
        fill,
      ])
      stack.distribution = .fillEqually
      return bar
    }

    private func barKey(_ title: String) {
      if title == "find" {
        showFind()
        return
      }
      live()
      if title == "ctrl" {
        ctrlLatched.toggle()
        updateBar()
        return
      }
      if let code = TerminalView.arrows[title] {
        session.input { t, out in vt_key(t, code, 0, out) }
        return
      }
      if let bytes = TerminalView.barKeys.first(where: { $0.0 == title })?.1 {
        if ctrlLatched, bytes.count == 1 {
          insertText(String(UnicodeScalar(bytes[0])))
          return
        }
        session.send(bytes)
      }
    }

    /// The latched ctrl shows as a filled key until the next character uses it.
    private func updateBar() {
      var config = ctrlLatched ? UIButton.Configuration.filled() : UIButton.Configuration.gray()
      config.title = "ctrl"
      ctrlButton?.configuration = config
    }

    /// Cmd+N stays here: the scene system, not the menu, makes windows.
    override var keyCommands: [UIKeyCommand]? {
      [UIKeyCommand(input: "n", modifierFlags: .command, action: #selector(newWindow))]
    }

    /// Two fingers tap: a new session, as in Blink.
    @objc private func twoFingerTap() {
      UIApplication.shared.sendAction(
        #selector(TerminalController.newSession), to: nil, from: self, for: nil)
    }

    override func paste(_ sender: Any?) {
      pasteText()
    }

    override func copy(_ sender: Any?) {
      copySelection()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
      switch action {
      case #selector(paste(_:)): return UIPasteboard.general.hasStrings
      case #selector(copy(_:)): return vp.hasSelection
      default: return super.canPerformAction(action, withSender: sender)
      }
    }

    // MARK: - find and prompts: the viewport's, reached from the find key,
    // the menus and the keyboard shortcuts

    @objc func showFind() {
      vp.find()
      becomeFirstResponder()
    }

    @objc func copyMode() { vp.enterCopyMode() }
    @objc func findOlder() { vp.step(back: true) }
    @objc func findNewer() { vp.step(back: false) }
    @objc func previousPrompt() { vp.jumpPrompt(back: true) }
    @objc func nextPrompt() { vp.jumpPrompt(back: false) }

    @objc private func newWindow() {
      UIApplication.shared.requestSceneSessionActivation(
        nil, userActivity: nil, options: nil, errorHandler: nil)
    }

    @objc fileprivate func pasteText() {
      if let s = UIPasteboard.general.string {
        session.paste(s)
      }
    }
  }

  // MARK: - composition (UITextInput): dead keys, Japanese, Chinese, Korean
  //
  // The only text this view "holds" is what an input method is composing:
  // it goes to the host when the method commits it, never before. The
  // positions below index into that marked text and nothing else.

  final class TextPosition: UITextPosition {
    let index: Int
    init(_ index: Int) { self.index = index }
  }

  final class TextRange: UITextRange {
    let from: Int
    let to: Int
    init(_ from: Int, _ to: Int) {
      self.from = min(from, to)
      self.to = max(from, to)
    }
    override var start: UITextPosition { TextPosition(from) }
    override var end: UITextPosition { TextPosition(to) }
    override var isEmpty: Bool { from == to }
  }

  extension TerminalView {
    private func index(_ p: UITextPosition) -> Int {
      min(max((p as? TextPosition)?.index ?? 0, 0), marked.count)
    }

    var selectedTextRange: UITextRange? {
      get { TextRange(marked.count, marked.count) }
      set {}
    }

    var markedTextRange: UITextRange? {
      marked.isEmpty ? nil : TextRange(0, marked.count)
    }

    var markedTextStyle: [NSAttributedString.Key: Any]? {
      get { nil }
      set {}
    }

    func setMarkedText(_ markedText: String?, selectedRange: NSRange) {
      marked = markedText ?? ""
    }

    /// Accepting the composition as it stands: it is the user's text now.
    func unmarkText() {
      let text = marked
      marked = ""
      if !text.isEmpty {
        insertText(text)
      }
    }

    var beginningOfDocument: UITextPosition { TextPosition(0) }
    var endOfDocument: UITextPosition { TextPosition(marked.count) }

    func text(in range: UITextRange) -> String? {
      guard let r = range as? TextRange else { return nil }
      let chars = Array(marked)
      let a = min(r.from, chars.count)
      let b = min(r.to, chars.count)
      return String(chars[a..<b])
    }

    func replace(_ range: UITextRange, withText text: String) {
      marked = ""
      insertText(text)
    }

    func textRange(from: UITextPosition, to: UITextPosition) -> UITextRange? {
      TextRange(index(from), index(to))
    }

    func position(from position: UITextPosition, offset: Int) -> UITextPosition? {
      let i = index(position) + offset
      return (0...marked.count).contains(i) ? TextPosition(i) : nil
    }

    func position(
      from position: UITextPosition, in direction: UITextLayoutDirection, offset: Int
    ) -> UITextPosition? {
      let sign = direction == .left || direction == .up ? -1 : 1
      return self.position(from: position, offset: sign * offset)
    }

    func compare(_ position: UITextPosition, to other: UITextPosition) -> ComparisonResult {
      let a = index(position)
      let b = index(other)
      return a < b ? .orderedAscending : (a > b ? .orderedDescending : .orderedSame)
    }

    func offset(from: UITextPosition, to: UITextPosition) -> Int {
      index(to) - index(from)
    }

    func position(within range: UITextRange, farthestIn direction: UITextLayoutDirection)
      -> UITextPosition?
    {
      direction == .left || direction == .up ? range.start : range.end
    }

    func characterRange(
      byExtending position: UITextPosition, in direction: UITextLayoutDirection
    ) -> UITextRange? {
      let i = index(position)
      return direction == .left || direction == .up ? TextRange(0, i) : TextRange(i, marked.count)
    }

    func baseWritingDirection(
      for position: UITextPosition, in direction: UITextStorageDirection
    ) -> NSWritingDirection { .leftToRight }

    func setBaseWritingDirection(_ writingDirection: NSWritingDirection, for range: UITextRange) {}

    /// Where the input method puts its candidate window: at the cursor.
    func firstRect(for range: UITextRange) -> CGRect {
      let scale = Float(window?.screen.scale ?? UIScreen.main.scale)
      let m = renderer.metrics
      let z = renderer.zoom
      let at =
        (SIMD2(Float(renderer.inset.x), Float(renderer.inset.y))
          + SIMD2(Float(Int(caret.col) * m.width), Float(Int(caret.row) * m.height))) * z
        + renderer.shift
      return CGRect(
        x: CGFloat(at.x / scale), y: CGFloat(at.y / scale),
        width: CGFloat(Float(m.width) * z / scale), height: CGFloat(Float(m.height) * z / scale))
    }

    func caretRect(for position: UITextPosition) -> CGRect {
      firstRect(for: TextRange(0, 0))
    }

    func selectionRects(for range: UITextRange) -> [UITextSelectionRect] { [] }

    func closestPosition(to point: CGPoint) -> UITextPosition? { endOfDocument }

    func closestPosition(to point: CGPoint, within range: UITextRange) -> UITextPosition? {
      range.end
    }

    func characterRange(at point: CGPoint) -> UITextRange? { nil }
  }

  extension TerminalView: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(
      _ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
      suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      var items: [UIMenuElement] = [
        UIAction(title: "Copy") { [weak self] _ in self?.copySelection() },
        UIAction(title: "Paste") { [weak self] _ in self?.pasteText() },
        UIAction(title: "Find") { [weak self] _ in self?.showFind() },
        UIAction(title: "Copy Mode") { [weak self] _ in self?.copyMode() },
        UIAction(title: "Clear Buffer") { [weak self] _ in self?.clearBuffer() },
        UIAction(title: keyboardShown ? "Hide Keyboard" : "Show Keyboard") { [weak self] _ in
          self?.toggleKeyboard()
        },
        UIAction(title: "New Session") { [weak self] _ in
          UIApplication.shared.sendAction(
            #selector(TerminalController.newSession), to: nil, from: self, for: nil)
        },
        UIAction(title: "Reload Config") { [weak self] _ in
          UIApplication.shared.sendAction(
            #selector(TerminalController.reloadConfig), to: nil, from: self, for: nil)
        },
        UIAction(title: "Close Session", attributes: .destructive) { [weak self] _ in
          UIApplication.shared.sendAction(
            #selector(TerminalController.closeSession), to: nil, from: self, for: nil)
        },
      ]
      let at = cell(at: configuration.sourcePoint)
      if let url = session.link(screen.cell(at.row, at.col).link) {
        items.insert(UIAction(title: "Open Link") { _ in UIApplication.shared.open(url) }, at: 0)
      }
      return UIMenu(children: items)
    }
  }
#endif
