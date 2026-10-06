#if os(macOS)
  import AppKit
  import FosforoCore
  import FosforoRender

  /// A window's sessions, one view each, one shown at a time; the status
  /// bar says which (n/N). The deck is the window's delegate, so the menu's
  /// session actions reach it through the responder chain.
  @MainActor
  final class Deck: NSObject, NSWindowDelegate {
    let window: NSWindow
    private unowned let app: AppDelegate
    private(set) var views: [TerminalView] = []
    private var current = 0
    var onEmpty: (() -> Void)?
    static let frameName = "fosforo"

    init(app: AppDelegate) throws {
      self.app = app
      let first = try app.makeView()
      let r = first.renderer
      let scale = NSScreen.main?.backingScaleFactor ?? 2
      let rows = r.theme.rows + (r.statusBar ? 1 : 0)
      let size = NSSize(
        width: CGFloat(r.theme.cols * r.metrics.width) / scale,
        height: CGFloat(rows * r.metrics.height) / scale)
      window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.contentView = NSView()
      // AppKit's default releases the window on close; with this deck still
      // holding it, that was one release too many (a crash on the red button)
      window.isReleasedWhenClosed = false
      window.contentResizeIncrements = NSSize(
        width: CGFloat(r.metrics.width) / scale, height: CGFloat(r.metrics.height) / scale)
      window.title = "fosforo"
      // never so small that nothing fits: 20 columns, 5 rows and the bar
      window.contentMinSize = NSSize(
        width: CGFloat(20 * r.metrics.width) / scale,
        height: CGFloat((5 + (r.statusBar ? 1 : 0)) * r.metrics.height) / scale)
      window.collectionBehavior.insert(.fullScreenPrimary)
      super.init()
      // where the last window was left, then cascading from the front one
      let saved = UserDefaults.standard.object(forKey: "NSWindow Frame " + Deck.frameName) != nil
      window.setFrameAutosaveName(Deck.frameName)
      if let front = NSApp.keyWindow {
        let topLeft = NSPoint(x: front.frame.minX, y: front.frame.maxY)
        window.setFrameTopLeftPoint(window.cascadeTopLeft(from: topLeft))
      } else if !saved {
        window.center()
      }
      window.delegate = self
      add(first)
      window.makeKeyAndOrderFront(nil)
    }

    private func add(_ view: TerminalView) {
      guard let content = window.contentView else { return }
      view.frame = content.bounds
      view.autoresizingMask = [.width, .height]
      content.addSubview(view)
      view.onExit = { [weak self, weak view] in
        guard let self, let view else { return }
        self.remove(view)
      }
      view.onSwipe = { [weak self] next in
        guard let self, !self.views.isEmpty else { return }
        self.show((self.current + (next ? 1 : self.views.count - 1)) % self.views.count)
      }
      view.onTitle = { [weak self, weak view] t in
        guard let self, let view, self.views.indices.contains(self.current),
          self.views[self.current] === view
        else {
          return
        }
        self.window.title = t.isEmpty ? "fosforo" : t
      }
      views.insert(view, at: views.isEmpty ? 0 : current + 1)
      view.start()
      Hooks.fire("open")
      show(views.firstIndex { $0 === view } ?? 0)
    }

    /// A session of this deck brought on top (a notification's).
    func reveal(_ view: TerminalView) {
      if let i = views.firstIndex(where: { $0 === view }) {
        show(i)
      }
    }

    private func show(_ index: Int) {
      guard views.indices.contains(index) else { return }
      if window.isKeyWindow && current != index && views.indices.contains(current) {
        views[current].session.focus(false)
      }
      current = index
      for (i, v) in views.enumerated() {
        v.isHidden = i != index
        v.position = (i + 1, views.count)
      }
      let v = views[index]
      let t = v.session.title()
      window.title = t.isEmpty ? "fosforo" : t
      window.makeFirstResponder(v)
      if window.isKeyWindow {
        v.session.focus(true)
      }
    }

    func windowDidBecomeKey(_ note: Notification) {
      if views.indices.contains(current) {
        views[current].session.focus(true)
      }
      Hooks.fire("focus")
    }

    func windowDidResignKey(_ note: Notification) {
      if views.indices.contains(current) {
        views[current].session.focus(false)
      }
      Hooks.fire("blur")
    }

    private func remove(_ view: TerminalView) {
      guard let i = views.firstIndex(where: { $0 === view }) else { return }
      view.stop()
      view.removeFromSuperview()
      views.remove(at: i)
      Hooks.fire("close")
      if views.isEmpty {
        window.close()
        return
      }
      show(min(i, views.count - 1))
    }

    // MARK: - menu actions (responder chain)

    @objc func newSession(_ sender: Any?) {
      do {
        // the directory of the session in front: its foreground process's
        // own, on this machine (ssh's is where ssh was started), never OSC 7's
        let front = views.indices.contains(current) ? views[current] : nil
        add(try app.makeView(directory: front?.session.transport.foreground().cwd))
      } catch {
        NSAlert(error: error).runModal()
      }
    }

    @objc func closeSession(_ sender: Any?) {
      guard views.indices.contains(current), Deck.confirmClosing([views[current]]) else { return }
      remove(views[current])
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
      Deck.confirmClosing(views)
    }

    /// Closing ends what runs in these sessions: a shell at its prompt goes
    /// quietly, anything else (vim, ssh, a build) is asked about first, as
    /// iTerm2 does.
    static func confirmClosing(_ views: [TerminalView]) -> Bool {
      let busy = views.compactMap { v -> String? in
        guard let name = v.session.transport.foreground().name, !Shell.isShell(name) else {
          return nil
        }
        return name
      }
      guard !busy.isEmpty else { return true }
      let alert = NSAlert()
      alert.messageText =
        busy.count == 1
        ? "\(busy[0]) is still running." : "\(busy.count) programs are still running."
      alert.informativeText =
        "Closing ends " + (busy.count == 1 ? "it." : busy.joined(separator: ", ") + ".")
      alert.addButton(withTitle: "Close")
      alert.addButton(withTitle: "Cancel")
      return alert.runModal() == .alertFirstButtonReturn
    }

    @objc func previousSession(_ sender: Any?) {
      show((current + views.count - 1) % views.count)
    }

    @objc func nextSession(_ sender: Any?) {
      show((current + 1) % views.count)
    }

    @objc func selectSession(_ sender: NSMenuItem) {
      show(sender.tag - 1)
    }

    func windowWillClose(_ note: Notification) {
      for v in views {
        v.stop()
      }
      views.removeAll()
      onEmpty?()
    }
  }
#endif
