import Foundation
import Testing

@testable import FosforoCore

/// build/fosforo-roc at the repository root (make roc-host).
private let host = URL(fileURLWithPath: #filePath)
  .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  .deletingLastPathComponent().appendingPathComponent("build/fosforo-roc").path

private func screenText(_ s: Session) -> String {
  var screen = Screen()
  s.snapshot(into: &screen)
  var out = ""
  for c in screen.cells {
    out.unicodeScalars.append(Unicode.Scalar(c.cp == 0 ? 32 : c.cp) ?? " ")
  }
  return out
}

private func waitFor(_ s: Session, _ text: String) -> Bool {
  let deadline = Date().addingTimeInterval(10)
  while Date() < deadline {
    if screenText(s).contains(text) {
      return true
    }
    Thread.sleep(forTimeInterval: 0.05)
  }
  return false
}

@Test(.enabled(if: FileManager.default.isExecutableFile(atPath: host)))
func mshWorksOnARealDirectory() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: dir) }
  try "ola do disco\n".write(
    to: dir.appendingPathComponent("notas.txt"), atomically: true, encoding: .utf8)
  try FileManager.default.createDirectory(
    at: dir.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
  try "x".write(to: dir.appendingPathComponent(".ssh/config"), atomically: true, encoding: .utf8)

  let s = try Session(
    executable: host, argv: ["fosforo-roc", dir.path], environment: ["USER": "teste"],
    directory: nil, rows: 24, cols: 80, history: 100)
  s.start()
  defer { s.hangup() }
  #expect(waitFor(s, "teste@"))  // the prompt from the start, no board
  #expect(!screenText(s).contains("Your choice"))
  s.send("ls\r")
  #expect(waitFor(s, "notas.txt"))
  #expect(!screenText(s).contains(".ssh"))  // hidden, as ls does
  s.send("ls -a\r")
  #expect(waitFor(s, ".ssh"))
  s.send("cat notas.txt\r")
  #expect(waitFor(s, "ola do disco"))
  s.send("echo gravado > novo.txt\r")
  let novo = dir.appendingPathComponent("novo.txt")
  let deadline = Date().addingTimeInterval(10)
  while Date() < deadline && !FileManager.default.fileExists(atPath: novo.path) {
    Thread.sleep(forTimeInterval: 0.05)
  }
  #expect(try String(contentsOf: novo, encoding: .utf8) == "gravado\n")
  s.send("exit\r")  // ends the session, as a shell does
  let end = Date().addingTimeInterval(10)
  while Date() < end && !s.hasExited {
    Thread.sleep(forTimeInterval: 0.05)
  }
  #expect(s.hasExited)
}
