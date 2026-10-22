#if os(iOS) && DEBUG
  import Foundation
  import FosforoCore
  import UIKit

  /// A launch the simulator smoke drives (tools/ios-smoke.sh), in debug
  /// builds only: the store's is a release build and has none of this.
  /// FOSFORO_SMOKE names a file in Documents, one line per step: text is
  /// typed into the first session with a return, "@wait SECONDS" waits,
  /// "@dismiss" closes what is presented over the terminal. At the end the
  /// screen as text and the class of what is presented go to smoke.out
  /// beside it, which the script reads back from the app's container.
  @MainActor
  enum Smoke {
    static func start(_ c: TerminalController) {
      guard let name = ProcessInfo.processInfo.environment["FOSFORO_SMOKE"] else { return }
      let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      guard let script = try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
      else { return }
      let steps = script.split(separator: "\n").map(String.init)
      run(steps[...], c, out: dir.appendingPathComponent("smoke.out"), after: 2)
    }

    private static func run(
      _ steps: ArraySlice<String>, _ c: TerminalController, out: URL, after delay: Double
    ) {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        guard let step = steps.first else {
          finish(c, out)
          return
        }
        var wait = 1.5
        if step.hasPrefix("@wait ") {
          wait = Double(step.dropFirst(6)) ?? 1
        } else if step == "@dismiss" {
          c.presentedViewController?.dismiss(animated: false)
        } else {
          c.frontSession?.send(step + "\r")
        }
        run(steps.dropFirst(), c, out: out, after: wait)
      }
    }

    private static func finish(_ c: TerminalController, _ out: URL) {
      var screen = Screen()
      c.frontSession?.snapshot(into: &screen)
      let presented = c.presentedViewController.map { String(describing: type(of: $0)) } ?? "none"
      let shown =
        (c.presentedViewController as? UINavigationController)?.topViewController
        .map { String(describing: type(of: $0)) } ?? "none"
      let text = screen.text + "\n--- presented \(presented) \(shown)\n"
      try? text.write(to: out, atomically: true, encoding: .utf8)
    }
  }
#endif
