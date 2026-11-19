import XCTest

/// 按住 ⌫ 横滑删除：往左滑多远删多少，不松手往右滑按原样恢复。
final class BackspaceSwipeDeletionTests: XCTestCase {
  private let step = BackspaceSwipeDeletion.step

  func testLeftwardDistanceDecidesHowManyToDelete() {
    let swipe = BackspaceSwipeDeletion(unit: .text(context: "你好世界"))
    XCTAssertEqual(swipe.available, 4)
    XCTAssertEqual(swipe.target(translation: 0), 0)
    XCTAssertEqual(swipe.target(translation: 30), 0, "往右滑不删")
    XCTAssertEqual(swipe.target(translation: -(step - 0.1)), 0, "不满一格不删")
    XCTAssertEqual(swipe.target(translation: -step), 1)
    XCTAssertEqual(swipe.target(translation: -2.5 * step), 2)
    XCTAssertEqual(swipe.target(translation: -100 * step), 4, "最多删到读得到的字数")
    XCTAssertEqual(swipe.target(translation: -.infinity), 0)
  }

  func testMovingBackRestoresWhatWasDeleted() {
    var swipe = BackspaceSwipeDeletion(unit: .text(context: "ab😀c"))
    XCTAssertEqual(swipe.move(to: -3 * step), 3, "删 c、😀、b")
    XCTAssertEqual(swipe.applied, 3)
    XCTAssertEqual((0..<3).compactMap { swipe.deletedText(at: $0) }, ["c", "😀", "b"], "离光标近的先删")
    XCTAssertEqual(swipe.move(to: -1 * step), -2, "往右滑回两格，恢复两个")
    XCTAssertEqual(swipe.applied, 1)
    XCTAssertEqual(swipe.move(to: 20), -1, "滑过起点全部恢复")
    XCTAssertEqual(swipe.applied, 0)
    XCTAssertEqual(swipe.move(to: 25), 0)
  }

  func testCompositionRetypesTheDeletedCodesInOrder() {
    var swipe = BackspaceSwipeDeletion(unit: .composition(original: "nihao"))
    XCTAssertEqual(swipe.move(to: -3 * step), 3)
    XCTAssertEqual(swipe.retyped(from: 3, to: 1), ["h", "a"], "从 ni 恢复到 niha")
    XCTAssertEqual(swipe.retyped(from: 3, to: 0), ["h", "a", "o"])
    XCTAssertEqual(swipe.retyped(from: 1, to: 3), [], "继续删时没有要重打的码")
    XCTAssertNil(swipe.deletedText(at: 0), "组码不按文字插回")
    XCTAssertEqual(swipe.move(to: -99 * step), 2, "最多删完整段组码")
  }

  func testOnlyRetypableCompositionsTakeTheSwipe() {
    XCTAssertTrue(BackspaceSwipeDeletion.canRetype(composition: "ni'hao", caret: 6))
    XCTAssertTrue(BackspaceSwipeDeletion.canRetype(composition: "64426", caret: 5), "九键数字")
    XCTAssertFalse(BackspaceSwipeDeletion.canRetype(composition: "nihao", caret: 2), "光标不在末尾")
    XCTAssertFalse(BackspaceSwipeDeletion.canRetype(composition: "", caret: 0))
    XCTAssertFalse(BackspaceSwipeDeletion.canRetype(composition: "u;", caret: 2), "微软双拼的 ;")
    XCTAssertFalse(BackspaceSwipeDeletion.canRetype(composition: "かな", caret: 2))
  }
}
