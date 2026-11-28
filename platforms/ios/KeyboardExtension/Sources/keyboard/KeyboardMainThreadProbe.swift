import Foundation

/// 主线程有没有被占住：键盘「已经显示出来，但按下去没反应」这种反馈，现有日志看不出来。
///
/// 日志里的 `keyboard_timing`、`dictionary_resumed` 只说明某一段代码自己花了多久，说明不了那段时间主线程在忙什么：一段 30 ms 的代码连着跑十几次，或者一次同步跨进程调用卡住，单看每一行都不显眼，加起来就是用户感觉到的「要过零点几秒才能打字」。
///
/// 这里不采样调用栈，只回答两个问题：主线程连续多久没有跑完一个空转的 block，以及那时阶段标记是什么。阶段由主线程在关键路径上写（`mark`），后台读；标记只取自代码里写死的英文单词，不含输入内容、路径或候选。动作本身是后台每 40 ms 往主队列投一个空 block，只比 `systemUptime`，不开定时器、不建视图。
///
/// 判断逻辑单独放在 `KeyboardStallDetector` 里，它只收时间戳、只返回该记什么，不碰时钟也不写日志，单测可以直接喂时间。
final class KeyboardStallDetector: @unchecked Sendable {
  /// 一次卡顿要记的东西。`milliseconds` 是这次卡顿的下界：后台发现超时的那一刻还不知道主线程后来卡了多久，`recovered` 为 true 的那条才是准确值。
  struct Event: Equatable {
    let milliseconds: Int
    let stage: String
    let recovered: Bool
  }

  private let lock = NSLock()
  private var stage = "launch"
  private var pendingSince: TimeInterval?
  /// 这一次卡顿已经记过的下界（毫秒）；nil 表示还没记。
  private var reportedMilliseconds: Int?
  private let threshold: TimeInterval

  /// `threshold` 以下不记：一次正常的布局或换装本来就要几十毫秒，全部记下来只会把日志灌满。
  init(threshold: TimeInterval = 0.25) {
    self.threshold = threshold
  }

  /// 主线程进入某个阶段。只在主线程调用，必须在锁外拿字符串，锁里只存一份引用。
  func mark(_ stage: String) {
    lock.lock()
    self.stage = stage
    lock.unlock()
  }

  /// 后台每轮问一次：主线程上一轮的空 block 还没跑完时返回 true，调用方不必再投一个。
  func hasPendingBeat() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pendingSince != nil
  }

  /// 记录这一轮投出去的时刻。返回 true 时调用方才投 block；`false` 说明上一轮还挂着。
  func beginBeat(at now: TimeInterval) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard pendingSince == nil else { return false }
    pendingSince = now
    return true
  }

  /// 后台看这次挂起是否已经超过阈值。返回事件时调用方记一行 `main_stall`；同一次卡顿只返回一次。
  func overdueEvent(at now: TimeInterval) -> Event? {
    lock.lock()
    defer { lock.unlock() }
    guard let since = pendingSince, reportedMilliseconds == nil else { return nil }
    let elapsed = now - since
    guard elapsed >= threshold else { return nil }
    let milliseconds = Int((elapsed * 1000).rounded())
    reportedMilliseconds = milliseconds
    return Event(milliseconds: milliseconds, stage: stage, recovered: false)
  }

  /// 主线程跑完了这一轮。已经记过下界、而真实时长明显更长时再补一条准确值；每次卡顿最多两条。
  func beat(at now: TimeInterval) -> Event? {
    lock.lock()
    defer { lock.unlock() }
    guard let since = pendingSince else { return nil }
    pendingSince = nil
    let elapsed = now - since
    let milliseconds = Int((elapsed * 1000).rounded())
    let reported = reportedMilliseconds
    reportedMilliseconds = nil
    flow: do {
      guard elapsed >= threshold else { break flow }
      // 后台那一轮还没赶上检查、主线程自己恢复了：这一次没人记过，这里记准确值。
      guard let reported else { return Event(milliseconds: milliseconds, stage: stage, recovered: false) }
      // 下界与准确值差不到 100 ms 时不必再写一行：日志里两条几乎一样的记录只会让人以为卡了两次。
      guard milliseconds - reported >= 100 else { break flow }
      return Event(milliseconds: milliseconds, stage: stage, recovered: true)
    }
    return nil
  }
}

/// 把 `KeyboardStallDetector` 接到主队列上：后台每 40 ms 投一个空 block，主线程跑完就回报。
///
/// 只在诊断日志开着时启动（隐私模式下日志本来就不写，探针自己也不该常驻）。探针跟着键盘的可见期走：`viewDidLoad` 启动，`viewWillDisappear` 停；键盘收起后主线程再怎么忙也不影响输入。
@MainActor
final class KeyboardMainThreadProbe {
  /// 两次心跳的间隔。取 40 ms 是为了在 250 ms 的阈值里至少能投出五、六次，设备再忙也不会因为探针自己的间隔而误报。
  static let beatInterval: DispatchTimeInterval = .milliseconds(40)

  private let detector: KeyboardStallDetector
  private let queue = DispatchQueue(label: "app.msime.ios.main-thread-probe", qos: .utility)
  private let report: @Sendable (String) -> Void
  private var timer: DispatchSourceTimer?

  init(threshold: TimeInterval = 0.25,
       report: @escaping @Sendable (String) -> Void = { DiagnosticLog.shared.write($0) }) {
    self.detector = KeyboardStallDetector(threshold: threshold)
    self.report = report
  }

  var isRunning: Bool { timer != nil }

  /// 日志开着时才跑：关掉（隐私模式、开关关闭）就停，不必为一行永远不会写的记录每 40 ms 敲一次主队列。`configureDiagnosticLog` 每次判定后调用。
  func setEnabled(_ enabled: Bool) {
    if enabled { start() } else { stop() }
  }

  /// 开始敲主队列。已经在跑时只更新阶段，不重复建定时器。
  func start() {
    guard timer == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + Self.beatInterval, repeating: Self.beatInterval,
                   leeway: .milliseconds(10))
    let detector = self.detector
    let report = self.report
    timer.setEventHandler {
      let now = ProcessInfo.processInfo.systemUptime
      if let event = detector.overdueEvent(at: now) {
        report("main_stall ms=\(event.milliseconds) stage=\(event.stage)")
      }
      guard detector.beginBeat(at: now) else { return }
      DispatchQueue.main.async {
        if let event = detector.beat(at: ProcessInfo.processInfo.systemUptime) {
          report("main_stall_recovered ms=\(event.milliseconds) stage=\(event.stage)")
        }
      }
    }
    timer.resume()
    self.timer = timer
  }

  /// 主线程进入某个阶段；`start` 之前调用只记下标记，等启动后用得上。
  func mark(_ stage: String) {
    detector.mark(stage)
  }

  func stop() {
    timer?.cancel()
    timer = nil
  }

  deinit {
    MainActor.assumeIsolated { timer?.cancel() }
  }
}
