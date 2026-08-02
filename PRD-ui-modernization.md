# PRD: REditor UI 现代化改造

## Problem Statement

REditor 当前的 UI 是 Avalonia 出厂模板的默认状态——单窗口、居中卡片布局、系统标题栏、Emoji 当图标、无品牌设计。这种"网页 demo 风格"的界面在 macOS 上显得格格不入，无法给用户传达专业、现代桌面应用的质感。作为一个定位跨平台的桌面编辑器应用，当前界面缺乏：

- Mac 原生应用的空间布局语言（Sidebar、Toolbar、Vibrancy）
- 视觉层次与品牌辨识度
- 精致的动效与交互反馈
- 专业图标系统

用户期望 REditor 看起来像一个"真正的 Mac App"——精致、现代、符合 Apple 设计规范，同时保持跨平台能力。

## Solution

对 REditor 的 UI 进行全面现代化改造，将其从"跨平台 demo 模板"升级为具有 macOS 原生质感的现代桌面应用。改造围绕三个核心支柱：

1. **空间重构** — 从居中卡片布局改为 Mac 经典三段式布局（自定义标题栏 + Sidebar 导航 + 主内容区 + 状态栏）
2. **视觉语言升级** — 引入 Vibrancy 毛玻璃效果、Design Token 系统、品牌配色、专业图标系统
3. **交互精致化** — 添加细腻的过渡动画、悬停反馈、主题平滑切换

改造后，REditor 将具备与 macOS 原生应用（如 Finder、Notes、Xcode）一致的视觉语言和空间感，同时在 Windows 上保持 Fluent Design 的协调性。

## User Stories

1. As a macOS user, I want REditor to have a native-feeling window chrome with traffic light buttons, so that it visually belongs on my desktop alongside other Mac apps.

2. As a macOS user, I want the sidebar to have a vibrancy/blur effect, so that the app feels modern and uses the visual language I expect from Mac apps.

3. As a user, I want a sidebar navigation to access different sections of the app, so that I can quickly switch between features without cluttered menus.

4. As a user, I want consistent, professional icons throughout the interface instead of emoji, so that the app looks polished and production-ready.

5. As a user, I want smooth animations when interacting with buttons, cards, and navigation items, so that the app feels responsive and refined.

6. As a user, I want the app to support both light and dark mode with smooth transitions between them, so that I can work comfortably in any lighting condition.

7. As a user, I want a toolbar with common actions readily accessible, so that I don't have to dig through menus for frequent operations.

8. As a user, I want a status bar showing relevant information (line/column, encoding, framework version), so that I always have context about my working state.

9. As a user, I want the title bar to integrate seamlessly with the content area, so that the interface feels like a cohesive whole rather than a generic window.

10. As a user, I want consistent spacing, typography, and visual rhythm throughout the app, so that it feels designed rather than assembled from defaults.

11. As a Windows user, I want the app to still look polished and follow Fluent Design principles, so that I don't feel like a second-class platform.

12. As a user, I want the app to have a distinct brand identity (logo, accent color, typography), so that it's memorable and differentiated from other editors.

## Implementation Decisions

### 架构层

- **窗口 SystemDecorations**：macOS 上设为 `None` 以启用自定义标题栏与交通灯按钮；Windows 上保留系统装饰以避免非原生感。通过运行时平台检测切换。
- **自定义标题栏**：使用 `Grid` 第一行作为可拖拽标题栏区域，左侧绘制三个 12px 圆形按钮（Close `#FF5F57`、Minimize `#FFBD2E`、Maximize `#28C840`），中间为应用标题/文档名，右侧为工具栏按钮组。
- **Sidebar 侧边栏**：宽度 220px，可拖拽调整。顶部为 Logo + 应用名，中部为导航 `ListBox`，底部为设置入口。选中项使用 Accent 色圆角胶囊背景高亮。
- **主内容区**：占据剩余空间，承载编辑器或当前功能页面。保持简洁，避免过度装饰影响内容可读性。

### 视觉系统

- **Design Token 体系**：在 `App.axaml` 中定义完整的资源字典，包括：
  - 品牌色（Brand Primary `#007AFF`、Brand Secondary `#5856D6`）
  - 字号层级（Caption 11px / Body 13px / Title 16px / Display 22px）
  - 间距系统（XS 4 / SM 8 / MD 16 / LG 24 / XL 32）
  - 圆角系统（SM 4 / MD 8 / LG 12 / XL 16 / Pill 999）
  - 阴影层级（SM / MD）
- **Vibrancy 效果**：使用 Avalonia 的 `ExperimentalAcrylicBorder` 实现毛玻璃背景。侧边栏 `TintOpacity="0.65"`，标题栏 `TintOpacity="0.8"`，内容区保持纯色背景确保可读性。
- **图标系统**：使用 Lucide Icons（线性风格）或 Fluent UI System Icons，通过 `PathIcon` 控件引用。将所有 Emoji 替换为对应语义的 SVG 路径图标。
- **字体**：继续使用 Inter 字体（已通过 `Avalonia.Fonts.Inter` 引入），macOS 上可追加 `SF Pro Text` 作为首选回退。

### 动效系统

- 按钮悬停：`BackgroundTransition` 150ms ease-out
- 卡片出现/进入：`Opacity` + `TranslateTransform` 250ms ease-out
- Sidebar 选中切换：`BackgroundTransition` 200ms spring-like
- 主题切换：全局颜色过渡 300ms ease-in-out
- 窗口打开：`ScaleTransform` + `Opacity` 200ms

### 主题与深浅色

- 继承现有 `RequestedThemeVariant="Default"` 跟随系统模式
- 所有自定义 Token 通过 `DynamicResource` 绑定，确保深浅色自动适配
- 手动切换按钮保留，但图标改为太阳/月亮 SVG（非 Emoji）

### 组件复用

- 将 `Border.card`、`TextBlock.caption`、`Button.primary` 等样式从 `Window.Styles` 提升到 `Application.Styles` 级别，使其可跨窗口/控件复用
- 新增可复用样式：`Button.icon-button`、`Border.sidebar`、`ListBoxItem.nav-item`、`Border.toolbar`

### 平台适配

- 通过 `RuntimeInformation.IsOSPlatform(OSPlatform.OSX)` 检测 macOS
- 仅在 macOS 上启用自定义标题栏和 Vibrancy（Windows 保留系统原生装饰）
- 跨平台共享 Design Token、图标、动效定义

## Testing Decisions

- **测试策略**：Avalonia 桌面应用的 UI 测试以**手动验证**为主，辅以 Avalonia 的 `Headless Testing` 框架验证控件树结构和样式应用。
- **验证维度**：
  - 视觉回归：macOS 和 Windows 分别截图对比，确认各平台视觉一致性
  - 交互验证：手动测试交通灯按钮、Sidebar 导航、工具栏按钮的功能正确性
  - 主题切换：验证深浅色模式下所有自定义 Token 正确适配
  - 动效验证：确认动画流畅、无卡顿、时长合理
  - 可访问性：确保文字对比度符合 WCAG AA 标准
- **优先测试 seam**：`MainWindow` 的 XAML 结构 + `App.axaml` 的资源字典是最关键的 seam，所有视觉改造都通过这两个入口生效。
- **无新增测试框架**：当前项目无测试项目，本 PRD 不要求新增自动化测试，以手动验证 + 截图对比为主。

## Out of Scope

- 不新增业务功能（文件编辑、保存、语法高亮等）——纯 UI 改造
- 不引入第三方 UI 组件库（如 Material.Avalonia、Semi.Avalonia）——保持纯 Avalonia 原生控件 + 自定义样式
- 不实现自定义标题栏的窗口动画（如 macOS 弹性窗口拉伸）——仅做基础拖拽和按钮功能
- 不添加复杂的设置面板或偏好设置窗口——当前阶段仅做布局框架
- 不涉及应用签名、公证（Notarization）或 App Store 分发
- 不实现 Sidebar 的可折叠/隐藏
- 不实现多标签页（Tab）系统

## Further Notes

- 当前代码量极小（~250 行 UI 代码），无历史包袱，适合全面重构
- Avalonia 12.1.1 已原生支持 `ExperimentalAcrylicBorder`，无需额外 NuGet 包
- 交通灯按钮在 macOS 上的 hover 效果（显示 ✕/−/＋ 符号）可作为后续增强，初始版本仅做静态圆形
- 建议实施顺序：Design Token → 窗口 Chrome → Sidebar → Vibrancy → 动效 → 图标替换
- 此 PRD 产出的是 UI 框架骨架，具体内容页面（编辑器、设置等）由后续 PRD 覆盖
