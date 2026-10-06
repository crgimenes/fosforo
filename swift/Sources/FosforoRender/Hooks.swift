import CFosforo
import Foundation

/// init.filo's on-* functions, run when the app's events happen (the list
/// is in cfg.h): the interpreter stays alive after the config ran. For an
/// event nobody set a handler for nothing runs at all: wants() is the
/// gate, cheap and safe from any thread; the handler itself runs on the
/// main thread, under the core's step budget.
public final class Hooks: @unchecked Sendable {
  public static let events = [
    "open", "close", "bell", "title", "prompt", "focus", "blur", "notify",
  ]
  private let session: OpaquePointer
  private var vars: [cfg_var]
  private let keys: [(String, Theme.Key)]
  private var theme: Theme
  /// The events with a handler, fixed when the config ran.
  public let has: Set<String>
  /// The theme after a handler changed it (set or (theme)), for every window.
  public var onTheme: ((Theme) -> Void)?
  /// (notify "text") from a handler, or the handler's own error.
  public var onNotice: ((String) -> Void)?

  /// Runs the config as Theme.parse does and keeps the interpreter.
  public static func open(_ source: String, themes: URL?) throws -> (Theme, Hooks) {
    let keys = Theme.keys()
    var vars = Theme.variables(keys, of: Theme())
    let bytes = Array(source.utf8)
    var err = [CChar](repeating: 0, count: 512)
    guard let s = cfg_open(bytes, bytes.count, themes?.path, &vars, vars.count, &err, err.count)
    else {
      Theme.freeNames(vars)
      throw ConfigError(description: Theme.cString(err))
    }
    do {
      let theme = try Theme.theme(from: vars, keys: keys)
      return (theme, Hooks(session: s, vars: vars, keys: keys, theme: theme))
    } catch {
      cfg_close(s)
      Theme.freeNames(vars)
      throw error
    }
  }

  private init(session: OpaquePointer, vars: [cfg_var], keys: [(String, Theme.Key)], theme: Theme) {
    self.session = session
    self.vars = vars
    self.keys = keys
    self.theme = theme
    has = Set(Hooks.events.filter { cfg_has(session, $0) })
  }

  deinit {
    cfg_close(session)
    Theme.freeNames(vars)
  }

  private static let lock = NSLock()
  nonisolated(unsafe) private static var active: Set<String> = []
  @MainActor public private(set) static var current: Hooks?

  /// The hooks of the config last read; nil forgets them.
  @MainActor public static func install(_ hooks: Hooks?) {
    current = hooks
    lock.lock()
    active = hooks?.has ?? []
    lock.unlock()
  }

  /// Whether firing `event` would run anything; from any thread.
  public static func wants(_ event: String) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return active.contains(event)
  }

  /// The event, from any thread: the handler, if any, runs on the main one.
  public static func fire(_ event: String, _ arg: String = "") {
    guard wants(event) else { return }
    Task { @MainActor in current?.fire(event, arg) }
  }

  /// Runs the handler of `event` with `arg`; what it changed reaches
  /// onTheme and onNotice.
  @MainActor public func fire(_ event: String, _ arg: String = "") {
    guard has.contains(event) else { return }
    var out = vars
    var notice = [CChar](repeating: 0, count: 256)
    var err = [CChar](repeating: 0, count: 512)
    let rc = cfg_fire(
      session, event, arg, &out, out.count, &notice, notice.count, &err, err.count)
    guard rc == 0 else {
      onNotice?(Theme.cString(err))
      return
    }
    let text = Theme.cString(notice)
    if !text.isEmpty {
      onNotice?(text)
    }
    do {
      let t = try Theme.theme(from: out, keys: keys)
      if t != theme {
        theme = t
        vars = out
        onTheme?(t)
      }
    } catch {
      onNotice?("on-\(event): \(error)")
    }
  }
}
