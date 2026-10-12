import Foundation
import Testing

@testable import FosforoCore

@Test func compositionKeepsItsSelectionAndReplacesInPlace() {
  var c = Composition()
  c.mark("ab", selected: NSRange(location: 0, length: 1))
  #expect(c.selection == NSRange(location: 0, length: 1))
  c.replace(NSRange(location: 0, length: 1), with: "x")
  #expect(c.text == "xb")
  #expect(c.selection == NSRange(location: 1, length: 0))
  #expect(c.commit() == "xb")
  #expect(c.isEmpty)
}

@Test func compositionCountsUTF16AndNeverSplitsACharacter() {
  var c = Composition()
  c.mark("a😀e\u{301}", selected: NSRange(location: 2, length: 0))  // inside the emoji
  #expect(c.length == 5)
  #expect(c.selection.location == 1)
  #expect(c.text(in: NSRange(location: 1, length: 1)) == "😀")
  #expect(c.text(in: NSRange(location: 3, length: 9)) == "e\u{301}")
  c.select(NSRange(location: 99, length: 3))
  #expect(c.selection == NSRange(location: 5, length: 0))
  c.select(NSRange(location: NSNotFound, length: 0))
  #expect(c.selection == NSRange(location: 5, length: 0))
  c.replace(NSRange(location: 1, length: 2), with: "ç")
  #expect(c.text == "açe\u{301}")
  #expect(c.selection == NSRange(location: 2, length: 0))
}

@Test func compositionCancelledIsEmpty() {
  var c = Composition()
  c.mark("か", selected: NSRange(location: 1, length: 0))
  c.mark("", selected: NSRange(location: 0, length: 0))
  #expect(c.isEmpty)
  #expect(c.commit() == "")
}
