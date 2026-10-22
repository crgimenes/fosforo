/// Which of a window's sessions is in front, by index; every operation gives
/// the index to show next, nil when there is none.
public struct SessionOrder: Sendable {
  public let count: Int
  public let current: Int

  public init(count: Int, current: Int) {
    self.count = count
    self.current = current
  }

  /// A new session goes right after the one in front.
  public var insertion: Int { count == 0 ? 0 : current + 1 }

  public var previous: Int? { count == 0 ? nil : (current + count - 1) % count }

  public var next: Int? { count == 0 ? nil : (current + 1) % count }

  /// The n-th session counting from 1, as Cmd+1..9 names it.
  public func select(_ n: Int) -> Int? { n >= 1 && n <= count ? n - 1 : nil }

  /// After the session at `removed` is gone, `count` already less it: a
  /// session closed behind the front one leaves the front where it is;
  /// closing the front shows the one in its place, or the last.
  public func afterRemoving(_ removed: Int) -> Int? {
    guard count > 0 else { return nil }
    return min(removed < current ? current - 1 : current, count - 1)
  }
}
