import Foundation
import Testing

@testable import FosforoRender

@Test func settingsKeepWhatTheyDoNotKnow() {
  var s = SettingsFile(";; mine\n(set FontSize 18)\n(set Bell \"none\") ; by hand\n")
  s.set("FontSize", number: 16)
  s.set("StatusBar", flag: false)
  s.set("Greeting", string: "a \"b\"\nc")
  s.theme = "phosphor"
  #expect(s["FontSize"] == "16" && s["StatusBar"] == "#f")
  #expect(
    s.text
      == ";; mine\n(set FontSize 16)\n(set Bell \"none\") ; by hand\n(set StatusBar #f)\n"
      + "(set Greeting \"a \\\"b\\\"\\nc\")\n(theme \"phosphor\")\n")
  s.unset("FontSize")
  s.theme = nil
  #expect(s["FontSize"] == nil && s.theme == nil && s.lines.count == 4)
  let fresh = SettingsFile("")
  #expect(fresh.lines == SettingsFile.header)
}

/// settings.filo runs first; init.filo starts from it and wins where it sets.
@Test func settingsRunUnderInit() throws {
  let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: dir) }
  try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  let initURL = dir.appendingPathComponent("init.filo")
  var s = SettingsFile("")
  s.set("FontSize", number: 30)
  s.set("Rows", number: 40)
  try s.write(to: dir.appendingPathComponent("settings.filo"))
  try "(set Rows 30)\n".write(to: initURL, atomically: true, encoding: .utf8)
  let t = try Theme.load(from: initURL)
  #expect(t.fontSize == 30 && t.rows == 30)
  try "(set Bogus 1)\n".write(
    to: dir.appendingPathComponent("settings.filo"), atomically: true, encoding: .utf8)
  #expect(throws: ConfigError.self) { try Theme.load(from: initURL) }
}
