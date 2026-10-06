import FosforoCore
import Foundation

/// An SSH session channel as a terminal transport: the client's first
/// channel, or another one opened on a connection already made
/// (ControlMaster). The client must be connected already (connect()
/// blocks; the caller runs it off the UI).
public final class SSHTransport: Transport, @unchecked Sendable {
  public let client: SSHClient
  private let channel: SSHChannel?
  /// Why it ended, when it was not the remote shell exiting: set before exit.
  public private(set) var failure: SSHError?

  public init(client: SSHClient) {
    self.client = client
    channel = nil
  }

  public init(channel: SSHChannel, client: SSHClient) {
    self.client = client
    self.channel = channel
  }

  public func start(
    output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void
  ) {
    let close: @Sendable (Int32?, SSHError?) -> Void = { [self] status, error in
      failure = error
      exit(status ?? (error == nil ? 0 : 255))
    }
    if let channel {
      channel.onData = output
      channel.onClose = close
      channel.start()
      return
    }
    client.onData = output
    client.onClose = close
    client.start()
  }

  public func send(_ bytes: [UInt8]) {
    channel?.send(bytes) ?? client.send(bytes)
  }

  public func resize(rows: Int, cols: Int) {
    channel?.resize(rows: rows, cols: cols) ?? client.resize(rows: rows, cols: cols)
  }

  public func hangup() {
    channel?.close() ?? client.close()
  }
}

/// ssh -N: a connection that only carries its forwards. Nothing comes to
/// the terminal; Ctrl+C, or the window going, ends it.
public final class ForwardTransport: Transport, @unchecked Sendable {
  public let client: SSHClient
  /// Why it ended, when it was not closed here: set before exit.
  public private(set) var failure: SSHError?

  private let lock = NSLock()
  private var told = false  // exit was called

  public init(client: SSHClient) {
    self.client = client
  }

  public func start(
    output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void
  ) {
    let end: @Sendable (SSHError?) -> Void = { [self] error in
      lock.lock()
      let first = !told
      told = true
      lock.unlock()
      guard first else { return }
      failure = error
      exit(error == nil ? 0 : 255)
    }
    client.onEnd = end
    if !client.alive {
      end(nil)  // over before it was watched
    }
  }

  public func send(_ bytes: [UInt8]) {
    if bytes.contains(0x03) {
      client.disconnect()
    }
  }

  public func resize(rows: Int, cols: Int) {}

  public func hangup() {
    client.disconnect()
  }
}
