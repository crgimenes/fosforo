import FosforoRender
import Testing

private func fit(
  width: Int = 400, top: Int, bottom: Int, left: Int = 0, bottomMargin: Int = 0,
  firm: Bool = false, cell: (width: Int, height: Int) = (20, 40), statusBar: Bool = false
) -> (rows: Int, cols: Int, inset: SIMD2<Int>) {
  Renderer.fitGrid(
    width: width, top: top, bottom: bottom, left: left, bottomMargin: bottomMargin, firm: firm,
    cellWidth: cell.width, cellHeight: cell.height, statusBar: statusBar)
}

// iPad Pro 11" full screen at 2x: 1194x834 pt, margins 32 top and 25 bottom,
// a row of 20 pt; 777 pt between the margins is 3 pt short of 39 rows.
@Test func iPadKeyboardHiddenBorrowsHalfFromEachMargin() {
  let f = fit(width: 2388, top: 64, bottom: 1618, bottomMargin: 50, cell: (22, 40))
  #expect(f.rows == 39)
  #expect(f.cols == 108)
  #expect(f.inset == SIMD2(0, 61))
  #expect(f.inset.y + f.rows * 40 == 1621)
  let bar = fit(
    width: 2388, top: 64, bottom: 1618, bottomMargin: 50, cell: (22, 40), statusBar: true)
  #expect(bar.rows == 38)
  #expect(bar.inset == SIMD2(0, 61))
}

// The keyboard's top at 446 pt leaves 414 pt, 6 pt short of 21 rows: all of
// it comes from the top margin, none from the keyboard.
@Test func iPadKeyboardUpBorrowsOnlyFromTheTop() {
  let f = fit(width: 2388, top: 64, bottom: 892, bottomMargin: 50, firm: true, cell: (22, 40))
  #expect(f.rows == 21)
  #expect(f.inset == SIMD2(0, 52))
  #expect(f.inset.y + f.rows * 40 == 892)
}

@Test func anExactFitBorrowsNothing() {
  let f = fit(top: 0, bottom: 800, left: 30, bottomMargin: 50)
  #expect(f.rows == 20)
  #expect(f.cols == 20)
  #expect(f.inset == SIMD2(30, 0))
}

@Test func halfARowOrMoreShortBorrowsNothing() {
  let more = fit(top: 64, bottom: 474, bottomMargin: 200)
  #expect(more.rows == 10)
  #expect(more.inset == SIMD2(0, 64))
  let half = fit(top: 64, bottom: 484, bottomMargin: 200)
  #expect(half.rows == 10)
  #expect(half.inset == SIMD2(0, 64))
}

@Test func onAFirmBottomTheLeftoverGoesToTheTop() {
  let f = fit(top: 64, bottom: 474, bottomMargin: 50, firm: true)
  #expect(f.rows == 10)
  #expect(f.inset == SIMD2(0, 74))
  let bar = fit(top: 64, bottom: 474, bottomMargin: 50, firm: true, statusBar: true)
  #expect(bar.rows == 9)
  #expect(bar.inset == SIMD2(0, 74))
}

@Test func aThinTopMarginLeavesMoreToTheBottom() {
  let f = fit(top: 10, bottom: 438, bottomMargin: 40)
  #expect(f.rows == 11)
  #expect(f.inset == SIMD2(0, 5))
  #expect(f.inset.y + f.rows * 40 == 445)
}

@Test func whenNeitherMarginCanGiveEnoughNothingIsBorrowed() {
  let thin = fit(top: 10, bottom: 438, bottomMargin: 10)
  #expect(thin.rows == 10)
  #expect(thin.inset == SIMD2(0, 10))
  let firm = fit(top: 10, bottom: 438, bottomMargin: 40, firm: true)
  #expect(firm.rows == 10)
  #expect(firm.inset == SIMD2(0, 38))
}

// An iPhone at 3x: 393x852 pt, margins 59 and 34, a row of 20 pt; 759 pt is
// 1 pt short of 38 rows.
@Test func iPhoneAtThreeTimesBorrowsFromBoth() {
  let f = fit(width: 1179, top: 177, bottom: 2454, bottomMargin: 102, cell: (30, 60))
  #expect(f.rows == 38)
  #expect(f.cols == 39)
  #expect(f.inset == SIMD2(0, 175))
  #expect(f.inset.y + f.rows * 60 == 2455)
}
