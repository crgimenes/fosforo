#if os(iOS)
  import CoreText
  import FosforoCore
  import FosforoMosh
  import FosforoRender
  import FosforoSSH
  import UIKit
  @preconcurrency import UserNotifications

  @MainActor
  final class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
      _ app: UIApplication,
      didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
      UNUserNotificationCenter.current().delegate = self
      registerBundledFonts()
      DispatchQueue.global(qos: .utility).async { AppDelegate.linkICloud() }
      RocShell.resolvePlaceholders()
      AppDelegate.installHooks()
      return true
    }

    /// The config's on-* hooks, read again with Reload Config; a config with
    /// an error leaves the ones in place (the window reports the error).
    static func installHooks() {
      guard let (_, hooks) = try? Theme.open() else { return }
      hooks.onTheme = { TerminalController.applyAll($0) }
      hooks.onNotice = { AppDelegate.post($0) }
      Hooks.install(hooks)
    }

    /// A notification from the app itself: a program's OSC 9/777, a hook's
    /// (notify). The first one asks the user's leave.
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

    /// The notification's session, shown: its scene brought forward and
    /// that session on top in it.
    static func reveal(session id: UUID) {
      for scene in UIApplication.shared.connectedScenes {
        // a scene in the background has no key window: any of its windows
        guard let ws = scene as? UIWindowScene, let window = ws.keyWindow ?? ws.windows.first,
          let c = window.rootViewController as? TerminalController, c.reveal(id)
        else {
          continue
        }
        UIApplication.shared.requestSceneSessionActivation(
          ws.session, userActivity: nil, options: nil, errorHandler: nil)
        return
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
            AppDelegate.reveal(session: id)
          }
        }
      }
      done()
    }

    /// With the app in front the notice is for another scene or session:
    /// still shown, as a banner.
    nonisolated func userNotificationCenter(
      _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
      withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
      done([.banner, .sound])
    }

    /// ~/iCloud: the app's folder in iCloud Drive ("fosforo"), beside the
    /// home that stays on the device (.ssh and .config never sync). Nothing
    /// when iCloud is off, or when ~/iCloud is something of the user's.
    /// yagni: files not downloaded yet show as .name.icloud placeholders.
    nonisolated static func linkICloud() {
      let fm = FileManager.default
      guard let container = fm.url(forUbiquityContainerIdentifier: nil) else { return }
      let docs = container.appendingPathComponent("Documents")
      try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
      let link = Theme.home.appendingPathComponent("iCloud")
      if let old = try? fm.destinationOfSymbolicLink(atPath: link.path) {
        guard old != docs.path else { return }
        try? fm.removeItem(at: link)  // ours, pointing where the container used to be
      } else if fm.fileExists(atPath: link.path) {
        return
      }
      try? fm.createSymbolicLink(at: link, withDestinationURL: docs)
    }

    func application(
      _ app: UIApplication, configurationForConnecting session: UISceneSession,
      options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
      let c = UISceneConfiguration(name: nil, sessionRole: session.role)
      c.delegateClass = SceneDelegate.self
      return c
    }

    /// The menu bar iPadOS shows at the top (pointer there, or a swipe down)
    /// and the shortcuts of a hardware keyboard: every command reachable
    /// without Cmd on the on-screen keyboard.
    override func buildMenu(with builder: UIMenuBuilder) {
      super.buildMenu(with: builder)
      guard builder.system == .main else { return }
      func key(
        _ title: String, _ input: String, _ mods: UIKeyModifierFlags = .command, _ action: Selector
      )
        -> UIKeyCommand
      {
        let c = UIKeyCommand(title: title, action: action, input: input, modifierFlags: mods)
        c.wantsPriorityOverSystemBehavior = true  // Cmd+arrows are text navigation otherwise
        return c
      }
      var goTo: [UIMenuElement] = []
      for n in 1...9 {
        goTo.append(
          UIKeyCommand(
            title: "Session \(n)", action: #selector(TerminalController.selectSession(_:)),
            input: "\(n)", modifierFlags: .command, propertyList: n))
      }
      let shell = UIMenu(
        title: "Shell",
        children: [
          UIMenu(
            options: .displayInline,
            children: [
              key("New Session", "t", .command, #selector(TerminalController.newSession)),
              key("Close Session", "w", .command, #selector(TerminalController.closeSession)),
            ]),
          UIMenu(
            options: .displayInline,
            children: [
              key(
                "Previous Session", UIKeyCommand.inputLeftArrow, .command,
                #selector(TerminalController.previousSession)),
              key(
                "Next Session", UIKeyCommand.inputRightArrow, .command,
                #selector(TerminalController.nextSession)),
              UIMenu(title: "Go to Session", children: goTo),
            ]),
          UIMenu(
            options: .displayInline,
            children: [
              key(
                "Previous Prompt", UIKeyCommand.inputUpArrow, .command,
                #selector(TerminalView.previousPrompt)),
              key(
                "Next Prompt", UIKeyCommand.inputDownArrow, .command,
                #selector(TerminalView.nextPrompt)),
            ]),
          UIMenu(
            options: .displayInline,
            children: [
              key("Find…", "f", .command, #selector(TerminalView.showFind)),
              key("Copy Mode", "c", [.command, .shift], #selector(TerminalView.copyMode)),
              key("Find Next", "g", .command, #selector(TerminalView.findOlder)),
              key("Find Previous", "g", [.command, .shift], #selector(TerminalView.findNewer)),
            ]),
        ])
      // the system's Find (Cmd F, G) and Close (Cmd W) own keys of the
      // Shell menu: with two owners UIKit drops the whole Shell, Cmd T too
      builder.remove(menu: .find)
      builder.remove(menu: .close)
      builder.insertSibling(shell, afterMenu: .file)
      // text styles mean nothing in a terminal; its Bigger/Smaller keys are ours
      builder.remove(menu: .format)
      builder.insertChild(
        UIMenu(
          title: "", options: .displayInline,
          children: [
            key("Reload Config", "r", .command, #selector(TerminalController.reloadConfig))
          ]), atEndOfMenu: .file)
      let fonts = [
        key("Bigger", "+", .command, #selector(TerminalView.biggerFont)),
        // one action twice needs a property list apart: UIKit tells commands by both
        UIKeyCommand(
          title: "Bigger", action: #selector(TerminalView.biggerFont), input: "=",
          modifierFlags: .command, propertyList: "="),
        key("Smaller", "-", .command, #selector(TerminalView.smallerFont)),
        key("Default Size", "0", .command, #selector(TerminalView.defaultFont)),
      ]
      fonts[1].attributes = .hidden  // Cmd = is Cmd + without the shift
      builder.insertChild(
        UIMenu(title: "", options: .displayInline, children: fonts), atStartOfMenu: .view)
    }

    /// Fonts shipped inside the app (the 3270 by default): iOS has only the
    /// system's, and the one the config names must be there to be used.
    private func registerBundledFonts() {
      let urls = Bundle.main.urls(forResourcesWithExtension: "otf", subdirectory: nil) ?? []
      for url in urls {
        CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
      }
    }
  }

  /// One window, one terminal: on iPadOS each window is a scene of its own
  /// with its own launcher and session (Cmd+N opens another).
  @MainActor
  final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    var window: UIWindow?

    func scene(
      _ scene: UIScene, willConnectTo session: UISceneSession,
      options connectionOptions: UIScene.ConnectionOptions
    ) {
      guard let ws = scene as? UIWindowScene else { return }
      let theme = (try? Theme.load()) ?? Theme()  // read per window, like Cmd+N on the Mac
      let window = UIWindow(windowScene: ws)
      window.rootViewController = TerminalController(theme: theme)
      window.makeKeyAndVisible()
      self.window = window
      Importer.offer(connectionOptions.urlContexts.map(\.url), from: terminals)
    }

    /// "Open in fosforo" while the app is running.
    func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
      Importer.offer(contexts.map(\.url), from: terminals)
    }

    private var backgroundSince: Date?
    static let relockAfter = 300.0  // seconds away before protected keys ask again

    private var terminals: TerminalController? {
      window?.rootViewController as? TerminalController
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
      terminals?.focus(true)
      Hooks.fire("focus")
    }

    func sceneWillResignActive(_ scene: UIScene) {
      terminals?.focus(false)
      Hooks.fire("blur")
    }

    func sceneDidEnterBackground(_ scene: UIScene) {
      backgroundSince = Date()
    }

    /// As banking apps do: after a while away, the owner is asked again.
    func sceneWillEnterForeground(_ scene: UIScene) {
      if let t = backgroundSince, Date().timeIntervalSince(t) > SceneDelegate.relockAfter {
        Launcher.deviceVault?.relock()
      }
      backgroundSince = nil
    }
  }

  /// "Open in fosforo" from the Files app or a share sheet: the file is
  /// copied into the home, a private key into ~/.ssh with its permissions,
  /// once the user says so; nothing moves on its own. Several files are
  /// asked about one after the other.
  @MainActor
  enum Importer {
    static func offer(_ urls: [URL], from controller: UIViewController?) {
      guard let controller, let url = urls.first(where: \.isFileURL) else { return }
      let rest = Array(urls.drop { $0 != url }.dropFirst())
      let scoped = url.startAccessingSecurityScopedResource()
      let data = try? Data(contentsOf: url)  // yagni: whole file in memory (keys, configs)
      if scoped {
        url.stopAccessingSecurityScopedResource()
      }
      guard let data else {
        offer(rest, from: controller)
        return
      }
      let name = url.lastPathComponent
      let key = PrivateKey.isPrivateKey(String(decoding: data.prefix(64), as: UTF8.self))
      let home = Theme.home
      let dest = home.appendingPathComponent(key ? ".ssh/" + name : name)
      let shown = (key ? "~/.ssh/" : "~/") + name
      let exists = FileManager.default.fileExists(atPath: dest.path)
      let alert = UIAlertController(
        title: (exists ? "Replace " : "Import ") + shown + "?",
        message: key ? "A private key: kept for this app only, mode 0600." : "\(data.count) bytes.",
        preferredStyle: .alert)
      alert.addAction(
        UIAlertAction(title: "Cancel", style: .cancel) { _ in offer(rest, from: controller) })
      alert.addAction(
        UIAlertAction(title: exists ? "Replace" : "Import", style: exists ? .destructive : .default)
        { _ in
          do {
            try save(data, to: dest, key: key)
          } catch {
            let failed = UIAlertController(
              title: "Could not import \(name)", message: "\(error)", preferredStyle: .alert)
            failed.addAction(UIAlertAction(title: "OK", style: .default))
            controller.present(failed, animated: true)
            return
          }
          offer(rest, from: controller)
        })
      controller.present(alert, animated: true)
    }

    private static func save(_ data: Data, to dest: URL, key: Bool) throws {
      if key {
        var dir = dest.deletingLastPathComponent()
        try FileManager.default.createDirectory(
          at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try dir.setResourceValues(values)
      }
      try data.write(to: dest, options: key ? [.atomic, .completeFileProtection] : [.atomic])
      if key {
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
      }
    }
  }

  /// A window's sessions, one view each, one shown at a time (the status
  /// bar says n/N): Cmd+T adds one, Cmd+W closes it, Cmd+Left/Right and
  /// Cmd+1..9 switch, as on the Mac.
  /// The device's account: "mobile" on an iPhone or iPad, as its Unix knows it.
  private let deviceUser = NSUserName().isEmpty ? "mobile" : NSUserName()
  /// The device's name as a host name: "iPad Pro" becomes iPad-Pro.
  @MainActor private var deviceHost: String {
    UIDevice.current.name.split(whereSeparator: \.isWhitespace).joined(separator: "-")
  }

  @MainActor
  final class TerminalController: UIViewController {
    private var theme: Theme
    private var views: [TerminalView] = []
    private var current = 0

    init(theme: Theme) {
      self.theme = theme
      super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("no coder") }

    override func loadView() {
      view = UIView()
      view.backgroundColor = .black
      do {
        try add()
      } catch {
        let label = UILabel()
        label.text = "fosforo: \(error)"
        label.numberOfLines = 0
        view = label
      }
    }

    /// A banner's bytes; "" for none. The default path not written yet (an
    /// install older than the file) is the copy in the app.
    private func art(_ path: String, default fallback: String, bundled: String) -> [UInt8] {
      guard !path.isEmpty else { return [] }
      if let bytes = try? Data(contentsOf: Theme.expand(path)) {
        return [UInt8](bytes)
      }
      guard path == fallback, let url = Bundle.main.url(forResource: bundled, withExtension: "ans")
      else { return [] }
      return (try? [UInt8](Data(contentsOf: url))) ?? []
    }

    private func add(directory: String? = nil) throws {
      let renderer = try Renderer(theme: theme, scale: UIScreen.main.scale)
      let home = Theme.home
      let launcher = Launcher(ssh: home.appendingPathComponent(".ssh"))
      launcher.clipboard = { UIPasteboard.general.string }
      let user = theme.user.isEmpty ? deviceUser : theme.user
      launcher.localUser = user
      let banner = art(theme.banner, default: Theme().banner, bundled: "banner")
      let narrow = art(theme.bannerNarrow, default: Theme().bannerNarrow, bundled: "banner-narrow")
      let shell = try ShellSwitch(
        home: home, launcher: launcher, user: user,
        host: theme.hostName.isEmpty ? deviceHost : theme.hostName, banner: banner,
        bannerNarrow: narrow, greeting: theme.greeting, directory: directory, rows: theme.rows,
        cols: theme.cols)
      let session = try Session(
        transport: shell, rows: theme.rows, cols: theme.cols, history: theme.history)
      theme.apply { session.configure(color: $0, rgb: $1) }
      let v = TerminalView(session: session, renderer: renderer)
      v.onExit = { [weak self, weak v] in
        guard let self, let v else { return }
        self.ended(v)
      }
      v.onSwipe = { [weak self] next in
        guard let self, !self.views.isEmpty else { return }
        self.show((self.current + (next ? 1 : self.views.count - 1)) % self.views.count)
      }
      v.frame = view.bounds
      v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      view.addSubview(v)
      views.insert(v, at: views.isEmpty ? 0 : current + 1)
      if isViewLoaded && view.window != nil {
        v.layoutIfNeeded()  // the grid's real size before the shell asks (the banner fits or not)
        v.start()
      }
      Hooks.fire("open")
      show(views.firstIndex { $0 === v } ?? 0)
    }

    /// The session with this id, if it is one of this scene's: shown.
    func reveal(_ id: UUID) -> Bool {
      guard let i = views.firstIndex(where: { $0.id == id }) else { return false }
      show(i)
      return true
    }

    private func show(_ index: Int) {
      guard views.indices.contains(index) else { return }
      if active && current != index {
        focus(false)
      }
      current = index
      for (i, v) in views.enumerated() {
        v.isHidden = i != index
        v.position = (i + 1, views.count)
      }
      views[index].becomeFirstResponder()
      if active {
        focus(true)
      }
    }

    private var active: Bool {
      view.window?.windowScene?.activationState == .foregroundActive
    }

    /// The window is the one in use, or stopped being: the shown session hears.
    func focus(_ on: Bool) {
      if views.indices.contains(current) {
        views[current].session.focus(on)
      }
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      for v in views {
        v.start()
      }
      if views.indices.contains(current) {
        views[current].becomeFirstResponder()
      }
    }

    @objc func newSession() {
      // where the session in front is: its rocchetto's directory, under any ssh
      let front = views.indices.contains(current) ? views[current] : nil
      try? add(directory: (front?.session.transport as? ShellSwitch)?.directory)
    }

    /// The last session stays: a window with no terminal has nothing to show.
    @objc func closeSession() {
      guard views.count > 1 else { return }
      let v = views.remove(at: current)
      v.stop()
      v.removeFromSuperview()
      Hooks.fire("close")
      show(min(current, views.count - 1))
    }

    /// exit in the shell: the session closes; the last one closes the
    /// window where there are others (iPad), else a new shell takes its
    /// place — an app never quits itself on iOS.
    private func ended(_ v: TerminalView) {
      guard let i = views.firstIndex(where: { $0 === v }) else { return }
      if views.count == 1 {
        if let scene = view.window?.windowScene, UIApplication.shared.connectedScenes.count > 1 {
          UIApplication.shared.requestSceneSessionDestruction(scene.session, options: nil)
          return
        }
        try? add()
      }
      views.remove(at: i)
      v.stop()
      v.removeFromSuperview()
      Hooks.fire("close")
      show(min(i < current ? current - 1 : current, views.count - 1))
    }

    static func applyAll(_ theme: Theme) {
      for scene in UIApplication.shared.connectedScenes {
        let c = (scene as? UIWindowScene)?.keyWindow?.rootViewController as? TerminalController
        c?.theme = theme
        for v in c?.views ?? [] {
          v.apply(theme)
        }
      }
    }

    /// init.filo again, for every window: what it changes shows now.
    @objc func reloadConfig() {
      let theme: Theme
      do {
        theme = try Theme.load()
      } catch {
        let alert = UIAlertController(
          title: "fosforo config", message: "\(error)", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
        return
      }
      TerminalController.applyAll(theme)
      AppDelegate.installHooks()
    }

    @objc func previousSession() {
      show((current + views.count - 1) % views.count)
    }

    @objc func nextSession() {
      show((current + 1) % views.count)
    }

    @objc func selectSession(_ c: UICommand) {
      show(((c.propertyList as? Int) ?? 1) - 1)
    }

    /// On the iPad the window controls (close, resize) live in that bar.
    override var prefersStatusBarHidden: Bool { UIDevice.current.userInterfaceIdiom != .pad }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
  }
#endif
