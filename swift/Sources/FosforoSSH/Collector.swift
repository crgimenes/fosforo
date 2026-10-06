import Foundation

/// What a one-shot remote command gave back, gathered on the client's
/// thread and waited for on another: the bytes and, once it closed, the
/// exit status.
public final class Collector: @unchecked Sendable {
  private let lock = NSLock()
  private var bytes: [UInt8] = []
  private var done = false
  private var exit: Int32?

  public init() {}

  public func append(_ b: [UInt8]) {
    lock.lock()
    bytes += b
    lock.unlock()
  }

  /// The command ended; status nil when the connection went without one.
  public func finish(_ status: Int32? = nil) {
    lock.lock()
    done = true
    exit = status
    lock.unlock()
  }

  public var data: [UInt8] {
    lock.lock()
    defer { lock.unlock() }
    return bytes
  }

  public var text: String { String(decoding: data, as: UTF8.self) }

  public var status: Int32? {
    lock.lock()
    defer { lock.unlock() }
    return exit
  }

  /// Polls until finish or the time is up; false when it never came.
  public func wait(seconds: Double) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
      lock.lock()
      let d = done
      lock.unlock()
      if d {
        return true
      }
      Thread.sleep(forTimeInterval: 0.02)
    }
    return false
  }
}
