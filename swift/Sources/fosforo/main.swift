#if os(macOS)
  import AppKit
  @preconcurrency import UserNotifications
  import FosforoCore
  import FosforoMosh
  import FosforoRender

  let usage = """
    usage: fosforo [-snapshot out.png [-r rows] [-c cols] [-scale n] [file]]

    Terminal emulator. With no arguments opens a window running your login
    shell. -snapshot renders the bytes of file (stdin when none) to a PNG with
    the window's renderer and exits, without opening any window.

      -snapshot out.png   write the frame to out.png
      -r rows, -c cols    grid size (default 25x80)
      -scale n            device pixels per point (default 2, Retina)
      -h                  this help

    example: script -q /dev/null ls -la | fosforo -snapshot /tmp/ls.png -c 100

    """

  @MainActor
  final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {

    func applicationDidFinishLaunching(_ note: Notification) {
      // holding a letter repeats it, as in a terminal; the system's default
      // would offer accents instead (iTerm2 turns it off the same way)
      UserDefaults.standard.register(defaults: ["ApplePressAndHoldEnabled": false])
      UNUserNotificationCenter.current().delegate = self
      buildMenu()
      do {
        try openWindow()
      } catch {
        FileHandle.standardError.write(Data("fosforo: \(error)\n".utf8))
        NSApp.terminate(nil)
      }
      NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
      Deck.confirmClosing(decks.flatMap(\.views)) ? .terminateNow : .terminateCancel
    }

    /// The config is read for every window, and again by Reload Config; its
    /// on-* hooks are the app's from then on.
    private func loadTheme() -> Theme {
      do {
        let (theme, hooks) = try Theme.open()
        hooks.onTheme = { [weak self] t in self?.applyAll(t) }
        hooks.onNotice = { AppDelegate.post($0) }
        Hooks.install(hooks)
        return theme
      } catch {
        let alert = NSAlert()
        alert.messageText = "fosforo config"
        alert.informativeText = "\(error)\n\nUsing the defaults for this window."
        alert.runModal()
        return Theme()
      }
    }

    private var decks: [Deck] = []

    /// One session's view: the login shell, the theme's colors.
    /// directory: where the shell opens (the session in front's, for ⌘T, as
    /// iTerm2 does); the home when none is given or it is gone.
    func makeView(directory: String? = nil) throws -> TerminalView {
      let theme = loadTheme()
      let scale = NSScreen.main?.backingScaleFactor ?? 2
      let renderer = try Renderer(theme: theme, scale: scale)
      let (path, argv) = Shell.login()
      var isDir: ObjCBool = false
      let start =
        directory.flatMap {
          FileManager.default.fileExists(atPath: $0, isDirectory: &isDir) && isDir.boolValue
            ? $0 : nil
        } ?? NSHomeDirectory()
      let session = try Session(
        executable: path, argv: argv, environment: Shell.environment(),
        directory: start, rows: theme.rows, cols: theme.cols, history: theme.history)
      theme.apply { session.configure(color: $0, rgb: $1) }
      return TerminalView(session: session, renderer: renderer)
    }

    private func openWindow() throws {
      let deck = try Deck(app: self)
      deck.onEmpty = { [weak self, weak deck] in self?.decks.removeAll { $0 === deck } }
      decks.append(deck)
    }

    @objc func about(_ sender: Any?) {
      let alert = NSAlert()
      alert.messageText = "fosforo"
      let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 560, height: 360))
      text.string = Credits.text
      text.isEditable = false
      text.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
      let scroll = NSScrollView(frame: text.frame)
      scroll.documentView = text
      scroll.hasVerticalScroller = true
      alert.accessoryView = scroll
      alert.runModal()
    }

    @objc func editConfig(_ sender: Any?) {
      _ = try? Theme.load()  // writes the documented default on first use
      NSWorkspace.shared.open(Theme.configURL)
    }

    /// A config with an error changes nothing: the windows keep what they have.
    @objc func reloadConfig(_ sender: Any?) {
      do {
        applyAll(try Theme.load())  // a bad file: the alert, and nothing changes
      } catch {
        let alert = NSAlert()
        alert.messageText = "fosforo config"
        alert.informativeText = "\(error)"
        alert.runModal()
        return
      }
      _ = loadTheme()  // the hooks follow the file too
    }

    func applyAll(_ theme: Theme) {
      for v in decks.flatMap(\.views) {
        v.apply(theme)
      }
    }

    /// A notification from the app itself: a program's OSC 9/777, a hook's
    /// (notify). The first one asks the user's leave. With a session, a
    /// click on it brings that session to the front.
    nonisolated static func post(_ text: String, session: UUID? = nil) {
      let center = UNUserNotificationCenter.current()
      center.requestAuthorization(options: [.alert, .sound]) { ok, _ in
        guard ok else { return }
        let content = UNMutableNotificationContent()
        content.title = "fosforo"
        content.body = text
        if let session {
          content.userInfo = ["session": session.uuidString]
        }
        center.add(
          UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
      }
    }

    /// The notification's session, shown: its window in front and key, that
    /// session on top of the window's deck.
    func reveal(session id: UUID) {
      for deck in decks {
        if let view = deck.views.first(where: { $0.id == id }) {
          NSApp.activate(ignoringOtherApps: true)
          deck.window.makeKeyAndOrderFront(nil)
          deck.reveal(view)
          return
        }
      }
    }

    nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
      withCompletionHandler done: @escaping () -> Void
    ) {
      let raw = response.notification.request.content.userInfo["session"] as? String
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          if let raw, let id = UUID(uuidString: raw) {
            self.reveal(session: id)
          }
        }
      }
      done()
    }

    /// With the app in front the notice is for another window or session:
    /// still shown, as a banner.
    nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
      withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
      done([.banner, .sound])
    }

    @objc func newWindow(_ sender: Any?) {
      do {
        try openWindow()
      } catch {
        NSAlert(error: error).runModal()
      }
    }

    private func buildMenu() {
      let main = NSMenu()
      let appItem = NSMenuItem()
      main.addItem(appItem)
      let app = NSMenu()
      app.addItem(
        withTitle: "Quit fosforo", action: #selector(NSApplication.terminate(_:)),
        keyEquivalent: "q")
      app.insertItem(
        withTitle: "Edit Config…", action: #selector(editConfig(_:)), keyEquivalent: ",", at: 0)
      app.insertItem(
        withTitle: "About fosforo", action: #selector(about(_:)), keyEquivalent: "", at: 0)
      appItem.submenu = app
      let shellItem = NSMenuItem()
      main.addItem(shellItem)
      let shell = NSMenu(title: "Shell")
      shell.addItem(withTitle: "New Window", action: #selector(newWindow(_:)), keyEquivalent: "n")
      shell.addItem(
        withTitle: "Reload Config", action: #selector(reloadConfig(_:)), keyEquivalent: "r")
      shell.addItem(.separator())
      shell.addItem(
        withTitle: "New Session", action: #selector(Deck.newSession(_:)), keyEquivalent: "t")
      shell.addItem(
        withTitle: "Close Session", action: #selector(Deck.closeSession(_:)), keyEquivalent: "w")
      let left = String(Character(UnicodeScalar(NSLeftArrowFunctionKey)!))
      let right = String(Character(UnicodeScalar(NSRightArrowFunctionKey)!))
      shell.addItem(
        withTitle: "Previous Session", action: #selector(Deck.previousSession(_:)),
        keyEquivalent: left)
      shell.addItem(
        withTitle: "Next Session", action: #selector(Deck.nextSession(_:)), keyEquivalent: right)
      for n in 1...9 {
        let item = NSMenuItem(
          title: "Session \(n)", action: #selector(Deck.selectSession(_:)), keyEquivalent: "\(n)")
        item.tag = n
        shell.addItem(item)
      }
      shellItem.submenu = shell
      let editItem = NSMenuItem()
      main.addItem(editItem)
      let edit = NSMenu(title: "Edit")
      edit.addItem(withTitle: "Copy", action: #selector(TerminalView.copy(_:)), keyEquivalent: "c")
      edit.addItem(
        withTitle: "Paste", action: #selector(TerminalView.paste(_:)), keyEquivalent: "v")
      edit.addItem(.separator())
      edit.addItem(
        withTitle: "Clear Buffer", action: #selector(TerminalView.clearBuffer(_:)),
        keyEquivalent: "k")
      edit.addItem(.separator())
      edit.addItem(withTitle: "Find…", action: #selector(TerminalView.find(_:)), keyEquivalent: "f")
      edit.addItem(
        withTitle: "Copy Mode", action: #selector(TerminalView.copyMode(_:)), keyEquivalent: "C")
      edit.addItem(
        withTitle: "Find Next (older)", action: #selector(TerminalView.findNext(_:)),
        keyEquivalent: "g")
      edit.addItem(
        withTitle: "Find Previous (newer)", action: #selector(TerminalView.findPrevious(_:)),
        keyEquivalent: "G")
      editItem.submenu = edit
      let viewItem = NSMenuItem()
      main.addItem(viewItem)
      let view = NSMenu(title: "View")
      let up = String(Character(UnicodeScalar(NSUpArrowFunctionKey)!))
      let down = String(Character(UnicodeScalar(NSDownArrowFunctionKey)!))
      view.addItem(
        withTitle: "Previous Prompt", action: #selector(TerminalView.previousPrompt(_:)),
        keyEquivalent: up)
      view.addItem(
        withTitle: "Next Prompt", action: #selector(TerminalView.nextPrompt(_:)),
        keyEquivalent: down)
      view.addItem(.separator())
      view.addItem(
        withTitle: "Bigger", action: #selector(TerminalView.biggerFont(_:)), keyEquivalent: "+")
      let equal = view.addItem(
        withTitle: "Bigger", action: #selector(TerminalView.biggerFont(_:)), keyEquivalent: "=")
      equal.isHidden = true  // Cmd = is Cmd + without the shift; hidden, it still answers
      view.addItem(
        withTitle: "Smaller", action: #selector(TerminalView.smallerFont(_:)), keyEquivalent: "-")
      view.addItem(
        withTitle: "Default Size", action: #selector(TerminalView.defaultFont(_:)),
        keyEquivalent: "0")
      viewItem.submenu = view
      NSApp.mainMenu = main
    }
  }

  /// -snapshot: the same renderer the window uses, into a PNG.
  func snapshot(_ args: [String]) -> Int32 {
    var rows = 25
    var cols = 80
    var scale = 2.0
    var out = ""
    var input: String?
    var i = 0
    while i < args.count {
      let a = args[i]
      let value = i + 1 < args.count ? args[i + 1] : nil
      switch a {
      case "-snapshot":
        out = value ?? ""
        i += 1
      case "-r":
        rows = Int(value ?? "") ?? 0
        i += 1
      case "-c":
        cols = Int(value ?? "") ?? 0
        i += 1
      case "-scale":
        scale = Double(value ?? "") ?? 0
        i += 1
      default: input = a
      }
      i += 1
    }
    guard !out.isEmpty, rows > 0, cols > 0, scale > 0 else {
      FileHandle.standardError.write(Data(usage.utf8))
      return 2
    }
    do {
      let theme = Theme()
      let renderer = try Renderer(theme: theme, scale: scale)
      let term = try Terminal(rows: rows, cols: cols, history: 0)
      theme.apply { term.configure(color: $0, rgb: $1) }
      let data =
        try input.map { try Data(contentsOf: URL(fileURLWithPath: $0)) }
        ?? FileHandle.standardInput.readDataToEndOfFile()
      term.write([UInt8](data))
      var screen = Screen()
      term.snapshot(into: &screen)
      try renderer.snapshot(screen, to: out)
      return 0
    } catch {
      FileHandle.standardError.write(Data("fosforo: \(error)\n".utf8))
      return 1
    }
  }

  let args = Array(CommandLine.arguments.dropFirst())
  if args.contains("-h") || args.contains("--help") {
    print(usage, terminator: "")
    exit(0)
  }
  if args.contains("-snapshot") {
    exit(snapshot(args))
  }
  let app = NSApplication.shared
  let delegate = AppDelegate()
  app.delegate = delegate
  app.setActivationPolicy(.regular)
  app.run()
#endif
