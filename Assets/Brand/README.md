# LiveLearn 标志

2026-09-12 重设计：两股有方向感的流光围绕同一星核，呼应语音与译文的汇合。应用图标采用星空黑底与银蓝色光泽，与主程序的星云、粒子字标配套。

优雅版精修：流光更纤细，首尾连续收尖，移除斜切口；星核缩小，扩大内部留白，色彩偏冷银，降低辉光并清理底板上的装饰星点。

## 已应用

- `AppIcon.icns`：Dock、Finder 和系统「关于」窗口；构建脚本写入 `CFBundleIconFile` 并复制到 `.app/Contents/Resources`。
- `MenuBarTemplate.pdf` / `MenuBarActiveTemplate.pdf`：菜单栏的 18pt 黑色透明模板，由 macOS 着色。闲置态是圆形星核，活动态是四向星核；暂停等活动会话仍沿用原有状态规则。
- `doc/diagrams/livelearn-poster.svg`：项目总览图同步使用新标识。

`LiveLearnMark` 是共享几何的 SwiftUI 组件，当前没有界面调用；主窗口和设置页仍使用独立的 `ParticleWordmark`，由粒子拼出 LiveLearn。

## 可复用资源

- `app-icon.svg` / `app-icon.png`：带底的应用图标，PNG 为 1024 × 1024，外边角透明。
- `mark-light.svg` / `mark-dark.svg`：透明底双色图形。
- `mark-monochrome-light.svg` / `mark-monochrome-dark.svg`：单色版本。
- `wordmark-light.svg` / `wordmark-dark.svg`：图形与 LiveLearn 字标组合；字标使用系统字体。
- `brand-preview.png` / `brand-preview.svg`：品牌预览；PNG 包含实际 16、32、64、128px 图标。
- `menu-idle-preview.png` / `menu-active-preview.png`：菜单栏造型的 4 倍白底预览，不是运行资源。

所有图形原创，以 `Sources/LiveLearnApp/DesignSystem/BrandGeometry.swift` 的闭合贝塞尔路径为几何来源；坐标以 32 × 32 为基准。原生组件、菜单栏回退和导出资源共用路径。应用图标不叠加星尘；小尺寸省略辉光，依靠连续轮廓保持清晰。

修改路径后运行 `zsh script/generate_brand_assets.sh`。脚本仅使用 macOS 自带 Swift、AppKit 和 `iconutil`，生成 16、32、128、256、512pt 的 1x / 2x 图标及 PDF、SVG、PNG；完整构建也会自动执行。无需联网或额外图形依赖。

应用图标底色从 `#121923` 收至 `#030507`；上层冷银、下层淡冰灰，星核为 `#F7FCFF`。透明标识提供深底、浅底和单色版本。菜单栏保持无背景、无光晕的模板；正文与浮层沿用现有设计。
