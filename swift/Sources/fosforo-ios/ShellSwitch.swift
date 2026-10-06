#if os(iOS)
  import FosforoCore
  import FosforoMosh
  import Foundation
  import UIKit

  /// What a window on iOS runs: rocchetto, which hands the app's commands (ssh,
  /// mosh, key, ssh-copy-id) to the launcher and waits for them; the
  /// terminal is the launcher's until the command ends.
  final class ShellSwitch: Transport, @unchecked Sendable {
    private let lock = NSLock()
    private let launcher: Launcher
    private let shell: RocShell
    private var current: Transport
    private var size: (rows: Int, cols: Int)
    private var output: (@Sendable ([UInt8]) -> Void)?

    init(
      home: URL, launcher: Launcher, user: String, host: String, banner: [UInt8],
      directory: String?, rows: Int, cols: Int
    ) throws {
      self.launcher = launcher
      size = (rows, cols)
      shell = try RocShell(
        home: home, user: user, host: host, commands: Launcher.shellCommands, banner: banner,
        directory: directory, rows: rows, cols: cols)
      current = shell
      shell.onCommand = { [weak self] words in self?.toLauncher(words) }
      shell.clipboardRead = { UIPasteboard.general.string }
      shell.clipboardWrite = { UIPasteboard.general.string = $0 }
    }

    func start(
      output: @escaping @Sendable ([UInt8]) -> Void, exit: @escaping @Sendable (Int32) -> Void
    ) {
      lock.lock()
      self.output = output
      lock.unlock()
      shell.start(output: output, exit: exit)
    }

    private func toLauncher(_ words: [String]) {
      lock.lock()
      current = launcher
      let out = output
      let s = size
      lock.unlock()
      launcher.resize(rows: s.rows, cols: s.cols)
      launcher.command(words, output: { out?($0) }, done: { [weak self] in self?.toShell($0) })
    }

    private func toShell(_ status: Int32) {
      lock.lock()
      current = shell
      let s = size
      let out = output
      lock.unlock()
      out?(Array("\u{1b}]2;\u{7}".utf8))  // the remote's title is gone with it
      shell.resize(rows: s.rows, cols: s.cols)
      shell.done(status)
    }

    /// Where rocchetto is, under whatever ssh or mosh runs on top: a new session
    /// opens there, never on the remote path.
    var directory: String? { shell.directory }

    private var active: Transport {
      lock.lock()
      defer { lock.unlock() }
      return current
    }

    func send(_ bytes: [UInt8]) { active.send(bytes) }

    func resize(rows: Int, cols: Int) {
      lock.lock()
      size = (rows, cols)
      lock.unlock()
      active.resize(rows: rows, cols: cols)
    }

    func hangup() {
      launcher.hangup()
      shell.hangup()
    }

    func overlay(_ screen: inout Screen) { active.overlay(&screen) }
    var overlayGeneration: UInt64 { active.overlayGeneration }
    var label: String? { active.label }
  }
#endif
