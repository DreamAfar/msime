import XCTest

/// 主线程卡顿探针的判断逻辑。喂时间而不是真等，测试不必依赖主队列有多忙。
final class KeyboardStallDetectorTests: XCTestCase {
  func testShortGapIsNotReported() {
    let detector = KeyboardStallDetector(threshold: 0.25)
    XCTAssertTrue(detector.beginBeat(at: 10))
    XCTAssertNil(detector.overdueEvent(at: 10.1))
    XCTAssertNil(detector.beat(at: 10.1))
  }

  func testOverdueBeatIsReportedOnceWithTheStageItWasIn() {
    let detector = KeyboardStallDetector(threshold: 0.25)
    detector.mark("skin")
    XCTAssertTrue(detector.beginBeat(at: 10))
    XCTAssertNil(detector.overdueEvent(at: 10.2))
    XCTAssertEqual(detector.overdueEvent(at: 10.4), KeyboardStallDetector.Event(milliseconds: 400, stage: "skin", recovered: false))
    // 同一次卡顿只报一次下界；主线程还没回来时后台每一轮都会看到它超时。
    XCTAssertNil(detector.overdueEvent(at: 10.6))
  }

  func testRecoveryReportsTheExactLengthWhenItIsClearlyLonger() {
    let detector = KeyboardStallDetector(threshold: 0.25)
    detector.mark("preferences")
    XCTAssertTrue(detector.beginBeat(at: 10))
    XCTAssertNotNil(detector.overdueEvent(at: 10.3))
    XCTAssertEqual(detector.beat(at: 11.2), KeyboardStallDetector.Event(milliseconds: 1_200, stage: "preferences", recovered: true))
  }

  func testRecoveryWithoutAPriorReportStillRecordsTheStall() {
    let detector = KeyboardStallDetector(threshold: 0.25)
    detector.mark("session_resume")
    XCTAssertTrue(detector.beginBeat(at: 10))
    // 后台那一轮还没赶上检查，主线程自己恢复了：这时只有主线程能报。
    XCTAssertEqual(detector.beat(at: 10.5), KeyboardStallDetector.Event(milliseconds: 500, stage: "session_resume", recovered: false))
  }

  func testRecoveryCloseToTheLowerBoundIsNotReportedTwice() {
    let detector = KeyboardStallDetector(threshold: 0.25)
    XCTAssertTrue(detector.beginBeat(at: 10))
    XCTAssertNotNil(detector.overdueEvent(at: 10.3))
    // 下界 300 ms、真实 340 ms：差不到 100 ms，再写一行只会让人以为卡了两次。
    XCTAssertNil(detector.beat(at: 10.34))
  }

  func testNoSecondBeatWhileOneIsStillPending() {
    let detector = KeyboardStallDetector(threshold: 0.25)
    XCTAssertTrue(detector.beginBeat(at: 10))
    XCTAssertTrue(detector.hasPendingBeat())
    XCTAssertFalse(detector.beginBeat(at: 10.05))
    XCTAssertNil(detector.beat(at: 10.06))
    XCTAssertFalse(detector.hasPendingBeat())
    XCTAssertTrue(detector.beginBeat(at: 10.07))
  }
}
