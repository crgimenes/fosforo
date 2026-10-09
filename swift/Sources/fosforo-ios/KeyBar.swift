#if os(iOS)
  import CFosforo
  import UIKit

  /// Terminal keys on the on-screen keyboard, plain labels as in Blink. On
  /// the phone a bar over the keyboard; on the iPad inside the keyboard's
  /// own shortcuts bar, the whole width (KeyHost puts it there). The fixed
  /// keys come first, up to fn; what follows scrolls when it does not fit.
  /// A key with two labels gives the small one when flicked down, as the
  /// iPad keyboard does; the arrows are one key, the side touched picks the
  /// direction. Modifiers stay on for the next key and show it; fn swaps
  /// the symbols for F1 to F12. The footer is the iPad's bar for the Pencil
  /// (drawing over the terminal): a key that brings the keyboard back, the
  /// drawing tools, colors, undo, clear and share.
  final class KeyBar: UIInputView {
    enum Part { case phone, pad, footer }

    enum Key: Equatable {
      case esc, ctrl, alt, tab, fn, find, hide, keyboard, textMode
      case undo, clear, share
      case tool(Int)  // index in tools
      case color(Int)  // index in colors
      case text(String)
      case arrow(Int32)
      case function(Int)  // 1...12
    }

    var onKey: (Key) -> Void = { _ in }
    var ctrl = false { didSet { refresh() } }
    var alt = false { didSet { refresh() } }
    var fn = false { didSet { fillStrip() } }
    var tool = 0 { didSet { refresh() } }
    var color = 0 { didSet { refresh() } }
    static let tools = ["pencil.tip", "highlighter", "eraser"]
    static let colors: [UIColor] = [.white, .systemRed, .systemYellow, .systemCyan, .systemGreen]

    let part: Part
    private let scroll = UIScrollView()
    private var left: [KeyView] = []
    private var strip: [KeyView] = []
    private var right: [KeyView] = []  // the phone's, at its right end

    private static let pad = UIDevice.current.userInterfaceIdiom == .pad
    /// Every key the same, as on the keyboard below.
    private static let keyWidth: CGFloat = pad ? 54 : 38
    private static let symbols: [(String, String?)] = [
      ("`", "~"), ("@", "#"), ("$", "^"), (";", ":"), ("-", "_"), ("=", "+"), ("[", "{"),
      ("]", "}"), ("\\", "|"), ("<", nil), (">", nil), ("/", "?"), ("'", "\""),
    ]

    init(_ part: Part) {
      self.part = part
      super.init(
        frame: CGRect(x: 0, y: 0, width: 0, height: 44),
        inputViewStyle: part == .pad ? .default : .keyboard)
      if part == .phone {
        translatesAutoresizingMaskIntoConstraints = false  // sized by intrinsicContentSize
        allowsSelfSizing = true
      }
      backgroundColor = part == .pad ? .clear : nil
      if part == .footer {
        // on the terminal, not in the keyboard: a dark keyboard's look of its own
        overrideUserInterfaceStyle = .dark
        backgroundColor = .secondarySystemBackground
      }
      scroll.showsHorizontalScrollIndicator = false
      scroll.alwaysBounceHorizontal = false
      scroll.delaysContentTouches = false  // a key lights at once, as on the keyboard
      scroll.contentInsetAdjustmentBehavior = .never
      if #available(iOS 26, *), part == .phone {
        // the keyboard is a rounded sheet of glass: the bar is its top edge
        let glass = UIVisualEffectView(effect: UIGlassEffect())
        glass.cornerConfiguration = .capsule(maximumRadius: 16)
        glass.frame = bounds
        glass.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        glass.isUserInteractionEnabled = false
        addSubview(glass)
      }
      addSubview(scroll)
      rebuild()
      registerForTraitChanges([UITraitVerticalSizeClass.self]) { (self: Self, _) in
        self.invalidateIntrinsicContentSize()
      }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no coder") }

    /// Taller on the iPad, lower with the phone on its side: the keyboard's
    /// own rows change the same way, and a fixed height came out clipped
    /// after a rotation.
    static func height(_ traits: UITraitCollection) -> CGFloat {
      pad ? 55 : traits.verticalSizeClass == .compact ? 38 : 44
    }

    override var intrinsicContentSize: CGSize {
      CGSize(width: UIView.noIntrinsicMetric, height: KeyBar.height(traitCollection))
    }

    private func rebuild() {
      placeFixed()
      fillStrip()
    }

    private func placeFixed() {
      for k in left + right {
        k.removeFromSuperview()
      }
      // the keyboard key first, where it always is
      let back =
        part == .footer
        ? [
          KeyView(.keyboard, symbol: "keyboard"),
          KeyView(.textMode, symbol: "character.cursor.ibeam"),
        ]
        : []
      let terminal = [
        KeyView(.esc, symbol: "escape"), KeyView(.ctrl, symbol: "control"),
        KeyView(.alt, symbol: "option"),
      ]
      let tail = [
        KeyView(.arrow(0), symbol: "arrow.up.and.down.and.arrow.left.and.right", repeats: true),
        KeyView(.find, symbol: "magnifyingglass"), KeyView(.fn, "fn"),
      ]
      switch part {
      case .phone:
        left = terminal + [KeyView(.tab, symbol: "arrow.right.to.line")]
        right = tail
      case .pad:  // the iPad keyboard has a tab key of its own
        left = terminal + tail
        right = []
      case .footer:
        left = back + KeyBar.tools.indices.map { KeyView(.tool($0), symbol: KeyBar.tools[$0]) }
        right = []
      }
      for k in left + right {
        addSubview(k)
        k.onKey = { [weak self] in self?.onKey($0) }
      }
      refresh()
      setNeedsLayout()
    }

    private func fillStrip() {
      for k in strip {
        k.removeFromSuperview()
      }
      if part == .footer {
        strip =
          KeyBar.colors.indices.map {
            KeyView(.color($0), symbol: "circle.fill", tint: KeyBar.colors[$0])
          } + [
            KeyView(.undo, symbol: "arrow.uturn.backward"), KeyView(.clear, symbol: "trash"),
            KeyView(.share, symbol: "square.and.arrow.up"),
          ]
      } else if fn {
        // the iPad keyboard has its own hide key
        strip =
          (KeyBar.pad ? [] : [KeyView(.hide, symbol: "keyboard.chevron.compact.down")])
          + (1...12).map { KeyView(.function($0), "F\($0)") }
      } else {
        strip = KeyBar.symbols.map { p, s in
          KeyView(.text(p), p, secondary: s.map { .text($0) }, s)
        }
      }
      for k in strip {
        k.onKey = { [weak self] in self?.onKey($0) }
        scroll.addSubview(k)
      }
      scroll.contentOffset = .zero
      refresh()
      setNeedsLayout()
    }

    private func refresh() {
      for k in left + strip + right {
        switch k.key {
        case .ctrl: k.on = ctrl
        case .alt: k.on = alt
        case .fn: k.on = fn
        case .tool(let i): k.on = i == tool
        case .color(let i): k.on = i == color
        default: break
        }
      }
    }

    /// The fixed keys, then the strip to the end; on the phone the arrows,
    /// find and fn close the bar at the right.
    override func layoutSubviews() {
      super.layoutSubviews()
      let area = bounds.inset(by: safeAreaInsets).insetBy(dx: 8, dy: 3)
      let w = KeyBar.keyWidth
      var x = area.minX
      for k in left {
        k.frame = CGRect(x: x, y: area.minY, width: w, height: area.height)
        x += w
      }
      var end = area.maxX
      for k in right.reversed() {
        end -= w
        k.frame = CGRect(x: end, y: area.minY, width: w, height: area.height)
      }
      scroll.frame = CGRect(x: x, y: area.minY, width: max(0, end - x), height: area.height)
      var sx: CGFloat = 0
      for k in strip {
        k.frame = CGRect(x: sx, y: 0, width: w, height: area.height)
        sx += w
      }
      scroll.contentSize = CGSize(width: sx, height: area.height)
    }
  }

  /// The iPad's way into its keyboard: a bar item of no size whose view, once
  /// in the keyboard's shortcuts bar, puts the KeyBar over that bar's whole
  /// width (as Blink does; the view names are UIKit's, not API, so when they
  /// are not found the bar stays inside the item, narrow but there).
  final class KeyHost: UIView {
    let bar: KeyBar

    init(_ bar: KeyBar) {
      self.bar = bar
      super.init(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no coder") }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else {
        bar.removeFromSuperview()
        return
      }
      setNeedsLayout()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      guard window != nil else { return }
      var place: UIView? = superview
      while let v = place, !String(describing: type(of: v)).contains("InputAssistantView") {
        place = v.superview
      }
      let host = place ?? self
      if bar.superview !== host {
        bar.removeFromSuperview()
        bar.frame = host.bounds
        bar.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(bar)
      }
      host.bringSubviewToFront(bar)
    }
  }

  extension KeyBar: UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
  }

  /// One key: a label, maybe a small second one above it, lit while touched.
  private final class KeyView: UIView {
    let key: KeyBar.Key
    private let secondary: KeyBar.Key?
    private let repeats: Bool
    var onKey: (KeyBar.Key) -> Void = { _ in }
    var on = false { didSet { paint() } }

    private let back = UIView()
    private let label = UILabel()
    private let small = UILabel()
    private var flicked = false
    private var start = CGPoint.zero
    private var timer: Timer?

    init(
      _ key: KeyBar.Key, _ title: String = "", symbol: String? = nil,
      secondary: KeyBar.Key? = nil, _ smallTitle: String? = nil, repeats: Bool = false,
      tint: UIColor = .label
    ) {
      self.key = key
      self.secondary = secondary
      self.repeats = repeats
      super.init(frame: .zero)
      back.isUserInteractionEnabled = false
      back.layer.cornerRadius = 8
      back.layer.cornerCurve = .continuous
      addSubview(back)
      if let symbol {
        let image = UIImageView(image: UIImage(systemName: symbol))
        image.tintColor = tint
        image.contentMode = .center
        image.frame = bounds
        image.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(image)
      }
      label.text = title
      label.textAlignment = .center
      label.font = .systemFont(ofSize: title.count > 1 ? 18 : 20)
      label.textColor = .label
      addSubview(label)
      small.text = smallTitle
      small.textAlignment = .center
      small.font = .systemFont(ofSize: 11)
      small.textColor = .secondaryLabel
      addSubview(small)
      isAccessibilityElement = true
      accessibilityLabel = title.isEmpty ? symbol : title
      accessibilityTraits = .keyboardKey
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no coder") }

    override func layoutSubviews() {
      super.layoutSubviews()
      back.frame = bounds.insetBy(dx: 2, dy: 0)
      if small.text == nil {
        label.frame = bounds
        return
      }
      let h = bounds.height
      small.frame = CGRect(x: 0, y: h * 0.08, width: bounds.width, height: h * 0.3)
      label.frame = CGRect(x: 0, y: h * 0.3, width: bounds.width, height: h * 0.6)
    }

    private var lit = false { didSet { paint() } }

    private func paint() {
      back.backgroundColor =
        on ? tintColor.withAlphaComponent(0.5) : lit ? .systemFill : .clear
      label.alpha = flicked ? 0.35 : 1
      small.textColor = flicked ? .label : .secondaryLabel
      small.transform = flicked ? CGAffineTransform(scaleX: 1.6, y: 1.6) : .identity
    }

    /// The arrow key: the side of its middle the finger is on, the
    /// farther way of the two; moving the finger turns it.
    private var aimed: KeyBar.Key {
      guard case .arrow = key else { return key }
      let dx = touch.x - bounds.midX
      let dy = touch.y - bounds.midY
      if abs(dx) / bounds.width > abs(dy) / bounds.height {
        return .arrow(Int32(dx < 0 ? VT_KEY_LEFT : VT_KEY_RIGHT))
      }
      return .arrow(Int32(dy < 0 ? VT_KEY_UP : VT_KEY_DOWN))
    }
    private var touch = CGPoint.zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
      start = touches.first?.location(in: self) ?? .zero
      touch = start
      flicked = false
      lit = true
      UIDevice.current.playInputClick()
      guard repeats else { return }
      onKey(aimed)
      timer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
        MainActor.assumeIsolated {
          self?.timer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated {
              guard let self else { return }
              self.onKey(self.aimed)
            }
          }
        }
      }
    }

    /// Down by a third of the key takes the small label, as on the iPad keyboard.
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
      touch = touches.first?.location(in: self) ?? touch
      guard secondary != nil, let p = touches.first?.location(in: self) else { return }
      let down = p.y - start.y > bounds.height / 3
      if down != flicked {
        flicked = down
        paint()
      }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
      if !repeats {
        onKey(flicked ? secondary ?? key : key)
      }
      finish()
    }

    /// The strip scrolling takes the touch: no key.
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
      finish()
    }

    private func finish() {
      timer?.invalidate()
      timer = nil
      flicked = false
      lit = false
    }
  }
#endif
