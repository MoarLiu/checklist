# 出账日 · CheckList

<img src="Resources/Brand/logo.png" width="96" height="96" alt="出账日 Logo">

一个常驻 macOS 菜单栏的还款提醒工具。记录信用卡与贷款账单，查看待还总额，并在还款日收到提醒。

## 功能

- 记录账单名称、类型、金额及还款日，按到期日查看待还账单。
- 菜单栏用账单日历线条标显示待还负债，金额为负数；可快捷查看最近四笔账单。
- 到期显示玻璃提醒卡，支持已经还款、稍后一小时、不再提醒。
- 已还清记录、撤销还款、单笔提醒开关与删除确认。
- 每日提醒时间和提示音设置，启动及唤醒后补查。
- SwiftData 本地账本，无需账号或服务端；金额以整数分保存。
- 紧凑的 760 × 520 窗口，macOS 26 及以上采用 Liquid Glass，旧系统采用 Material。
- 跟随系统切换浅色与深色外观，输入框、文字、到期标签及提醒卡统一适配。

## 安装与使用

从 GitHub Releases 下载 DMG，将「出账日.app」拖入 Applications 后打开。

**系统要求：** macOS 14 或更高版本。当前下载包为 Apple Silicon（arm64）。

在「提醒设置」允许系统通知后，退出应用也可以收到已排程的通知。关闭主窗口会继续在菜单栏运行；从弹窗底部或应用菜单选择「退出」才会结束进程。

本次发布使用 `Moa Local Development Code Signing` 本地自签证书，已启用 hardened runtime，尚未使用 Apple Developer ID 签名或 Apple 公证。其他 Mac 可能提示无法验证开发者，请通过系统提供的确认打开方式处理。

## 提醒规则

- 默认在还款日 09:00 提醒，可在设置中修改。
- 已过提醒时间才添加当天到期的账单，会立即提醒。
- 同一账单每天自动提醒一次；未还款则次日继续提醒。
- 稍后提醒会延迟一小时，可重复使用；关闭提醒只影响该笔账单。
- 还款或删除后取消相关提醒；旧通知不会覆盖新的还款、静音或稍后状态。
- 应用运行期间每 20 秒补查，并在唤醒、日期或时区变化后补查。

系统通知采用滚动排程：先为每笔账单保留下一次提醒，再补充随后七天的每日提醒，合计最多 60 条。退出应用后只能投递已经排程的通知，重新启动后会续排。长期使用建议保持菜单栏应用运行。系统通知会受权限、专注模式与系统调度影响。

## 隐私与数据

账单只保存在本机：

- 正式账本：`~/Library/Application Support/CheckList/`
- 演示账本：`~/Library/Application Support/CheckList-Demo/`

还款日保存为年月日，按本地日历解析；切换时区不会将原始还款日期改成另一天。读取失败时会保留已有账本并显示错误。

演示模式具有独立账本与设置，不读取、清除或修改正式系统通知队列。原始 Figma Make 导出、设计聊天截图、验收日志及本地数据库不包含在仓库或安装包中。

## 开发

需要完整 Xcode 26 或更新版本，以及 Swift 6.2 或更新版本的编译器。可以用 Xcode 打开 `Package.swift`。

```sh
# 使用本机已有的 Moa 开发证书构建
./scripts/build.sh
open build/出账日.app

# 没有该证书时，显式选择 ad-hoc 签名
CODE_SIGN_IDENTITY=- ./scripts/build.sh

# 独立演示模式；切换前先退出正在运行的实例
open build/出账日.app --args --demo

# 严格并发与警告检查
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test -Xswiftc -strict-concurrency=complete -Xswiftc -warnings-as-errors

# 生成并验证 DMG 与 SHA-256 文件
./scripts/package-dmg.sh
```

可通过 `CODE_SIGN_IDENTITY` 指定其他已有证书。脚本不会创建证书，也不会在指定证书缺失时自动改用其他签名。

构建脚本默认使用 `/Applications/Xcode.app`，也可设置 `DEVELOPER_DIR`。使用 `CHECKLIST_DATA_DIR` 可以指定独立验收账本，该模式不会操作正式系统通知队列。安装包输出到 `release/`，可用 `CHECKLIST_RELEASE_DIR` 修改输出目录。

在独立验收账本模式下，可设置 `CHECKLIST_PREVIEW_APPEARANCE=light` 或 `dark` 验证两种外观；此设置只影响该预览进程，正常使用自动跟随系统。

## 当前范围

本版本尚未提供循环账单、部分还款、开机自启、iCloud 同步、隐私锁和 Intel 下载包。

发布内容见 [更新记录](CHANGELOG.md)。

Logo 的矢量源文件、透明 PNG 和生成方式见 [品牌资源说明](docs/branding.md)。
