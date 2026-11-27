import UIKit

/// 长按菜单优先贴在按键上方；上方放不下（顶排键）就翻到按键下方，仍留在扩展可命中的边界内。
/// 键盘扩展画不出自己的窗口，菜单不能像系统键盘那样浮在键盘外面，只能盖住相邻的键行；
/// 盖住下面一排比盖住手指正按着的那个键更好，所以先看上方空间够不够。
@MainActor
enum KeyboardHoldOptionsLayout {
  static func activate(_ options: UIView, from key: UIView, in container: UIView) {
    let size = options.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
    let target = key.convert(key.bounds, to: container)
    let fitsAbove = target.minY - 6 - size.height >= 6
    let anchor = fitsAbove
      ? options.bottomAnchor.constraint(equalTo: key.topAnchor, constant: -6)
      : options.topAnchor.constraint(equalTo: key.bottomAnchor, constant: 6)
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
