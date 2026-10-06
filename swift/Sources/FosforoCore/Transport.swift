import CFosforo
import Darwin
import Foundation

/// Where a session's bytes come from and go to: a process on a pty, an SSH
/// channel, rocchetto in-process.
public protocol Transport: AnyObject, Sendable {
  /// Starts delivering output; `exit` is called once, when the other side
  /// is gone, with a wait(2)-style status (or the remote exit status).
  func start(
    output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void)
  func send(_ bytes: [UInt8])
  func resize(rows: Int, cols: Int)
  /// What closing the window means to the other side.
  func hangup()
  /// Drawn over the screen without being in it (Mosh's predicted echo);
  /// overlayGeneration changes whenever the overlay does.
  func overlay(_ screen: inout Screen)
  var overlayGeneration: UInt64 { get }
  /// The directory and name of the foreground process, when the transport
  /// can see them (a local pty): the status bar without shell integration.
  func foreground() -> (cwd: String?, name: String?)
  /// What the status bar says about the other side ("ssh user@host"); nil
  /// when the shell is on this machine.
  var label: String? { get }
}

extension Transport {
  public func overlay(_ screen: inout Screen) {}
  public var overlayGeneration: UInt64 { 0 }
  public func foreground() -> (cwd: String?, name: String?) { (nil, nil) }
  public var label: String? { nil }
}

#if os(macOS)
  /// A local child process on a pseudo-terminal. Not on iOS: no fork there.
  public final class PTYTransport: Transport, @unchecked Sendable {
    private let fd: Int32
    public let pid: pid_t
    private let writer = DispatchQueue(label: "fosforo.pty.writer")
    private let lock = NSLock()
    private var exited = false

    /// argv[0] is what the child sees as its name ("-zsh" for a login shell).
    public init(
      executable: String, argv: [String], environment: [String: String], directory: String?,
      rows: Int, cols: Int
    ) throws {
      guard !argv.isEmpty else {
        throw SessionError(description: "empty argv")
      }
      let a = CStrings(argv)
      let e = CStrings(environment.map { "\($0.key)=\($0.value)" })
      var child: pid_t = 0
      fd = pty_spawn(
        executable, a.pointers, e.pointers, directory, Int32(rows), Int32(cols), &child)
      guard fd >= 0 else {
        throw SessionError(description: "pty_spawn: \(String(cString: strerror(errno)))")
      }
      pid = child
    }

    deinit {
      close(fd)
    }

    public func start(
      output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void
    ) {
      let thread = Thread { [self] in
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
          let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
          if n < 0 && errno == EINTR {
            continue
          }
          if n <= 0 {
            break
          }
          output(Array(buf[0..<n]))
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        lock.lock()
        exited = true
        lock.unlock()
        exit(status)
      }
      thread.name = "fosforo.pty.reader"
      thread.start()
    }

    /// In order and off the caller's thread: a paste larger than the pty
    /// buffer must not block the UI while the child catches up.
    public func send(_ bytes: [UInt8]) {
      writer.async { [fd] in
        var off = 0
        while off < bytes.count {
          let n = bytes[off...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
          if n < 0 && errno == EINTR {
            continue
          }
          if n <= 0 {
            return
          }
          off += n
        }
      }
    }

    public func resize(rows: Int, cols: Int) {
      _ = pty_resize(fd, Int32(rows), Int32(cols))
    }

    public func foreground() -> (cwd: String?, name: String?) {
      let group = tcgetpgrp(fd)
      let who = group > 0 ? group : pid
      var name = [CChar](repeating: 0, count: 256)
      let n = proc_name(who, &name, UInt32(name.count))
      var info = proc_vnodepathinfo()
      let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
      var cwd: String?
      if proc_pidinfo(who, PROC_PIDVNODEPATHINFO, 0, &info, size) == size {
        cwd = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
          String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
      }
      let bytes = name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
      return (cwd, n > 0 ? String(decoding: bytes, as: UTF8.self) : nil)
    }

    public func hangup() {
      lock.lock()
      let gone = exited
      lock.unlock()
      if !gone {
        kill(pid, SIGHUP)
      }
    }
  }

  /// A NULL-terminated char* array that owns its strings.
  private final class CStrings {
    let pointers: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>
    private let count: Int

    init(_ strings: [String]) {
      count = strings.count
      pointers = .allocate(capacity: strings.count + 1)
      for (i, s) in strings.enumerated() {
        pointers[i] = strdup(s)
      }
      pointers[strings.count] = nil
    }

    deinit {
      for i in 0..<count {
        free(pointers[i])
      }
      pointers.deallocate()
    }
  }
#endif
