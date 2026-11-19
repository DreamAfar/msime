import Foundation

/// 按住 ⌫ 横滑删除：按住不放往左滑，滑多远删多少；不松手再往右滑，刚删掉的按原样一个个恢复；松手才算定下来。
///
/// 删的单位有两种（`Unit`）：组字时是组码（拼音字母、九键数字），删一格等于对引擎按一次 ⌫，恢复是把删掉的码按原顺序重打；没有组字时是光标前的文字，按字形（`Character`）一个个删，恢复是把删掉的字原样插回。这个类型只管「滑到这里该删到第几个」，真正去删和插回由键盘控制器做。
struct BackspaceSwipeDeletion: Equatable {
  /// 每删一个单位要往左滑的距离（pt），与空格横滑移光标的手感相近。
  static let step: Double = 14

  enum Unit: Equatable {
    /// 组字的组码：`original` 是开始滑时的整段码，删的是它末尾的若干个。
    case composition(original: String)
    /// 光标前的文字：`context` 是开始滑时光标前读得到的那段文字。
    case text(context: String)
  }

  let unit: Unit
  /// 这次滑动最多能删几个单位：组码的个数，或光标前读得到的字数。
  let available: Int
  /// 目前已经删掉的单位数。
  private(set) var applied = 0

  init(unit: Unit) {
    self.unit = unit
    switch unit {
    case .composition(let original): available = original.count
    case .text(let context): available = context.count
    }
  }

  /// 水平位移 `translation`（往左为负）对应应当删掉几个单位：往左每满一个 `step` 删一个，最多 `available`；滑回起点或往右都是 0。
  func target(translation: Double) -> Int {
    guard translation < 0, translation.isFinite else { return 0 }
    return min(available, Int((-translation / Self.step).rounded(.down)))
  }

  /// 滑到 `translation` 时要做的事：正数是还要再删几个，负数是要恢复几个，0 是不动。调用后 `applied` 记成新的目标。
  mutating func move(to translation: Double) -> Int {
    let goal = target(translation: translation)
    defer { applied = goal }
    return goal - applied
  }

  /// 恢复组码时要按顺序重打的码：已经删掉 `from` 个、要退回到只删 `to` 个时，原码里重新出现的那一段（`from` > `to`）。
  func retyped(from: Int, to: Int) -> [Character] {
    guard case .composition(let original) = unit, from > to else { return [] }
    let characters = Array(original)
    return Array(characters[(characters.count - from)..<(characters.count - to)])
  }

  /// 删文字时第 `index` 个（从 0 起，离光标最近的是 0）删掉的字，恢复时原样插回。
  func deletedText(at index: Int) -> String? {
    guard case .text(let context) = unit else { return nil }
    let characters = Array(context)
    guard index >= 0, index < characters.count else { return nil }
    return String(characters[characters.count - 1 - index])
  }

  /// 组字能不能按组码滑删：码不空、光标在末尾（删的总是末尾的码），而且每个码都是重打得回去的 ASCII 字母、数字或分词符 `'`。双拼的 `;`、假名、注音这类码不在其内，这时不接横滑，⌫ 照常按下删一个、按住连删。
  static func canRetype(composition: String, caret: Int) -> Bool {
    !composition.isEmpty && caret == composition.count
      && composition.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "'") }
  }
}
