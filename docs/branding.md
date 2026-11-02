# 出账日 Logo

设计方向：用一个清晰的日历符号表达还款日期，以纸张折角表达账单，以深青色勾表达还款完成，以一枚小琥珀色圆点表达到期提醒。整体保留应用的青绿色渐变和紧凑风格。

- 主色：`#3FF0CD` → `#0FBFA0`
- 图形深色：`#134E4A`
- 纸张：`#FFFFFF` → `#E5FFF7`
- 提醒点：`#FFCA57`
- 构图：1024 × 1024 画布，外侧透明，图形居中；没有依赖字体的文字或数字。

资源：

- `Resources/Brand/logo.svg`：可编辑矢量稿。
- `Resources/Brand/logo.png`：1024 × 1024 透明 PNG。
- `Resources/AppIcon.icns`：macOS 16–1024 像素多尺寸应用图标。
- `scripts/generate-icon.swift`：原生 Core Graphics 矢量绘制及导出程序。

这版使用原生矢量绘制，未使用外部图片或字体。生成程序在每个尺寸直接绘制矢量路径，避免依赖大图缩放。

在项目根目录重新导出：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift scripts/generate-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
./scripts/package-dmg.sh
```

SVG、PNG 和 ICNS 均包含在 App 包中，主窗口侧栏直接使用包内 PNG，Finder 和关于窗口使用 ICNS。macOS 菜单栏使用同一标志的单色线条版：两枚环扣、账单页、还款勾和右下折角，不带提醒圆点。
