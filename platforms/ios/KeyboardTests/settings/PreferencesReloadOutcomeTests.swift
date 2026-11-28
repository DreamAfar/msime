import XCTest

/// 键盘每次出现都会重载共享文档。文档没变时再跑一遍十几个 `synchronize*` 和外观重算，只会把首帧之后的主线程占住；这里守住「没变就只回报、不重放」这条边界，同时保证「改了就一定重放」。
@MainActor
final class PreferencesReloadOutcomeTests: XCTestCase {
  private var state: URL!

  override func setUp() {
    super.setUp()
    state = FileManager.default.temporaryDirectory
      .appendingPathComponent("msime-preferences-reload-\(UUID().uuidString)", isDirectory: true)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: state)
    super.tearDown()
  }

  private func reload(_ bridge: MetasequoiaInputSessionBridge) async -> MetasequoiaInputSessionBridge.PreferencesReload? {
    let reloaded = expectation(description: "reload")
    var outcome: MetasequoiaInputSessionBridge.PreferencesReload?
    bridge.reloadSharedPreferencesReportingOutcome { value in
      outcome = value
      reloaded.fulfill()
    }
    await fulfillment(of: [reloaded], timeout: 15)
    return outcome
  }

  /// 同一份文档连着读两次：第一次应用，第二次必须回报 `unchanged`，不能重复重放。
  func testSecondReadOfTheSameDocumentReportsUnchanged() async throws {
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    let firstOutcome = await reload(bridge)
    let first = try XCTUnwrap(firstOutcome)
    guard case .applied(let revision) = first else {
      return XCTFail("the first read of a new document has to apply, got \(first)")
    }

    let secondOutcome = await reload(bridge)
    let second = try XCTUnwrap(secondOutcome)
    XCTAssertEqual(second, .unchanged(revision))
  }

  /// 文档改了就必须重放，而且 revision 要往前走：去重不能把设置应用刚写下的值挡在外面。
  func testDocumentChangeAppliesAgainWithANewerRevision() async throws {
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    let firstOutcome = await reload(bridge)
    let first = try XCTUnwrap(firstOutcome)
    guard case .applied(let firstRevision) = first else {
      return XCTFail("the first read of a new document has to apply, got \(first)")
    }

    XCTAssertTrue(MetasequoiaInputSessionBridge.updateSharedPreferences(stateRoot: state) {
      var quanpin = $0["quanpin"] as? [String: Any] ?? [:]
      quanpin["autocorrect_transposition"] = false
      $0["quanpin"] = quanpin
    })

    let secondOutcome = await reload(bridge)
    let second = try XCTUnwrap(secondOutcome)
    guard case .applied(let secondRevision) = second else {
      return XCTFail("a changed document has to apply, got \(second)")
    }
    XCTAssertGreaterThan(secondRevision, firstRevision)
  }

  /// 旧的布尔回调仍然表达「偏好可用」：没变与刚应用都是 true，只有读不到才是 false。剪贴板历史这类「文档到了才启用」的行为靠它，去重不能把它关掉。
  func testBooleanCallbackStaysTrueWhenTheDocumentIsUnchanged() async throws {
    let bridge = MetasequoiaInputSessionBridge(stateRoot: state)
    let first = expectation(description: "first")
    var firstAccepted = false
    bridge.reloadSharedPreferences { firstAccepted = $0; first.fulfill() }
    await fulfillment(of: [first], timeout: 15)
    XCTAssertTrue(firstAccepted)

    let second = expectation(description: "second")
    var secondAccepted = false
    bridge.reloadSharedPreferences { secondAccepted = $0; second.fulfill() }
    await fulfillment(of: [second], timeout: 15)
    XCTAssertTrue(secondAccepted, "an unchanged document is still ready, not a failed read")
  }
}
