# Agent Note: iOS 字母键长按弹出字符选项

Status: implemented

## Problem

用户拿 iOS 系统键盘作参照：长按 `e` 弹出 `é è ê ë` 供选，希望水杉也能长按字母键选字符；进一步提出「可以设置成长按弹出多个符号供选择上屏」。

现状是长按已经被占用：26 键字母键按住 0.5 秒会**直接输入右上角的角标符号**（`KeyboardKeyButton.cornerHintHoldDelay` + `triggerCornerHint`），设置页也明确写着「按住字母键始终输入角标」。所以这不是新增一个手势，而是换掉长按的语义。

Android 早已实现这套交互：英文走 `EnglishLetterHoldPolicy.choices`（大写、角标、上下标、声调、数字变体），中文走 `showLetterOptions`（小写、大写、角标），长按弹出 `PopupWindow` 并支持拖选；iOS 只有九键和 14/18 键有长按菜单，26 键字母没有跟上。

## Decision

- 长按 0.5 秒改为**弹出选项**：复用九键已有的 `showKeyHoldOptions`（背板 + 一排按钮 + `KeyboardHoldOptionsLayout`），点一项上屏。角标不再由长按直接输入，而是作为选项里的一项保留；滑动出角标完全不变。
- 默认表对齐 Android（`LetterHoldPreference.defaults`）：
  - 中文：这个键的小写、大写、角标，以及 **a/e/i/o/u** 的四个声调。`e` → `e E 3 ē é ě è`；`q` → `q Q 1`。
  - 英文：同上的大小写与角标，另加 `ê`、`v` 的 `üǖǘǚǜ`、`n` 的 `ńňǹ`、`m` 的 `ḿ`，以及该字母存在的上标、下标。
  - 中文只给 a/e/i/o/u 是用户明确要求；英文用 Android 的全表。Unicode 没有的上下标（q/w/y/z 等）不列。
- 一个键最多 **10 项**：弹窗五列一行、最多两行，两行正好十个；再多会盖住半个键盘。`normalize` 负责单字素、去重、过滤空白与控制字符。
- 逐键自定义存本机 App Group 的 `keyboard.gesture.letterHoldOptions`（JSON `{"e":[...]}`），总开关是 `keyboard.gesture.letterHoldOptionsEnabled`，默认开。**空数组是「这个键不弹」**，长按回到输入角标；缺键才是「跟随默认」。总开关关掉时全部回到输入角标，与改动前一致。
- **组字中长按等同点按**（`KeyboardKeyButton.holdSuppressed` 读控制器的 `hasComposition`）：与 Android 的 `candidateTapsOnly` 一致。否则选一个音调会把拼音组字结束掉，属于事故。
- 选中项**按字面上屏**：先 `finishComposition`，再 `insertDirectText`（`commitNineKeyHoldOption`）。音调、上下标不是拼音编码，不能交给引擎；角标也沿用这条（26 键原本就是 `insertSymbolLayerLiteral`）。
- 弹窗定位先量高度：上方放得下就贴键上方，顶排键放不下就翻到键**下方**。键盘扩展画不出自己的窗口，菜单不能像系统键盘那样浮在键盘外，盖住下面一排比盖住手指正按着的键好。
- 设置页「键盘 → 手势」新增「长按弹出选项」总开关；逐键入口复用预览图字母键的编辑页，在滑动分组下面新增「长按弹出」：输入框按字素连着写，保存后回显规范化结果，留空保存即不弹，「恢复默认」回去掉逐键覆盖。`letterSwipeEditable` 从「滑动总开关开着」放宽为「滑动或长按选项开着」，否则关掉滑动后逐键长按清单没有入口。
- 读屏没有长按动作，字母键挂一个「显示长按选项」的 `UIAccessibilityCustomAction`，打开同一份弹窗。
- 「重置所有设置」的本地清单补上这两个键。

## Alternatives considered

- **保留长按出角标，另找手势弹选项**：滑动方向已经分给了逐键动作，双击、重按都会和系统行为或现有手势冲突；用户明确要的就是长按。
- **中文也给 v/n/m 的声调**：用户选了「中文只给 a/e/i/o/u」。`ü` 在中文里由 `v` 键输入，但音调只在注音、教学这类场景用得上，多数人不需要。
- **把选项数量上限设成 12（与快捷符号一致）**：12 项要三行，弹窗高度接近一个键行；两行十项已经够放一套音调加角标。
- **拖选（iOS 系统键盘那样按住滑到某一项松手）**：需要把按键的触摸接力给弹窗、做高亮命中与取消阈值；本机没有 Xcode，无法编译验证，先与九键菜单统一成「松手后再点一项」。
- **英文 o 也放 Android 的「⮕ 切拼音键盘」**：iOS 底行本来就有中/英键，再放一个切换项只会让选项更长。
- **把逐键清单写进共享文档随账号同步**：与字母键滑动、底行滑动一致，手感跟设备走；跨端字段还要其他客户端认识新动作。

## Consequences

- 长按的手感变了：以前按住半秒松开就出角标，现在弹出选项后要再点一项；想快速输入角标仍可沿设定方向滑动，或在弹窗里点它。
- 组字中长按不再出角标，松手输入的是这个字母（Android 同款）；上屏后联想不算组字，长按照常弹选项。
- 自定义清单一旦保存就固定，不随中英文切换；默认表才随语言变。编辑页的说明写明了这一点。
- 中文模式长按 `e` 会列出大写 `E`，点它按字面上屏大写字母，不进入拼音组字；这是长按菜单的语义，不是点键。
- 弹窗里音调、上下标都按字面插入，全角开关照常作用（`insertDirectText`）；角标也走同一条。
- 顶排键的弹窗会盖住第二排；九键和 14/18 键的弹窗也一起换成了「上方放不下就翻到下方」，之前是压回键盘顶部、盖住被按的键。
- 26 键以外的键盘没有改：九键、14/18 键、日文假名各有自己的长按菜单或 flick。

## Testing

`KeyboardTests/input/LetterCornerHintTests.swift` 新增三条：

- `testLetterHoldDefaultsFollowTheLanguage`：中文 `e` 的七项、大写状态先列大写、`q` 只有三项、英文含 `ê` 且正好十项、中文 `v` 没有 `ü`、非字母没有选项。
- `testLetterHoldOptionsStoreCustomListsAndEmptyMeansNoPopup`：自定义覆盖默认且不再跟语言变、单字素与去重、空数组等于不弹、`clear` 回到默认、总开关关掉后为空。
- `testLetterKeyLongPressShowsItsOptions`：字母键带着 `holdOptions` / `onHoldOptions` / 读屏自定义动作；中文 `e` 弹出七项，弹窗里有 `letterHoldOption-é`；设成空列表后不再弹。

`scripts/test-ios-key-layout-settings.py` 更新了预览键可编辑的条件，并新增总开关与逐键输入框、保存按钮的断言（33 项通过）。

本机是 Windows，没有 Xcode / Swift 工具链：Swift 单测**没有编译、没有运行**，只做了静态核对与括号平衡比对。需要在 macOS 上跑 `MSIMEKeyboardTests`，并在真机验收：中文组字中长按不出弹窗、空闲时长按 `e` 弹出并上屏 `é`、顶排键弹窗翻到下方、关掉总开关后长按回到角标、逐键保存空清单后该键不弹。

## Related notes

- [iOS 26 键上滑、下滑各一个可配动作](2026-11-23-ios-letter-two-way-swipe-actions.md)：长按原来与滑动共用角标；本次把长按拆成独立选项，滑动路径不动。
- [iOS 底行按键上滑、下滑与「上屏候选译文」](2026-11-27-ios-bottom-key-swipe-actions.md)：同一页设置的手势分组，新增的总开关排在「显示字母键角标」之后。
- [iOS 符号页输入后返回字母键盘](2026-11-27-ios-symbol-return-to-letters.md)：同一批设置页改动，互不影响。
