import UIKit

/// 长按菜单始终贴在按键上方，不再翻到下面。
///
/// 键盘扩展画不出自己的窗口，菜单不能像系统键盘那样浮在键盘外面，只能盖住相邻的键行。原先顶排键上方放不下时
/// 会翻到按键下方：同一个长按，第 1 排和个别第 2 排的键在指下弹出，与其余键不一致。现在统一放上方——
/// 上方确实不够高时由容器的顶边约束把它压回键盘内，宁可盖住这一排自己，也不换到手指底下。
@MainActor
enum KeyboardHoldOptionsLayout {
  /// 气泡里每个选项格子的宽度；按住不放左右滑动时按这个宽度换算高亮到第几项。
  static let itemWidth: CGFloat = 36
  /// 相邻格子的间隔，与气泡里 UIStackView 的 spacing 一致。
  static let itemSpacing: CGFloat = 4

  /// 按住字母键左右滑动时，手指相对按下点的水平位移落在第几个选项上。
  ///
  /// 以按下点为原点：向右每挪过一个格子（宽 + 间隔）就高亮下一项，向左对称；不足半格仍算原地，
  /// 结果夹在 `[0, count-1]`，所以不会滑出选项范围。选项多于一行时按从左到右、从上到下的顺序连续计数，
  /// 与气泡按钮的排列一致。
  static func highlightedIndex(dx: CGFloat, count: Int) -> Int {
    guard count > 0 else { return 0 }
    let step = itemWidth + itemSpacing
    let shifted = (dx / step).rounded()
    return min(count - 1, max(0, Int(shifted)))
  }

  static func activate(_ options: UIView, from key: UIView, in container: UIView) {
    let anchor = options.bottomAnchor.constraint(equalTo: key.topAnchor, constant: -6)
    anchor.priority = .defaultHigh
    let centred = options.centerXAnchor.constraint(equalTo: key.centerXAnchor)
    centred.priority = .defaultHigh
    NSLayoutConstraint.activate([
      anchor, centred,
      options.topAnchor.constraint(greaterThanOrEqualTo: container.topAnchor, constant: 6),
      options.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -6),
      options.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 6),
      options.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -6),
    ])
  }
}
