import FosforoCore
import Testing

@Test func newSessionsGoRightAfterTheFrontOne() {
  #expect(SessionOrder(count: 0, current: 0).insertion == 0)
  #expect(SessionOrder(count: 1, current: 0).insertion == 1)
  #expect(SessionOrder(count: 3, current: 0).insertion == 1)
  #expect(SessionOrder(count: 3, current: 2).insertion == 3)
}

@Test func previousAndNextWrapAround() {
  let first = SessionOrder(count: 3, current: 0)
  #expect(first.previous == 2)
  #expect(first.next == 1)
  let last = SessionOrder(count: 3, current: 2)
  #expect(last.previous == 1)
  #expect(last.next == 0)
  let single = SessionOrder(count: 1, current: 0)
  #expect(single.previous == 0)
  #expect(single.next == 0)
  let empty = SessionOrder(count: 0, current: 0)
  #expect(empty.previous == nil)
  #expect(empty.next == nil)
}

@Test func selectCountsFromOneAndRefusesWhatIsNotThere() {
  let order = SessionOrder(count: 3, current: 1)
  #expect(order.select(1) == 0)
  #expect(order.select(3) == 2)
  #expect(order.select(4) == nil)
  #expect(order.select(9) == nil)
  #expect(order.select(0) == nil)
  #expect(order.select(-1) == nil)
  #expect(SessionOrder(count: 0, current: 0).select(1) == nil)
}

@Test func closingTheFrontSessionShowsTheOneInItsPlace() {
  #expect(SessionOrder(count: 2, current: 1).afterRemoving(1) == 1)
  #expect(SessionOrder(count: 2, current: 0).afterRemoving(0) == 0)
  #expect(SessionOrder(count: 2, current: 2).afterRemoving(2) == 1)  // the last went: the new last
  #expect(SessionOrder(count: 0, current: 0).afterRemoving(0) == nil)
}

@Test func closingABackSessionKeepsTheFront() {
  #expect(SessionOrder(count: 3, current: 2).afterRemoving(0) == 1)  // same view, one place down
  #expect(SessionOrder(count: 3, current: 0).afterRemoving(2) == 0)
  #expect(SessionOrder(count: 3, current: 1).afterRemoving(3) == 1)
}
