# simai_swift

[![Swift](https://github.com/hhlfinn/simai_swift/actions/workflows/ci.yml/badge.svg)](https://github.com/hhlfinn/simai_swift/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-GPLv3-blue.svg)](LICENSE)

原生 Swift 的 simai 谱面解析、渲染与游玩框架，抽取自 Airmai 的谱面引擎。

A native Swift package for parsing, rendering, and playing simai charts. Extracted from the chart engine developed for Airmai.

## 特性 · Features

- 解析完整 `maidata.txt` 或单独的 simai 表达式，保留 BPM、细分、偏移、音符与路径信息。
- SwiftUI Canvas 原生绘制 TAP、HOLD、SLIDE、TOUCH、TOUCH HOLD、BREAK 和星星效果。
- UIKit 多指与合并触摸采样，按触摸时间戳进行判定。
- 独立的音符头与滑条计分、Critical Perfect、BREAK 加分、DX 分、连击与 FAST/LATE。
- 本地音频播放、暂停、定位及音频设备时钟同步。
- 速度、镜像、时序偏移、特效和音量设置，支持自定义宿主界面。
- 独立事件流与不可变结算快照，供宿主接入自己的业务。
- 合成音效和原创演示谱面，可直接运行示例。

### 平台支持

| 平台 | 最低版本 | 提供的能力 |
| --- | --- | --- |
| iOS / iPadOS | 16.0 | 解析、渲染、多指游玩、本地音频播放器 |
| macOS | 13.0 | 解析、路径几何、Canvas 渲染、判定引擎和离线测试 |

Package 使用 Swift tools 5.9 和 Swift 5 语言模式。当前本地验证使用 Xcode 27 / Swift 6.4，其他工具链由 CI 持续验证。

## 安装 · Installation

在 Xcode 的 **File → Add Package Dependencies** 中添加此仓库，选择 `SimaiSwift` 产品。

也可以在 `Package.swift` 中添加依赖。

```swift
.package(url: "https://github.com/hhlfinn/simai_swift.git", from: "0.1.0")
```

在目标的 `dependencies` 中添加产品。

```swift
.product(name: "SimaiSwift", package: "simai_swift")
```

## 使用 · Usage

### 1. 解析谱面

```swift
import SimaiSwift

let chart = try SimaiChartParser.parse(
    notation: "(120){4}1,2,3,4,5,6,7,8,E",
    bpm: 120,
    offset: 2
)

print(chart.noteCount)
print(chart.events.first?.time as Any)
```

读取完整文件时，使用 `maidata` 入口。

```swift
let text = try String(contentsOf: maidataURL, encoding: .utf8)
let master = try SimaiChartParser.parse(maidata: text, levelIndex: 3)
```

`levelIndex` 的映射为 Basic `0`、Advanced `1`、Expert `2`、Master `3`、ReMaster `4`，对应 `inote_2` 到 `inote_6`。传入原始表达式时，表达式内的 BPM/细分标记继续生效。缺失难度与空谱面通过错误返回。

### 2. 预览与播放

iOS / iPadOS 宿主可以直接使用原生播放器。音频 URL 应当是可读取的本地文件，文件生命周期由宿主管理。

```swift
import SimaiSwift
import SwiftUI

@MainActor
struct ChartPage: View {
    @StateObject private var controller: SimaiPlayerController

    init(chart: SimaiChart, audioURL: URL) {
        _controller = StateObject(wrappedValue:
            SimaiPlayerController(chart: chart, audioURL: audioURL)
        )
    }

    var body: some View {
        SimaiPlayerView(controller: controller, mode: .preview)
    }
}
```

`SimaiPlayerView` 在显示时准备谱面和音频，离开时停止并释放播放器，应用进入非活跃状态时暂停。自定义宿主直接管理控制器时，应在生命周期结束时调用 `stop()`。

```swift
await controller.prepare()
controller.play()
controller.pause()
controller.seek(to: 12.5)
controller.stop()
```

准备失败后通过 `errorMessage` 查看错误，内置界面提供重试。连续准备或在准备期间停止时，旧任务通过代次标识失效。

### 3. 游玩与结算

```swift
SimaiPlayerView(controller: controller, mode: .gameplay) { result in
    print(result.achievement)
    print(result.dxScore, result.totalDXScore)
    print(result.maxCombo)
    print(result.judgements)
}
```

控制器的设置可以在主线程调整。

```swift
controller.settings.noteSpeed = 8
controller.settings.mirror = .leftRight
controller.settings.audioTimingOffset = 0.020
controller.settings.visualTimingOffset = 0
controller.settings.musicVolume = 0.7
controller.settings.hitSoundVolume = 0.2
controller.settings.showEffects = true
```

时序偏移的单位为秒。默认音频设备管线补偿继承自原生引擎，具体设备和音频路由需要实际校准。模拟器测试覆盖逻辑和渲染构建，真机触摸到音频的端到端延迟需另行测量。

### 4. 自定义渲染和输入

`SimaiChartRenderer` 可以由宿主提供时间，适合编辑器和自定义预览界面。

```swift
SimaiChartRenderer(chart: chart, currentTime: time, settings: settings)
```

需要自定义游玩界面时，可以组合 `SimaiGameplaySession`、`SimaiMultiTouchSurface` 和渲染器。触摸点使用判定圆归一化坐标，圆心为 `(0, 0)`，外圈半径为 `1`。`SimaiMultiTouchSurface` 会完成 UIKit 坐标换算。

```swift
let session = SimaiGameplaySession(chart: chart, gameplayEventBus: controller.events)

// 在实际触摸回调中传入 frame，保留其原始时间戳。
session.handle(
    frame: frame,
    playbackTimeAtSystemUptime: controller.presentationTime(atSystemUptime:),
    settings: settings
)

// 播放中的时钟更新。
session.update(time: controller.livePresentationTime, settings: settings)
```

宿主自绘时应将 session 的已判定音符、头部反馈与滑条进度传给渲染器，具体组合见 [SimaiPlayerView.swift](Sources/SimaiSwift/SimaiPlayerView.swift)。自定义暂停需要调用 `releaseAllInputs(time:settings:)` 结束仍按住的触摸。

### 5. 订阅事件

每个播放器拥有独立事件总线。订阅任务由宿主取消，事件流使用有界缓冲。

```swift
let stream = controller.events.events(bufferingNewest: 256)
let task = Task {
    for await event in stream {
        print(event.kind, event.sourceNoteID as Any, event.judge as Any)
    }
}

// 宿主结束订阅时调用。
task.cancel()
```

## 示例 · Example

打开 [Examples/Demo/SimaiDemo.xcodeproj](Examples/Demo/SimaiDemo.xcodeproj)，选择 iPhone 或 iPad 模拟器运行。预览和游玩模式可直接切换。

示例在运行时生成 120 BPM 节拍音频，并解析原创演示谱面。真机运行时，在示例 target 中选择自己的签名团队。

## 架构

| 组件 | 职责 |
| --- | --- |
| `SimaiChartParser` / `SimaiChart` | 解析与不可变谱面索引 |
| `SimaiSlidePathGeometry` / `SimaiNoteMotion` | 路径几何与基于谱面时间的运动 |
| `SimaiChartRenderer` | SwiftUI Canvas 绘制 |
| `SimaiMultiTouchSurface` | 多指输入、合并采样与坐标转换 |
| `SimaiGameplaySession` | 判定、独立计分槽与成绩状态 |
| `SimaiPlayerController` / `SimaiPlaybackClock` | 本地音频和显示时间映射 |
| `GameplayEventBus` | 实时事件订阅 |

判定与计分的实现说明见 [GAMEPLAY.md](GAMEPLAY.md)。

## 开发与测试

```sh
swift test
ruby Tools/test_native_regressions.rb
xcodebuild -scheme SimaiSwift \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

公开 API 测试覆盖原始表达式、maidata 难度、音符标记、路径、真实触摸输入和事件总线。原生回归覆盖滑条轨迹、端点交接、合并采样、HOLD、BREAK/DX 计分、运动边界及离线音效增益。

`SOURCE_PROVENANCE.json` 记录抽取时的框架源码哈希。维护者可使用 `Tools/export_from_airmai.rb` 对允许列表内的引擎文件重新抽取。生成工具使用 Xcode 自带的 SwiftSyntax，运行时包通过 Apple 系统框架工作。

欢迎提交 Issue 和 Pull Request。报告判定问题时请提供最小 simai 表达式、设置、预期结果和可复现的时间戳序列。

## 来源与许可证

整个框架按 **GNU GPL v3.0** 发布，完整文本见 [LICENSE](LICENSE)。再分发与衍生作品须遵守该许可。

谱面语法、运动、路径与判定规则参考 `Project-Fukakai/simai_flutter` 的固定版本 `f15acddffc6a43d0c0f74beeb91fc282fcb9bf2c`。该上游为 MIT。判定区坐标在原生源码中标注来自 Majdata 的 JudgeAreas 数据，而 MajdataPlay 采用 GPLv3，因此本仓库保留此来源并使用 GPLv3 发布组合框架。完整的 MIT 声明及进一步来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

谱面、音乐、封面和商标的权利归各自权利人所有。宿主应使用获得授权的素材。
