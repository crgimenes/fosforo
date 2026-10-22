import FosforoRender
import Testing

private let notices = Credits.text.split(separator: "\n", omittingEmptySubsequences: false)
  .map { $0.trimmingCharacters(in: .whitespaces) }
private let reflowed = Credits.reflowed(Credits.text).split(
  separator: "\n", omittingEmptySubsequences: false
).map(String.init)

@Test func everyCopyrightAndBulletStartsALine() {
  let items = notices.filter { $0.hasPrefix("Copyright") || $0.hasPrefix("*") }
  #expect(items.count == 12)
  for item in items {
    #expect(reflowed.contains { $0.hasPrefix(item) }, "\(item)")
  }
}

@Test func aHardWrappedParagraphBecomesOneLine() {
  #expect(
    reflowed.contains {
      $0.hasPrefix("THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS")
        && $0.hasSuffix("POSSIBILITY OF SUCH DAMAGE.")
    })
  let debian = [
    "The Debian Logo glyph is based on the Debian Open Use Logo and is Copyright (c) 1999",
    "Software in the Public Interest, Inc., and it is incorporated here under the terms of the",
    "Creative Commons Attribution-ShareAlike 3.0 Unported License. The logo is released under",
    "the terms of the GNU Lesser General Public License, version 3 or any later version, or, at",
    "your option, of the Creative Commons Attribution-ShareAlike 3.0 Unported License.",
  ]
  #expect(reflowed.contains(debian.joined(separator: " ")))
}

@Test func blankLinesBetweenParagraphsStay() {
  #expect(reflowed.filter(\.isEmpty).count == notices.filter(\.isEmpty).count)
  #expect(reflowed.count < notices.count)
}

@Test func reflowJoinsOnlyWhatContinues() {
  #expect(Credits.reflowed("") == "")
  #expect(Credits.reflowed("a\nb") == "a b")
  #expect(Credits.reflowed("a.\nb") == "a.\nb")
  #expect(Credits.reflowed("met:\nb") == "met:\nb")
  #expect(Credits.reflowed("a\n\nb") == "a\n\nb")
  #expect(Credits.reflowed("  a\n    * b\n      c") == "a\n* b c")
  #expect(Credits.reflowed("x\n1. one\n2. two") == "x\n1. one\n2. two")
  #expect(
    Credits.reflowed("Copyright a\nCopyright b\nreserved") == "Copyright a\nCopyright b reserved")
}
