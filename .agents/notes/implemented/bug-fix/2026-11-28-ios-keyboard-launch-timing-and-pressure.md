# Agent Note: iOS 键盘启动分段计时，首帧后不再重复重放，收起与后台放掉纯缓存

Status: implemented

## Problem

用户反馈 iOS 上唤起键盘偏慢，有时还会先显示零点几秒的空白再画出按键和工具栏；键盘显示出来之后，按下去和点收起也要等零点几秒才有反应，而且用一会儿就容易被系统结束、退回系统键盘。一份设备诊断包（47 次唤起、3 个键盘进程、909 行）里能看到两类浪费，但看不出时间：

- `mem+avail` 恒为 76 MB，全程贴着扩展上限；153 次 `memory_warning`，其中 149 次落在第一帧之前。每一次警告都走完整的释放流程：清主题缓存、跨输入线程清引擎缓存、重算候选外观。
- 每次唤起 3.06 遍整棵按键树换装；47 次唤起里按键音重载 39 次。

第一帧之前的全量释放基本是无用功：那时可选面板打不开，释义、翻译、候选画布的缓存都是空的，按键音正在加载；清掉主题与候选外观反而让首帧把颜色和候选条重算一遍，引擎清缓存还要跨一次输入线程。诊断日志原有的 `keyboard_loaded`、`keyboard_built`、`keyboard_shown` 只带内存读数，看不出启动时间落在哪一段，也看不出首帧之后主线程还在忙什么——用户说的「按下去没反应」不属于任何一段代码自己的耗时，只可能是主线程被占着。

加上第一版计时之后，真机复测（同一进程 8 次唤起）把缺口量出来了：进程内第一次唤起 `first_frame_ms=1813`，其中 `built_ms=235`，剩下 1578 ms 全在 `keyboard_built` 之后；之后 7 次稳定在 482–526 ms，`prepare_ms` 67–79、`built_ms` 137–151，也就是说 **343–375 ms 落在 `keyboard_built` 到首帧之间**，而这一段当时一行读数都没有。同一份日志里还能看到底行的地球键在 `viewDidLoad` 与连上宿主之间读到了不同的值，`viewDidLayoutSubviews` 为此把整棵键盘又排了一遍——`needsInputModeSwitchKey` 在扩展连上宿主之前只是默认值，布局却把它当成了结论。

第二版把地球键按进程记住、并把这一段的四段打点补上后，同一台设备上 `first_frame_ms=353`：`prepare_ms=69`、`built_ms=143`、`will_appear_ms=296`、`window_skin_ms=9`、`layout_ms=0`、`resume_ms=25`。也就是说 `viewIsAppearing` 到首帧只剩 57 ms，**153 ms 落在 `viewWillAppear` 里**（减去重建会话的 25 ms 仍有约 128 ms 没有归属），同时 `layouts=10`——整棵键盘在首帧前被排了十遍。同一个进程里另外七次唤起仍然是 350 ms 上下，`layouts` 也仍是两位数，说明这不是地球键那一条路径，而是每次出现固定的重排。用户在同一版上仍然看到「先出现白色键盘底框、再出现按键」，截图里只有系统在扩展外面画的那条底栏（地球键与麦克风）和键盘底板，扩展自己的视图还什么都没画：这段空白就是首帧之前的等待，`first_frame_ms` 有 350 ms 时肉眼一定能看到。

`layout_ms=0` 说明单遍布局本身不贵，但那只量了 `viewDidLayoutSubviews` 回调自己的时间；每遍重设几百条约束后重新解算整棵键盘发生在回调之外，十遍加起来是多少没有任何读数。

第三版（`616edbe`）的真机数据把两个判断同时修正了。冷启动 `first_frame_ms=545`、`built_ms=169`、`will_appear_ms=489`，而同一进程里先前测到的 353 ms 是热态，两者不能直接比；`keyboard_loaded` 那行的 `base=` 这次是 30 MB 而不是 47 MB，说明进程基线也不是常量。更要紧的是 `layout_total_ms=8`：首帧前那九遍布局总共只花 8 ms，`layouts` 是十遍还是九遍都只是噪音，**布局从头到尾不是瓶颈**。而 `will_spans` 只写到 `sync:` 就断了——`DiagnosticLog` 把每条记录截到 192 字节，字段一多，后面的分段在真机上被静静砍掉；读日志的人只会看到一段没有结尾的名字，把它当成「这段没走到」。同一批数据里 `prefs` 与 `layout` 都是 0 ms，`theme` 13 ms、`session` 34 ms，也就是说 `will_appear_ms − built_ms` 那 320 ms 里约 273 ms 落在 `sync` 那一段（读宿主输入框、一串偏好同步、候选条、换装、回复键盘），而它恰恰是被截掉的那半截。

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
- **首帧前的空白段也分段。** `keyboard_timing` 增加 `will_appear_ms`（`viewWillAppear` 走完时从 `viewDidLoad` 起算）、`window_skin_ms`（`viewIsAppearing` 补窗口换装）、`layout_ms`（首帧前最后一次 `viewDidLayoutSubviews`）与 `layouts=`（这次出现调了几遍 `updateKeyboardLayout`）。四段加起来对上 `first_frame_ms` 与 `built_ms` 之差，就能判断三百多毫秒里是偏好准备、整树换装还是布局占着。
- **地球键按进程记住，布局不再问系统。** 新增 `layoutRequiresGlobeKey`：本次出现解析过就用本次的值，其次用同一扩展进程里上一次解析的值，都没有才读 `needsInputModeSwitchKey`。布局里所有读 `needsInputModeSwitchKey` 的地方（`layoutInputs`、底行宽度表、九宫格借位、日文模式列、`viewDidLayoutSubviews` 的核对）都改成读它。每次出现只解析两次：`viewWillAppear` 里一次（`trustingFalse: false`，此时系统只会说「不要」，那个 false 是默认值，不覆盖上一次记下的「要」），进窗口后的 `viewDidLayoutSubviews` 核一次真值，首帧后那一轮异步刷新里再兜底一次。进程级缓存只在 `.appex` 里生效，测试宿主 `.xctest` 不看它，用例之间不会互相带上一个值。
- **`viewWillAppear` 逐段计时。** `will_appear_ms` 只说这一段一共 153 ms，拆成 `keyboard_spans` 里的 `theme:…,prefs:…,layout:…,session:…,sync:…,candidates:…,skin:…,reply:…`，按代码里现成的分段点取时间差，用逗号隔开（日志字段之间是空格）。只量这一次出现的第一帧。
- **`layout_total_ms`：十遍布局到底值多少。** `layout_ms` 量的是 `viewDidLayoutSubviews` 回调自己，约束重设后重新解算整棵键盘发生在回调之外；在 `updateKeyboardLayout` 开头取时刻、用 `defer` 累加，行尾与 `layouts=` 并排，一眼能看出「十遍很贵」还是「十遍是噪音」。
- **`updateKeyboardLayout` 末尾记下这一遍用的输入。** `appliedLayoutInputs` 原先只在 `updateKeyboardLayoutIfNeeded` 里、调用之前写；直接调用 `updateKeyboardLayout` 的三处（建界面、`viewDidLayoutSubviews` 里的底行重排、分离切换）不写，紧接着的 `updateKeyboardLayoutIfNeeded` 拿它和 nil 或旧值比，判定「变了」再整棵排一遍。现在每遍结束时按当时的值写一次，`viewDidLayoutSubviews` 里 `numberRowFits` 的那次核对比的也是最新一遍的结果。
- **超长记录不再静默截断。** 新增 `DiagnosticLog.recordBody`：正文超过 `maxEventBytes` 时截到上限再补 ` ~truncated`，`write` 改用它。`sanitize` 的可打印 ASCII 约束与 192 字节上限都没变——那是「调用点写错也不会把输入内容带进文件」的安全边界——只是被截掉时留个痕迹。
- **阶段与分段各占一行，并把那个大段再拆开。** `keyboard_timing` 只留 `prepare_ms`、`built_ms`、`first_frame_ms`、`will_appear_ms`、`resume_ms`、`deferred_warnings`；`keyboard_phases` 单独记 `window_skin_ms`、`layout_ms`、`layout_total_ms`、`layouts`；`keyboard_spans` 单独记分段。分段本身也拆细了：第一段 `enter` 从 `viewDidLoad` 结束那一刻起算，量的是 UIKit 建完界面到把这次出现交回来（含 `super`）的时间；`synchronizeInputContext` 之后单记一段 `context`，因为它要跨进程读宿主输入框；原来那一大段 `sync` 改名 `prefsync`，只覆盖那一串偏好同步。

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
- **把 `updateKeyboardLayout` 拆出「只重排底行」的轻量版本** — 地球键只影响底行那几个键的显隐与宽度，理论上可以只重排 `actionRow`。但 `arrangeActionRow` 的入参是从 `updateKeyboardLayout` 的十几个局部变量（键面、层、数字页、样式与分离状态）算出来的，抽取面几乎覆盖整个函数，回归风险高于收益；先按进程记住地球键把这一遍整树排掉，改的只是读值处。
- **首帧前不排布局，等确认连上宿主再排** — 没有可靠的「连接已建立」回调，`viewDidAppear` 是唯一确定点，等到那里等于首帧前没有键盘；键盘被挡住时还可能永远等不到。
- **每轮 `viewDidLayoutSubviews` 都读真值核对地球键** — 最直白，但 `needsInputModeSwitchKey` 每次读都要问输入系统，设备日志里一轮出现读二十余次就是布局反复读它造成的；改成每次出现只核一次，值错了也只在首帧前多排一遍。
- **先猜「十遍布局」是空白帧的原因，直接去掉几条重排路径** — `layout_ms=0` 说明最后一遍本身不贵，十遍加起来是否可观没有任何读数；在没有 `layout_total_ms` 之前删路径，等于把回归风险押在猜测上。
- **把空白帧当成本地渲染问题（以为按键没画出来）去查绘制** — 截图里能看到的那条底栏（地球键、麦克风）是 iOS 在所有第三方键盘下方画的系统区域，扩展只能画在它上面；扩展自己的视图那时还没出第一帧。要缩短的是首帧时间，不是绘制路径。
- **把 `maxEventBytes` 从 192 调大，让 `will_spans` 挤在同一行** — 那 192 字节是「调用点写错也不会把输入内容带进文件」的边界（`testEventsAreCutToPrintableAscii` 守着），为一行调试字段放宽它，等于让所有调用点一起冒这个险；拆成几行更划算，还顺手让截断变得可见。

## Consequences

- **收益**：启动时间被拆成准备运行时、建界面、第一帧、重建会话四段，设备上可以直接看出该减哪一块；第一帧之前的 149 次全量释放变成一行日志，省掉重复的主题解析、候选外观重算和跨输入线程清缓存；按键音不再在启动阶段被反复释放重载（同一份日志里 47 次唤起重载了 39 次）。首帧之后再也不用为一份没变的文档跑那一串同步与外观重算，`main_stall`/`first_frame_idle`/`first_key` 能把「显示出来但点不动」定位到具体阶段；收起与后台不再带着释义译文和已解码的按键音常驻，后台被 jetsam 结束的概率随之下降。首帧前那 343–375 ms 现在拆成出现准备、窗口换装、布局三段，`layouts=` 能直接看出整棵键盘排了几遍；同一个进程里第二次唤起不必再为地球键多排一遍，底行首帧前就按对的值画出来，布局里也不再反复向输入系统查询这个值。第三版把 `viewWillAppear` 里的 153 ms 再拆成八段、把十遍布局的累计耗时单列，并让每一遍布局结束时记下自己用的输入：直接调用之后紧跟一次 `updateKeyboardLayoutIfNeeded` 的那类重复重排不再发生。第四版把这一行按 192 字节上限拆成三行，分段不会再被截掉，并把原本那一段 `sync` 再分成 `enter`、`context`、`prefsync`——真机上九遍布局合计只有 8 ms，布局这条线可以就此排除。
- **代价**：诊断日志开着时多一个每 40 ms 敲主队列的后台定时器（只比时间戳，不采样、不建视图）；收起后第一次打字前按键音要重新加载，最坏头几个键退回系统按键声；后台放掉释义与译文后，回前台第一次出候选要重新取一遍，联网翻译会多一次请求。
- **重访信号（首帧后）**：真机日志里若 `main_stall` 集中在 `preferences` 阶段，说明文档确实每次都在变，下一步要查是谁在写；若集中在 `appearance`，说明整树换装仍需削减。`preferences_unchanged` 与 `preferences_applied` 的比例能直接说明去重省掉了多少轮。`caches_released` 前后内存差很小，说明常驻大头不在这些纯缓存上，得转向引擎会话与视图本身。
- **重访信号（启动）**：真机日志里 `keyboard_timing` 的 `prepare_ms` 若明显大于 `built_ms` 与 `first_frame_ms` 之和，下一步该做的是把准备运行时挪出首帧（即上面被否决的那条，需要先拆偏好读取）；若 `deferred_warnings` 很大而 `first_frame_ms` 仍不动，说明瓶颈不在内存压力，回到建界面与布局。
- **重访信号（地球键）**：稳态唤起的 `layouts=` 应为 1。若常见 2 而 `window_skin_ms` 很小，说明多排的那遍来自首帧前的地球键核对（用户常在增删输入法），这时才值得去做「只重排底行」；若同时 `window_skin_ms` 接近那三百毫秒，问题在 `viewIsAppearing` 的整树换装，先查 `keySkinNeedsWindowPass` 为什么每次出现都为真。
- **重访信号（空白帧）**：`first_frame_ms` 超过约 200 ms 时，第三方键盘下方那条系统底栏会先于扩展的画面上屏，用户看到的就是「先白底框、再出按键」。`layout_total_ms` 已经把布局排除在外（九遍合计 8 ms），不必再为它花时间。接下来只看 `keyboard_spans`：`enter` 占大头说明时间在 UIKit 交回之前，改不了；`context` 占大头说明首帧前读宿主输入框在等跨进程返回；`prefsync` 占大头时要先分清正式包与未签名包——未签名包没有 App Group，一次出现几十行 `client is not entitled`，每次读取都走一遍注定失败的 container lookup，这一段的数字在正式签名之前不可信。
- **重访信号（截断）**：日志里出现 ` ~truncated` 就说明那条记录又长过 192 字节了，字段该再拆一行，而不是继续往里加。

## Verification

- 新增 `testMemoryWarningsBeforeTheFirstFrameAreDeferred`：第一帧之前连发两次警告，日志里是 `memory_warning suppressed=2` 且没有 `memory_released`。
- `testKeyboardLaunchFootprintIsLoggedPerStage` 增加 `keyboard_timing` 校验：`built_ms`、`first_frame_ms` 必须是毫秒数，`prepare_ms`、`resume_ms` 允许是 `-`。
- `KeyboardMemoryTests` 原有的三条内存警告用例改为在 `viewDidAppear` 之后发警告，契约不变（一次 `engine_cache=reset`、一次 `engine_cache=deferred`，上屏后一行 `engine_cache_reset`）。
- 新增 `PreferencesReloadOutcomeTests`：同一份文档连着读两次，第二次必须是 `unchanged(revision)`；写一个字段之后必须 `applied` 且 revision 更大；旧的布尔回调在 `unchanged` 时仍是 `true`，剪贴板历史的启用条件不被去重关掉。
- 新增 `KeyboardStallDetectorTests`：短于阈值不报、超时只报一次下界、恢复时明显更长才补准确值、后台没赶上时由主线程记、相差不到 100 ms 不重复写、上一拍还挂着时不再投。
- `testKeyboardLaunchFootprintIsLoggedPerStage` 追加 `will_appear_ms`、`window_skin_ms`、`layout_ms`、`layouts` 四个字段的数字校验：前三个没走到的段记 0，不写 `-`，这样「没发生」和「没记」在设备日志里分得开。第三版再加 `layout_total_ms` 的数字校验，并把 `will_spans` 按逗号拆开、逐段校验 `名字:毫秒数`，保证这一行在字段之间只用空格分隔的日志里不会被拆成别的字段。第四版随字段拆行调整：`keyboard_timing` 校验 `built_ms`、`first_frame_ms`、`will_appear_ms`，`keyboard_phases` 校验四个阶段字段，`keyboard_spans` 取整行按逗号逐段校验。
- 新增 `testOverlongRecordsMarkTheTruncation`：500 字节的记录仍截到 `maxEventBytes`，但末尾是 ` ~truncated`；短记录原样通过。
- 未验证：没有真机数据。模拟器不给 `avail`、也不设扩展上限，`deferred_warnings` 与两秒窗口的实际效果只能在设备上确认；首帧之前不清缓存对 jetsam 的影响同样需要真机复测。`main_stall`、`first_frame_idle`、`first_key`、`caches_released` 这几行是这次加在设备上的读数，本轮既没有真机日志，也没有模拟器上的卡顿复现，只能确认它们不改变现有用例的断言。
