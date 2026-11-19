# Trackpad tap prototype

手动启用的三指／四指轻点探测工具，用于验证内置 Multi-Touch 触控板与 Apple
妙控板的事件来源与轻点识别。默认只打印结果；显式传入 `--execute` 才发送
三指复制（⌘C）与四指粘贴（⌘V）。不修改 Mos 设置或系统设置。

Mos 的“偏好设置 → 通用”中提供“触控板轻点复制／粘贴”。默认关闭，勾选后仅本次运行
有效，退出 Mos 后关闭。开关下方说明两种手势；不可监听时显示提示并保持关闭。
当前外接设备保守限定为本机已验证的 family 129（Magic Trackpad），加上框架标记
为内置的非显示触控面。未知外接类型暂不启用，尚未承诺覆盖所有代际的妙控板。

## 构建与自动测试

在仓库根目录运行：

```bash
bash tools/trackpad/build.sh
bash tools/trackpad/test.sh
build/trackpad-probe/probe --help
```

构建不会启动监听器。工具位于 `build/trackpad-probe/probe`，兼容 Swift 5
语言模式，不要求修改 Mos 的最低系统版本。当前 Xcode 若已不支持 macOS 10.13，
工具会使用本机编译器的部署目标；这不代表已经验证了 macOS 10.13 运行兼容性。

`test.sh` 在独立 Swift Package 中运行 **同一个**
`MosTests/TrackpadTapRecognizerTests.swift` 与 `TrackpadTapInputTests.swift` 文件，
只替换测试模块的 import。共 46 项测试覆盖识别、输入状态和快捷键事件构造。
它使用模拟触摸帧，不启动 Mos，也不访问触控板，不需要设备权限。识别器位于
`Mos/InputEvent/TrackpadTapRecognizer.swift`，已纳入 Mos 自动同步的 app target；
测试文件已纳入 MosTests target。应用只有在偏好设置开关开启后才访问设备；
睡眠／用户切换／退出会停止监听，唤醒时恢复已开启的功能。撤销辅助功能权限
会停止监听，应用现有权限恢复流程会再次尝试恢复。

## 真实触控板试用

按仓库 `AGENTS.md`，真实设备和本机权限操作需经用户确认后执行。
一次监听默认 60 秒，最多 600 秒，按 Ctrl-C 可提前结束。

先验证公开接口：

```bash
build/trackpad-probe/probe --listen --source public --duration 60
```

它观察 AppKit 的本地／全局 `.gesture` 事件，通过 `allTouches()` 读取触摸点，
使用 `NSTouch.device` 区分设备。公开 API 存在并不保证其他应用收到的触摸序列
也会被完整转发给全局监听器。工具停止时会显示触摸帧、识别次数，以及不含触摸点
的手势事件数量。没有数据或缺少结束事件时，不会猜测并触发动作。

若公开接口收不到完整数据，再单独验证可选私有接口：

```bash
build/trackpad-probe/probe --listen --source private --duration 60
```

此模式动态加载系统 `MultitouchSupport.framework`，为它枚举出的设备注册触摸帧
回调。工具和 Mos 共用 `Mos/Trackpad/MultitouchBridge.c`，不静态链接私有框架；
只有启用监听才动态加载。回调会复制
触摸帧，再交给主线程识别；每个设备单独保存状态。睡眠／用户切换会停止监听，
恢复时重建；设备拓扑变化也会清空候选并重新注册。此模式使用未公开的 ABI，
需要验证具体系统和设备，系统升级可能造成失效。
首次启用或重连时，先让手指全部离开设备，等一个空闲帧后才接收新轻点，
避免从已有触摸序列中途开始。切换、休眠和重连会使排队的旧帧失效。

如果 macOS 限制事件监听，可由用户根据系统提示授予相应权限。工具不主动弹出
授权窗口或修改权限，缺少触摸数据时只记录结果。

## 实际复制／粘贴

在系统设置的辅助功能列表中为探测程序授予权限后：

```bash
build/trackpad-probe/probe --listen --source private --duration 60 --execute
```

未获辅助功能权限时，该命令返回状态码 3，不启动监听，也不弹授权窗口。
不开 `--execute` 的命令仍只识别。实际试用时请在文本编辑器的新文档中放一行
可辨识的测试文字，用鼠标选中后做三指轻点，再把插入点移到空白处做四指轻点，
确认复制的内容被贴入。先把手指移开触控板，再开始每组轻点。

探测程序和应用共用轻点输入状态及键盘事件构造代码；每次动作先创建完整
keyDown / keyUp 对（按下带 ⌘，抬起清除修饰键），使用私有事件源与 Mos 合成事件标记，避免被按键映射／录制
再次处理。应用会跳过菜单交互以及按住 ⌘⌥⌃⇧ 时的动作，避免与键盘操作冲突。

## 人工验收顺序

在内置触控板和妙控板上各执行一次下面的检查。用文本编辑器、浏览器等其他应用
作为前台，避免只验证当前终端。

| 操作 | 预期识别结果 |
| --- | --- |
| 三指轻点，连续 20 次 | 每次只显示一次“三指 → 复制” |
| 四指轻点，连续 20 次 | 每次只显示一次“四指 → 粘贴”，不显示三指复制 |
| 手指稍微错开落下／抬起 | 以完整的一次多指轻点判定 |
| 单指、双指轻点 | 不显示复制／粘贴 |
| 三指／四指长按超过 0.3 秒 | 不显示复制／粘贴 |
| 多指滑动后回到原处 | 不显示复制／粘贴 |
| 双指滚动、缩放、系统三指／四指滑动 | 不显示复制／粘贴 |
| 三指拖移选择文字，抬起 | 不显示复制／粘贴 |
| 两块设备同时接触 | 每块设备的识别独立，不合并手指数 |
| 妙控板断开再重连，仅私有模式 | 重新接收数据，不补发旧手势 |
| 睡眠／唤醒，仅私有模式 | 重建监听，不补发旧手势 |

系统“三指轻点查询”占用同一手势。若已开启，记录它是否同时弹出；由用户决定
关闭或改用其他触发方式。三指拖移可能产生额外的系统鼠标事件，需要真实验证。
原型会取消已开始的轻点候选，但不会吞掉系统事件。

建议记录系统版本、触控板型号、监听模式、三指／四指成功次数、误触次数，以及
是否开启“三指拖移”和“三指轻点查询”。通过后再决定 Mos 的正式输入接口和 UI。

## 识别规则与当前限制

- 等最后一根有效手指抬起后，最多输出一次结果；有效手指数必须恰好为 3 或 4。
- 每根手指用自己的身份与初始位置跟踪，移动超过归一化距离 `0.035` 后取消候选，
  即使滑回原点也不恢复。
- 总时长最多 `300 ms`，手指落下间隔最多 `80 ms`，峰值手指数的重叠至少 `25 ms`。
  参数暂用于试验，尚未经真实设备校准。
- 从已有移动／静止触摸中途接入、取消事件、无效数据、手指替换、长按、点击、
  滚动都取消候选。
- 公开模式可忽略系统标记的 resting thumb。私有模式当前没有复用系统掌压判断，
  因此误触、悬停与静放拇指需要重点验证。
- 设备过滤使用框架内置标记及本机验证的外接 family 129。其他外接 family 暂不支持；
  此过滤依赖未公开标记，需要用不同代际设备复核。

参考：Apple 的 `NSEvent` / `NSTouch` 文档，MiddleClick 的 MoreTouch 桥接声明，
OpenMultitouchSupport 的 OpenMTInternal 声明。原型独立实现，不引入这些项目的包。

## 2026-11-19 真实设备验证记录

环境：macOS 27.0.1（26A434）；内置触控板与蓝牙 Magic Trackpad 均被系统枚举，
用户本轮只操作了妙控板。两轮监听各 60 秒，均正常结束。

| 模式 | 触摸帧 | 三指识别 | 四指识别 | 结论 |
| --- | --- | --- | --- | --- |
| public | 0 | 0 | 0 | 本轮没有收到触摸数据，尚不能确定是否与权限或事件转发有关 |
| private | 1760 | 8 | 10 | 妙控板可提供触摸数据，三指／四指轻点均能识别 |

用户反馈“次数不止5次，没啥问题”。未精确记录实际操作次数，不能计算成功率，
也不能据此宣称没有漏识别、重复触发或误触。内置触控板、设备重连、睡眠恢复、
系统手势共存，以及真实复制／粘贴仍未完成验证。

原始日志保存在 `build/trackpad-probe/public-test.log` 与
`build/trackpad-probe/private-test.log`（本地构建目录，不提交到仓库）。

## 本次集成验证

- 独立 XCTest：46 项通过，未发送实际键盘事件，未访问设备。
- Debug 应用及 MosTests target：`build-for-testing` 通过，已确认新增源文件与桥接
  C 文件参与编译；没有启动完整 Mos 或运行 hosted XCTest。
- 当前 Xcode 不接受 10.13 部署目标，本机也缺少工程配置的开发证书，因此构建
  使用独立 `/tmp` 产物和命令行 `MACOSX_DEPLOYMENT_TARGET=12.0` /
  `CODE_SIGNING_ALLOWED=NO`。未修改工程最低版本／签名设置。
- Swift 5 模式对新增 Swift 组件做了 macOS 10.13 / x86_64 availability typecheck，
  通过；这不能替代旧系统实机验证。
- 设备过滤后的一秒 recognition smoke：枚举 2 块支持的触控板，收到 36 帧，正常
  停止，未发送快捷键。本轮未组织人工轻点，不能据此评估新的识别成功率。
- `--execute` 权限检查已验证：未授权返回状态码 3，未开始监听。真实复制／粘贴
  按用户选择留待稍后授权试用；内置触控板、恢复路径与新菜单的实际交互仍未
  完成实机验证。

## 2026-11-19 试用版无响应排查

用户反馈菜单有对勾但轻点无响应。运行日志显示 Accessibility / PostEvent 权限
已允许，菜单的 `trackpadTapClick` 已调用。旧版仅记录监听失败，未记录帧和动作，
不能通过旧日志判断识别是否完成。

对同一设备回调做了三秒只读检查：native timestamp 约 `48.026`，
`mach_absolute_time` / `systemUptime` 约 `1596352.209`，共收到 162 帧、7 个
无有效接触帧。此前把 native timestamp 与 listener 的 systemUptime 直接比较，
使正常触摸帧都被拒绝。已将两种时钟分开：设备 timestamp 只用于测量轻点时长；
桥接层捕获的 host receivedAt 用于判断回调是否来自启用之前，继续保留 generation
检查及首次空闲要求。

新增不同时间起点、两设备不同时钟的回归用例，独立测试 46 项通过。实际复制／
粘贴是否在修正后的应用里成功，仍需用户重启新包后复测。新包位于
`build/trackpad-trial-clockfix/Mos Debug.app`，原试用包保留，未覆盖正在运行的程序。

Debug 日志新增：

```bash
tail -f ~/Library/Logs/Mos/trackpad-taps.log
log show --last 5m --style compact --predicate 'subsystem == "com.caldis.Mos" AND category == "TrackpadTap"'
```

文件日志在 utility queue 异步写入，最大 512 KiB 后轮换一份历史文件。记录开关、
设备首帧的两种时钟、每五秒的帧数／空闲帧／峰值手指数、取消事件统计、识别结果、
动作跳过原因和 `keyboardPairPosted`；不读取剪贴板或记录其内容。`keyboardPairPosted`
只表示键盘事件已提交，不能证明前台应用完成复制／粘贴。非 Debug 构建关闭该日志。

## 同路径替换后的授权恢复

2026-11-19 用户反馈旧辅助功能条目无法移除且对新包不生效。新旧本机试用包均
为 adhoc 签名，其 designated requirement 分别绑定不同 cdhash。TCC 日志显示
校验新包时仍使用旧哈希，返回 `-67050`，Accessibility 请求返回 false；保持路径
一致未能让这次授权自动沿用。系统日志还曾将相同 bundle ID 解析到另一份试用包。

确认 Mos 已退出后，仅执行 `tccutil reset Accessibility com.caldis.Mos.debug`，
工具返回成功；注销已注册的其他试用副本并重新注册
`build/trackpad-trial/Mos Debug.app`。未重置正式 Mos 或其他应用授权，未修改系统
TCC 数据库。用户再次授权后，系统在 15:52（Asia/Shanghai）以新包哈希校验成功。

应用日志显示 Accessibility 为 true、监听 2 块设备，随后出现 4 次
`action=copy keyboardPairPosted=true`。这是识别及事件提交的证据，尚不能确认前台
应用复制结果或四指粘贴结果。本次恢复后保留已授权二进制，不重新编译或改签。

## 2026-11-19 偏好设置与本地 Release 包

用户随后确认已正常授权，实际复制／粘贴可以使用。开关已从菜单移至
“偏好设置 → 通用”，下方显示三指复制、四指粘贴与退出后关闭的说明。
开启失败时保持关闭；设备断开导致管理器关闭功能时，已打开的偏好设置同步勾选状态。
维持默认关闭、仅本次运行生效。

本次按用户要求只打包本机使用的 Release 构建。输出位于
`build/trackpad-local-release/Mos.app` 与同目录的 `Mos.Local.4.3.0-20261119.1.zip`。
原已授权的 `build/trackpad-trial/Mos Debug.app` 保留。启用新包前先退出旧 Mos，
新包的 bundle ID 是 `com.caldis.Mos`，辅助功能授权需按新包确认。

本机没有有效签名身份，当前 Xcode 27.2 的构建部署范围从 macOS 12 开始。
该包使用临时签名、arm64 与 macOS 12.0 部署目标；项目原有 macOS 10.13 和签名
配置不变。本地 archive 额外使用命令行 `ENABLE_HARDENED_RUNTIME=NO`，避免临时
签名在加载 Sparkle 时触发 Team ID 校验失败；此参数仅用于本地构建。
构建号通过命令行覆盖为 `20261119.1`，未调整更新源、appcast 或公开版本元数据。

验证包括 46 项独立 XCTest、Debug build、Release archive，以及 15 种语言的
浅色／深色偏好设置布局和开关交互检查（使用真实控制器、编译后的 storyboard、
隔离的管理器替身）。新增 Swift 组件与偏好设置通过 macOS 10.13 / x86_64
availability typecheck；旧系统实机运行和休眠／重连路径仍未验证。
最终本地包在 XCTest 启动保护下通过启动检查（不运行全局输入监听），Sparkle 加载
正常；压缩包无 AppleDouble 文件，保留 framework 符号链接的解压结果通过
`codesign --verify --deep --strict`。新的 Release 包尚未组织真实手势复测。
