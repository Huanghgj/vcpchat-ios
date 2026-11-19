# 开源致谢

## VCP 生态

VChat 参考并适配了以下项目的协议与交互：

- [VCPMobile](https://github.com/MRiecy/VCPMobile)：MRiecy / Nova。
- [VCPChat](https://github.com/lioensky/VCPChat) 与 [VCPToolBox](https://github.com/lioensky/VCPToolBox)：lioensky。

林间夜游与雨后绿叶壁纸沿用原 iOS 客户端素材。

## 第三方组件

| 组件 | 用途 | 许可 |
| --- | --- | --- |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 本机数据库 | [MIT](https://github.com/groue/GRDB.swift/blob/v7.0.0/LICENSE) |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Markdown 解析 | Apache 2.0 + Runtime Library Exception |
| [HighlighterSwift](https://github.com/smittytone/HighlighterSwift) | 代码高亮 | MIT |
| [SwiftMath](https://github.com/mgriebling/SwiftMath) | 公式排版 | MIT |
| [SDWebImage](https://github.com/SDWebImage/SDWebImage) | 动态图片 | MIT |
| [MermaidKit](https://github.com/2389-research/MermaidKit) | 原生图表 | [MIT](../Vendor/MermaidKit/LICENSE) |

各组件及附带字体保留各自许可。

### MermaidKit 归属与适配

MermaidKit 2.10.2，源码版本 `8556a1b8`。Copyright 2026 Clint Ecker。

本项目纳入 Apple 原生解析、布局和绘制组件，适配 Swift 6.0 工程配置，添加有像素上限的 Actor 绘制入口，并修正显式 XY 轴范围与裁切。完整许可保留于组件目录及应用资源。

### 双曲场图

场图绘制、话题团展开、节点查询和黎曼切片使用 [VCPChat 双曲场图](https://github.com/lioensky/VCPChat/tree/a070768d623519a7b69abedd1c4340e6030076f5/modules/warpedFieldAtlas)（VCPChat 贡献者，CC BY-NC-SA 4.0）。iOS 适配了本地资源加载、手机布局、触屏选点和双指缩放；数据通过原生只读接口取得。改编沿用同一许可。

### V5.2 聊天渲染与表情修复

iOS 聊天渲染参考 [VCPChat V5.2 的流式更新](https://github.com/lioensky/VCPChat/commit/76b5704) 以及[表情目录匹配](https://github.com/lioensky/VCPChat/blob/e9615e743f0e12948c6d664066280601e34b8b98/modules/renderer/emoticonUrlFixer.js)（VCPChat 贡献者，CC BY-NC-SA 4.0）。使用 SwiftUI、独立气泡 WKWebView 和消息专用图像缓存实现对应行为；未引入 Electron。
