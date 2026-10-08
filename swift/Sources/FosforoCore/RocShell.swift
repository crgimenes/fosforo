#if os(iOS)
  import CFosforo
  import Darwin
  import Foundation

  /// rocchetto in this process: iOS has no processes to start. One thread drives
  /// the session (the C side is not thread-safe); keys and sizes reach it
  /// through a queue and a wake-up pipe, and its output goes out as it
  /// comes. The home directory is a real one: what the shell writes there
  /// is on disk.
  public final class RocShell: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private let home: URL
    private let user: String
    private let host: String
    private let banner: [UInt8]
    private let bannerNarrow: [UInt8]
    private let greeting: String
    private let commands: String
    private let startDirectory: String?
    private var cwd: String?
    private var finished: Int32?  // the app's command ended, with this status
    private var size: (rows: Int, cols: Int)
    private var keys: [UInt8] = []
    private var session: OpaquePointer?  // the C session while it runs, for a Ctrl-C from here
    private var resized = false
    private var stopping = false
    private let wake: (read: Int32, write: Int32)
    static let tickMs: UInt32 = 50
    static let idleTickMs: UInt32 = 250  // after idleAfter with no key, output or command
    static let idleAfter: TimeInterval = 2

    /// Called on the shell's thread with one of `commands` the user typed;
    /// the shell waits until done(status).
    public var onCommand: (@Sendable ([String]) -> Void)?

    /// The machine's clipboard for pbcopy and pbpaste (and the Filo
    /// functions), read and written on the shell's thread. Unset, the shell
    /// says this host has none.
    public var clipboardRead: (@Sendable () -> String?)?
    public var clipboardWrite: (@Sendable (String) -> Void)?
    private var clip: [UInt8] = []  // pbpaste's bytes, valid until the next read

    /// Where the shell is, as a path of its own tree (/home/<user>/...):
    /// what a new session's `directory` takes to open there.
    public var directory: String? {
      lock.lock()
      defer { lock.unlock() }
      return cwd
    }

    /// banner: shown first, when it fits the window; bannerNarrow in its
    /// place when only that fits. commands: the app's
    /// own, which the shell hands to onCommand. directory: where to open,
    /// as another session's `directory` says it; the home when it is gone.
    public init(
      home: URL, user: String, host: String, commands: [String] = [], banner: [UInt8] = [],
      bannerNarrow: [UInt8] = [], greeting: String = "", directory: String? = nil, rows: Int,
      cols: Int
    ) throws {
      try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
      self.home = home
      self.user = user
      self.host = host
      self.banner = banner
      self.bannerNarrow = bannerNarrow
      self.greeting = greeting
      self.commands = commands.joined(separator: " ")
      startDirectory = directory
      size = (rows, cols)
      var p: [Int32] = [0, 0]
      guard pipe(&p) == 0 else { throw SessionError(description: "pipe") }
      wake = (p[0], p[1])
      _ = fcntl(wake.read, F_SETFL, O_NONBLOCK)
      _ = fcntl(wake.write, F_SETFL, O_NONBLOCK)
    }

    deinit {
      close(wake.read)
      close(wake.write)
    }

    public func start(
      output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void
    ) {
      let t = Thread { [self] in run(output, exit) }
      t.name = "fosforo.roc"
      t.stackSize = 8 << 20  // a main thread's: rocchetto and its tree walk were made for one
      t.start()
    }

    private var busyOutput: (([UInt8]) -> Void)?  // the terminal, while a script runs long

    private func run(_ output: @escaping ([UInt8]) -> Void, _ exit: (Int32) -> Void) {
      lock.lock()
      let first = size
      lock.unlock()
      guard
        let s = froc_new(
          home.path, user, host, commands, UInt16(clamping: first.cols),
          UInt16(clamping: first.rows))
      else {
        output(Array("rocchetto: cannot open \(home.path)\r\n".utf8))
        exit(1)
        return
      }
      lock.lock()
      session = s
      lock.unlock()
      busyOutput = output
      froc_busy_output(
        s,
        { ctx, data, n in
          let me = Unmanaged<RocShell>.fromOpaque(ctx!).takeUnretainedValue()
          me.busyOutput?(Array(UnsafeBufferPointer(start: data, count: n)))
        }, Unmanaged.passUnretained(self).toOpaque())
      defer {
        lock.lock()
        session = nil
        lock.unlock()
        froc_free(s)
      }
      froc_clipboard(
        s,
        { ctx, len in
          let me = Unmanaged<RocShell>.fromOpaque(ctx!).takeUnretainedValue()
          return me.pasteBytes(len!)
        },
        { ctx, data, n in
          let me = Unmanaged<RocShell>.fromOpaque(ctx!).takeUnretainedValue()
          me.clipboardWrite?(
            String(decoding: UnsafeBufferPointer(start: data, count: n), as: UTF8.self))
          return me.clipboardWrite != nil
        }, Unmanaged.passUnretained(self).toOpaque())
      if let d = startDirectory {
        _ = froc_chdir(s, d)  // not a directory any more: the home, quietly
      }
      var p = [CChar](repeating: 0, count: 256)
      func track() {
        let n = p.withUnsafeMutableBufferPointer { froc_cwd(s, $0.baseAddress, $0.count) }
        let now =
          n > 0 ? String(decoding: p[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self) : nil
        lock.lock()
        cwd = now
        lock.unlock()
      }
      track()
      if let art = [banner, bannerNarrow].first(where: {
        !$0.isEmpty && RocShell.width(of: $0) <= first.cols
      }) {
        output(art + Array("\r\n".utf8))
      }
      if !greeting.isEmpty {
        let lines = greeting.split(separator: "\n", omittingEmptySubsequences: false)
        output(Array("\u{1b}[2m\(lines.joined(separator: "\r\n"))\u{1b}[0m\r\n".utf8))
      }
      var buf = [UInt8](repeating: 0, count: 65536)
      var active = Date()  // the last key, output or command
      func flush() {
        while true {
          let n = buf.withUnsafeMutableBufferPointer { froc_output(s, $0.baseAddress, $0.count) }
          guard n > 0 else { return }
          active = Date()
          output(Array(buf[0..<n]))
        }
      }
      flush()
      var last = Date()
      while !froc_exited(s) {
        // a session nobody typed at and that wrote nothing for a while is
        // ticked every quarter second, not twenty times a second: rocchetto needs
        // the tick for its timeouts, not for sitting at a prompt
        let idle = Date().timeIntervalSince(active) > RocShell.idleAfter
        var fds = pollfd(fd: wake.read, events: Int16(POLLIN), revents: 0)
        _ = poll(&fds, 1, Int32(idle ? RocShell.idleTickMs : RocShell.tickMs))
        var drain = [UInt8](repeating: 0, count: 64)
        while read(wake.read, &drain, drain.count) > 0 {}
        lock.lock()
        let input = keys
        keys.removeAll()
        let newSize = resized ? size : nil
        resized = false
        let stop = stopping
        let done = finished
        finished = nil
        lock.unlock()
        if stop {
          return
        }
        if let n = newSize {
          froc_resize(s, UInt16(clamping: n.cols), UInt16(clamping: n.rows))
        }
        if let d = done {
          froc_done(s, d)
        }
        if !input.isEmpty {
          active = Date()
          input.withUnsafeBufferPointer { froc_input(s, $0.baseAddress, $0.count) }
        }
        let now = Date()
        let ms = UInt32(min(1000, max(0, now.timeIntervalSince(last) * 1000)))
        if ms >= RocShell.tickMs {
          froc_tick(s, ms)
          last = now
        }
        flush()
        track()
        var cmd = [CChar](repeating: 0, count: 4096)
        let n = cmd.withUnsafeMutableBufferPointer { froc_command(s, $0.baseAddress, $0.count) }
        if n > 0 {
          let words = cmd[0..<n].split(separator: 0, omittingEmptySubsequences: false).dropLast()
          onCommand?(
            words.map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) })
        }
      }
      flush()
      exit(0)
    }

    /// iCloud Drive files not downloaded yet (the disk shows .name.icloud)
    /// are listed by their names with their sizes, and brought down when
    /// read, as the Files app does. Once, before the first session.
    public static func resolvePlaceholders() {
      froc_placeholders(
        { _, path, size in
          let url = URL(fileURLWithPath: String(cString: path!))
          let values = try? url.resourceValues(forKeys: [.fileSizeKey])
          size!.pointee = Int64(values?.fileSize ?? 0)
          return true
        },
        { _, path in
          let url = URL(fileURLWithPath: String(cString: path!))
          try? FileManager.default.startDownloadingUbiquitousItem(at: url)
          let deadline = Date().addingTimeInterval(60)
          while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) {
              return true
            }
            Thread.sleep(forTimeInterval: 0.2)
          }
          return false
        }, nil)
    }

    /// The columns a banner takes, drawn off screen: art made of cursor
    /// moves and colors has no line lengths to count.
    static func width(of bytes: [UInt8]) -> Int {
      guard let t = try? Terminal(rows: 200, cols: 400, history: 0) else { return Int.max }
      t.write(bytes)
      var screen = Screen()
      t.snapshot(into: &screen)
      var widest = 0
      for r in 0..<screen.rows {
        for c in stride(from: screen.cols - 1, through: widest, by: -1) {
          let cell = screen.cell(r, c)
          if cell.cp > 32 || cell.bg != 0 {
            widest = c + 1
            break
          }
        }
      }
      return widest
    }

    /// The clipboard as bytes the C side may keep until the next call.
    private func pasteBytes(_ len: UnsafeMutablePointer<Int>) -> UnsafePointer<UInt8>? {
      guard let text = clipboardRead?() else {
        len.pointee = 0
        return nil
      }
      clip = Array(text.utf8)
      len.pointee = clip.count
      return clip.withUnsafeBufferPointer { $0.baseAddress }
    }

    private func poke() {
      var b: UInt8 = 1
      _ = Darwin.write(wake.write, &b, 1)
    }

    public func send(_ bytes: [UInt8]) {
      lock.lock()
      keys += bytes
      if bytes.contains(0x03), let s = session {
        froc_interrupt(s)  // a script running stops now, not after it ends
      }
      lock.unlock()
      poke()
    }

    public func resize(rows: Int, cols: Int) {
      lock.lock()
      size = (rows, cols)
      resized = true
      lock.unlock()
      poke()
    }

    /// The command onCommand was given has ended.
    public func done(_ status: Int32) {
      lock.lock()
      finished = status
      lock.unlock()
      poke()
    }

    /// Closing the window ends the shell; nothing to hang up but the thread.
    public func hangup() {
      lock.lock()
      stopping = true
      lock.unlock()
      poke()
    }
  }
#endif
