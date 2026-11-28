# Agent Note: iOS 键盘启动分段计时，首帧后不再重复重放，收起与后台放掉纯缓存

Status: implemented

## Problem

用户反馈 iOS 上唤起键盘偏慢，有时还会先显示零点几秒的空白再画出按键和工具栏；键盘显示出来之后，按下去和点收起也要等零点几秒才有反应，而且用一会儿就容易被系统结束、退回系统键盘。一份设备诊断包（47 次唤起、3 个键盘进程、909 行）里能看到两类浪费，但看不出时间：

- `mem+avail` 恒为 76 MB，全程贴着扩展上限；153 次 `memory_warning`，其中 149 次落在第一帧之前。每一次警告都走完整的释放流程：清主题缓存、跨输入线程清引擎缓存、重算候选外观。
- 每次唤起 3.06 遍整棵按键树换装；47 次唤起里按键音重载 39 次。

第一帧之前的全量释放基本是无用功：那时可选面板打不开，释义、翻译、候选画布的缓存都是空的，按键音正在加载；清掉主题与候选外观反而让首帧把颜色和候选条重算一遍，引擎清缓存还要跨一次输入线程。诊断日志原有的 `keyboard_loaded`、`keyboard_built`、`keyboard_shown` 只带内存读数，看不出启动时间落在哪一段，也看不出首帧之后主线程还在忙什么——用户说的「按下去没反应」不属于任何一段代码自己的耗时，只可能是主线程被占着。

## Decision

先让启动时间可分段度量，同时砍掉第一帧之前那批只会让首帧重算的释放。

- `MetasequoiaInputSessionBridge` 记下 `msimeClientPrepareHost` 的耗时（`hostPrepareMilliseconds`）。资源校验、把自定义辅助码表搬进状态根、写运行时选项都在这一次调用里，键盘启动时间的一大半通常落在这里而不是建界面。
- `KeyboardViewController` 记三段耗时，在 `viewDidAppear` 写完 `keyboard_shown` 之后补一行 `keyboard_timing`：`prepare_ms`（上面那段）、`built_ms`（`viewDidLoad` 开始到 `keyboard_built`）、`first_frame_ms`（`viewDidLoad` 开始到这一行）、`resume_ms`（`viewWillAppear` 里重建词库会话），以及 `deferred_warnings`。没发生的那段写 `-`。
- 第一帧之前（`hasDrawnFirstFrame` 为 false，且距 `viewDidLoad` 不到 `launchMemoryPressureWindow`＝2 秒）的内存警告不释放任何缓存：引擎缓存、主题与候选外观那时要么是空的，要么正是首帧要用的，而 `snapshotWorker`、`onlineCandidates` 这类懒加载对象在这一刻去停它们，反而会在内存最紧的时候把它们建出来。这一轮只写一行 `memory_warning suppressed=<n>`，不写 `memory_released`。第一帧之后、或过了两秒窗口，照旧走原来的全量释放，并把此前合并的次数一并记下。
- `KeyboardMemoryTests.composingKeyboard()` 补一次 `viewDidAppear(false)`：那几条用例量的是键盘显示之后的行为，而新的契约以第一帧为界。新增 `testMemoryWarningsBeforeTheFirstFrameAreDeferred` 钉住合并行为，`testKeyboardLaunchFootprintIsLoggedPerStage` 增加对 `keyboard_timing` 各字段的校验。

首帧之后另有两组改动：

- **共享文档没变就不再重放。** `reloadSharedPreferencesReportingOutcome` 把结果分成 `applied`（文档比这个进程应用过的新）、`unchanged`（同一版）与 `unavailable`（读不到）。`documentRevision` 只在活会话接受之后才记，所以相等就意味着这个进程已经应用过这一版，`viewWillAppear` 发起的那一轮十几个 `synchronize*`、外观重算和候选重画一个字段也不会变——而它常常正好排在首帧之后。旧的布尔回调保留，`unchanged` 仍算「偏好可用」，剪贴板历史这类「文档到了才启用」的行为不受影响。
- **主线程卡顿探针。** 后台每 40 ms 往主队列投一个空 block，主线程跑完就回报；超过 250 ms 没跑完记一行 `main_stall ms= stage=`，恢复时若明显更长再补一行 `main_stall_recovered`。阶段由主线程在关键路径上写（`build`、`session_resume`、`appearance`、`first_frame`、`preferences`、`key`、`dismiss`），只取代码里写死的英文单词。探针跟着诊断日志开关启停，`viewWillDisappear` 再停一次。判断逻辑单独放在 `KeyboardStallDetector` 里，喂时间就能测。
- **首帧之后的等待有了读数。** `first_frame_idle ms=` 是首帧到主线程把排着的那一轮跑完的时间；`preferences_applied ms=` 从首帧起算，偏好重放晚到时能看出它就压在触摸前面；`first_key ms=` 是第一帧到第一次按键被接住的时间；`dismiss_requested panel= reply= composing=` 先记下收起按钮的触摸有没有到；`keyboard_shown`、`memory_warning`、`memory_released` 后面附 `memoryParts`（候选画布、按键数、可见候选数、译文条数、按键音是否加载）。
- **收起与宿主进后台时放掉纯缓存。** `releaseRebuildableCaches` 清手写笔迹、主题解析结果、释义与译文；收起时另外放掉按键音播放器（下次出现按偏好在后台重载，不挡首帧）。候选画布的皮肤图两处都留着：收起再出现沿用已解码的那一份是有意的（`CandidateCanvasTests` 守着），宿主进后台时键盘还显示着、回来未必再走一次 `viewWillAppear`。两处都记一行 `caches_released`，带释放前后的内存读数。

## Alternatives considered

- **照 Android #10175 的做法，把建会话整个排到第一帧之后** — 那是这次真正想要的形状，但 iOS 上做不到同样小。`KeyboardViewController` 里有近 270 行直接引用 `session.`，而且首帧要用的偏好文档正是 `msimeClientPrepareHost` 的返回值：把准备推迟，`viewDidLoad` 就只能按 App Group 镜像或默认值画，方案、皮肤、候选配色会先错一遍再被重画，正好是 #11830 报告的那种闪烁和跳动。要做需要先把「只要偏好」拆成 `msimeClientLoadPreferences`（不需要会话句柄）的轻量快照，再逐个换掉 `viewDidLoad` 里的会话依赖，单独立项、单独验证。
- **不做分段计时，直接按猜测减内存** — 0.44–0.71 秒的准备耗时是日志里唯一确定的大块，但它和建界面、第一帧的占比没有数据；先减错地方会白改一轮。
- **按时间间隔去抖（例如一秒内只释放一次）** — 与现有用例冲突：`testTheMemoryWarningLinesTellWhenTheEngineCacheWasReleased` 在同一次运行里连着发两次警告，要求两次都释放（一次 `reset`、一次 `deferred`）。而且设备上那 149 次集中在第一帧之前，按阶段判断比按时间判断更准，也不依赖调度快慢。
- **第一帧之前仍走全量释放，只加计时** — 计时能看出哪一段慢，但设备日志里 149 次警告都在首帧之前，那每次都让首帧把主题、候选外观和引擎缓存重建一遍的开销会一直在，量出来的 `first_frame_ms` 也仍然混着这部分。
- **把新字段加到 `keyboard_loaded` 上** — 那一行已经接近诊断记录 192 字节的上限（`testTheLongestMemoryLineFitsTheRecord` 就守着这一点），加时间字段会把末尾的内存读数挤掉，所以单独写一行。
- **共享文档没变也照旧重放一遍** — 每个 `synchronize*` 自己都很便宜，看上去重复一次无害；但它们排在一起正好落在首帧之后，十几项加上外观重算和候选重画，就是用户按下去没反应的那零点几秒。分成 `unchanged` 与 `unavailable` 两部分，还能让「剪贴板历史已就绪」不再依赖「这一版文档刚被应用过」。
- **用 Instruments 采样或 `kdebug` 代替常驻探针** — 那些工具要在连机的开发环境里用，而用户报的是设备上偶发的一下；诊断日志要能从设备里导出、事后对照。探针只比时间戳，开销比一行日志还小。
- **宿主进后台时连候选画布的皮肤图一起放掉** — 键盘那时还显示着，回到前台未必再走一次 `viewWillAppear`，没有别的地方会重新加载那张图，候选条会一直按配色画。
- **收起键盘时连视图树一起拆掉** — 那样能省最多，但下次出现要重建 150–200 个按键，正好把这一轮省下的启动时间又还回去；控制器被复用时 `viewDidLoad` 也不会再跑，等于把「复用」变成「每次重建」。
- **在后台把 `prepareHost` 也推迟** — 见上一条：首帧要用的偏好就是它的返回值，推迟会先按镜像画错一遍，仍需要单独立项。

## Consequences

- **收益**：启动时间被拆成准备运行时、建界面、第一帧、重建会话四段，设备上可以直接看出该减哪一块；第一帧之前的 149 次全量释放变成一行日志，省掉重复的主题解析、候选外观重算和跨输入线程清缓存；按键音不再在启动阶段被反复释放重载（同一份日志里 47 次唤起重载了 39 次）。首帧之后再也不用为一份没变的文档跑那一串同步与外观重算，`main_stall`/`first_frame_idle`/`first_key` 能把「显示出来但点不动」定位到具体阶段；收起与后台不再带着释义译文和已解码的按键音常驻，后台被 jetsam 结束的概率随之下降。
- **代价**：诊断日志开着时多一个每 40 ms 敲主队列的后台定时器（只比时间戳，不采样、不建视图）；收起后第一次打字前按键音要重新加载，最坏头几个键退回系统按键声；后台放掉释义与译文后，回前台第一次出候选要重新取一遍，联网翻译会多一次请求。
- **重访信号（首帧后）**：真机日志里若 `main_stall` 集中在 `preferences` 阶段，说明文档确实每次都在变，下一步要查是谁在写；若集中在 `appearance`，说明整树换装仍需削减。`preferences_unchanged` 与 `preferences_applied` 的比例能直接说明去重省掉了多少轮。`caches_released` 前后内存差很小，说明常驻大头不在这些纯缓存上，得转向引擎会话与视图本身。
- **重访信号（启动）**：真机日志里 `keyboard_timing` 的 `prepare_ms` 若明显大于 `built_ms` 与 `first_frame_ms` 之和，下一步该做的是把准备运行时挪出首帧（即上面被否决的那条，需要先拆偏好读取）；若 `deferred_warnings` 很大而 `first_frame_ms` 仍不动，说明瓶颈不在内存压力，回到建界面与布局。

## Verification

- 新增 `testMemoryWarningsBeforeTheFirstFrameAreDeferred`：第一帧之前连发两次警告，日志里是 `memory_warning suppressed=2` 且没有 `memory_released`。
- `testKeyboardLaunchFootprintIsLoggedPerStage` 增加 `keyboard_timing` 校验：`built_ms`、`first_frame_ms` 必须是毫秒数，`prepare_ms`、`resume_ms` 允许是 `-`。
- `KeyboardMemoryTests` 原有的三条内存警告用例改为在 `viewDidAppear` 之后发警告，契约不变（一次 `engine_cache=reset`、一次 `engine_cache=deferred`，上屏后一行 `engine_cache_reset`）。
- 新增 `PreferencesReloadOutcomeTests`：同一份文档连着读两次，第二次必须是 `unchanged(revision)`；写一个字段之后必须 `applied` 且 revision 更大；旧的布尔回调在 `unchanged` 时仍是 `true`，剪贴板历史的启用条件不被去重关掉。
- 新增 `KeyboardStallDetectorTests`：短于阈值不报、超时只报一次下界、恢复时明显更长才补准确值、后台没赶上时由主线程记、相差不到 100 ms 不重复写、上一拍还挂着时不再投。
- 未验证：没有真机数据。模拟器不给 `avail`、也不设扩展上限，`deferred_warnings` 与两秒窗口的实际效果只能在设备上确认；首帧之前不清缓存对 jetsam 的影响同样需要真机复测。`main_stall`、`first_frame_idle`、`first_key`、`caches_released` 这几行是这次加在设备上的读数，本轮既没有真机日志，也没有模拟器上的卡顿复现，只能确认它们不改变现有用例的断言。
