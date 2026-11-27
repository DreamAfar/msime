import UIKit

/// 长按菜单始终贴在按键上方，不再翻到下面。
///
/// 键盘扩展画不出自己的窗口，菜单不能像系统键盘那样浮在键盘外面，只能盖住相邻的键行。原先顶排键上方放不下时
/// 会翻到按键下方：同一个长按，第 1 排和个别第 2 排的键在指下弹出，与其余键不一致。现在统一放上方——
/// 上方确实不够高时由容器的顶边约束把它压回键盘内，宁可盖住这一排自己，也不换到手指底下。
@MainActor
enum KeyboardHoldOptionsLayout {
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
