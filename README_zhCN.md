<p align="center">
  <img src="MacKeyValue/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png" width="128" height="128" alt="KeyValue Icon">
</p>

<h1 align="center">KeyValue</h1>

<p align="center">
  <strong>K🔒V — 安全的密码与键值对管理工具</strong>
</p>

<p align="center">
  <a href="https://github.com/aresnasa/mac-keyvalue/releases/latest"><img src="https://img.shields.io/github/v/release/aresnasa/mac-keyvalue?style=flat-square&color=blue" alt="Latest Release"></a>
  <a href="https://github.com/aresnasa/mac-keyvalue/blob/main/LICENSE"><img src="https://img.shields.io/github/license/aresnasa/mac-keyvalue?style=flat-square" alt="MIT License"></a>
  <a href="https://github.com/aresnasa/mac-keyvalue/releases"><img src="https://img.shields.io/github/downloads/aresnasa/mac-keyvalue/total?style=flat-square&color=green" alt="Downloads"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2013%2B-lightgrey?style=flat-square" alt="macOS 13+">
  <img src="https://img.shields.io/badge/swift-5.9%2B-orange?style=flat-square" alt="Swift 5.9+">
</p>

<p align="center">
  加密存储 · 快捷键入 · 剪贴板管理 · Gist 同步
</p>

---

## 📦 安装

### 方式一：下载 DMG（推荐）

1. 前往 [Releases](https://github.com/aresnasa/mac-keyvalue/releases/latest) 下载最新的 `.dmg` 文件
2. 打开 DMG，将 **KeyValue.app** 拖入 **Applications** 文件夹
3. 首次打开：**右键** 点击 KeyValue.app → 选择「**打开**」

> ⚠️ 本应用是免费开源软件，采用 ad-hoc 签名。macOS 首次打开时会提示"无法验证开发者"，右键 → 打开即可。
> 也可以执行：`xattr -cr /Applications/KeyValue.app`

### 方式二：从源码构建

```bash
git clone https://github.com/aresnasa/mac-keyvalue.git
cd mac-keyvalue/MacKeyValue

# 构建并运行
./build.sh --run

# 或构建 DMG 安装包
./build.sh --dmg
```

<details>
<summary>构建脚本更多用法</summary>

```bash
./build.sh              # 构建 Release .app
./build.sh debug        # 构建 Debug .app
./build.sh --dmg        # 构建 + 打包 DMG
./build.sh --dmg --run  # 构建 + DMG + 启动
./build.sh --icons      # 仅重新生成图标
./build.sh --clean      # 清理构建产物
./build.sh --help       # 完整帮助
```

</details>

### 🔐 首次启动权限

启动后应用会引导你授予两个系统权限：

| 权限 | 用途 | 设置路径 |
|------|------|---------|
| **辅助功能** (Accessibility) | 模拟键盘输入密码 | 系统设置 → 隐私与安全性 → 辅助功能 |
| **输入监控** (Input Monitoring) | 创建键盘事件 | 系统设置 → 隐私与安全性 → 输入监控 |

两个开关都打开后，按应用提示重启即可。

---

## ✨ 功能特性

### 🔐 AES-256 加密存储

- **AES-256-GCM** 认证加密，防篡改
- 主密钥存储在 macOS **Keychain** 中
- 支持密钥轮换和 HKDF-SHA256 密钥派生
- 每次加密使用随机 Nonce

### ⌨️ 快捷键 & 键盘模拟

- 全局快捷键一键复制密码
- **模拟键盘逐字符输入** — 绕过禁止粘贴的密码框（PVE/KVM 等 Web 控制台）
- 自动 **⌘V 粘贴**到目标窗口
- 自定义快捷键绑定

<table>
<tr>
<th width="260" align="center">快捷键</th>
<th align="left">功能</th>
</tr>
<tr>
<td align="center"><kbd>&nbsp;⌘&nbsp;</kbd>&ensp;<kbd>&nbsp;⇧&nbsp;</kbd>&ensp;<kbd>&nbsp;K&nbsp;</kbd></td>
<td>&emsp;🪟&ensp; 显示/隐藏主窗口</td>
</tr>
<tr>
<td align="center"><kbd>&nbsp;⌘&nbsp;</kbd>&ensp;<kbd>&nbsp;⌥&nbsp;</kbd>&ensp;<kbd>&nbsp;Space&nbsp;</kbd></td>
<td>&emsp;🔍&ensp; 快速搜索</td>
</tr>
<tr>
<td align="center"><kbd>&nbsp;⌘&nbsp;</kbd>&ensp;<kbd>&nbsp;⇧&nbsp;</kbd>&ensp;<kbd>&nbsp;V&nbsp;</kbd></td>
<td>&emsp;📋&ensp; 剪贴板历史</td>
</tr>
<tr>
<td align="center"><kbd>&nbsp;⌘&nbsp;</kbd>&ensp;<kbd>&nbsp;⇧&nbsp;</kbd>&ensp;<kbd>&nbsp;⌥&nbsp;</kbd>&ensp;<kbd>&nbsp;P&nbsp;</kbd></td>
<td>&emsp;🔒&ensp; 切换隐私模式</td>
</tr>
<tr>
<td align="center"><kbd>&nbsp;⌘&nbsp;</kbd>&ensp;<kbd>&nbsp;1&nbsp;</kbd></td>
<td>&emsp;🔄&ensp; 切换精简/管理模式</td>
</tr>
</table>

### 📋 智能剪贴板

- 自动记录剪贴板历史（最多 500 条）
- 智能识别内容类型（文本、链接、路径…）
- 记录来源应用
- Pin 固定重要条目
- 复制密码后自动清除剪贴板

### ☁️ GitHub Gist 同步

- 双向同步到 GitHub Gist
- 基于时间戳自动合并冲突
- Token 安全存储在 Keychain
- **加密值和私密条目永远不会上传**

### 🔒 隐私模式

- 剪贴板操作不被记录
- 所有数据 100% 本地存储
- 私密条目不参与同步

### 🗂️ 条目管理

- 分类：密码 / 代码片段 / 命令 / 剪贴板 / 其他
- 标签 + 收藏 + 全文搜索（支持正则）
- 使用统计和排序
- JSON 导入/导出
- 精简模式 & 管理模式 双界面

---

## 🏗️ 项目架构

```
MacKeyValue/
├── Package.swift                    # Swift Package Manager
├── build.sh                         # 构建 & 打包脚本
├── Sources/
│   ├── App/
│   │   └── MacKeyValueApp.swift     # 入口、菜单栏、AppDelegate
│   ├── Models/
│   │   └── KeyValueEntry.swift      # 数据模型
│   ├── Services/
│   │   ├── EncryptionService.swift  # AES-256-GCM 加密
│   │   ├── StorageService.swift     # 本地持久化
│   │   ├── ClipboardService.swift   # 剪贴板 & 键盘模拟
│   │   ├── HotkeyService.swift      # 全局快捷键 (Carbon)
│   │   ├── GistSyncService.swift    # Gist 同步
│   │   └── BiometricService.swift   # Touch ID 认证
│   ├── ViewModels/
│   │   └── AppViewModel.swift       # MVVM 视图模型
│   └── Views/
│       ├── ContentView.swift        # 主界面
│       ├── CompactView.swift        # 精简模式
│       └── AccessibilityGuideOverlay.swift  # 权限引导
├── Resources/
│   ├── Info.plist
│   ├── MacKeyValue.entitlements
│   ├── AppIcon.icns
│   └── Assets.xcassets/
└── Tests/
```

---

## 🔒 安全架构

```
用户数据 → JSON 编码 → AES-256-GCM 加密 → 本地文件
                               ↑
                          主密钥 (256-bit)
                               ↑
                       macOS Keychain (硬件保护)
```

- 所有敏感数据使用 AES-256-GCM 认证加密
- 主密钥由 macOS Keychain 保护（设备解锁时可访问）
- 每次加密使用 `SecRandomCopyBytes` 生成 12 字节随机 Nonce
- Gist 同步仅传输元数据，**加密值永远不会离开本机**

---

## 📦 依赖

| 包名 | 用途 |
|------|------|
| [swift-crypto](https://github.com/apple/swift-crypto) | AES-GCM 加密、HKDF 密钥派生 |
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | 全局快捷键 |
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | HTML 内容解析 |

---

## 🛠️ 开发

### 环境要求

- **macOS 13.0+** (Ventura 或更高)
- **Xcode 15.0+** 或 **Swift 5.9+**

### 快速开始

```bash
cd MacKeyValue

# SPM 构建 & 运行
swift run MacKeyValue

# 或使用 Xcode
open Package.swift
```

### 架构模式

- **MVVM** + Service Layer
- **Combine** 响应式数据流
- **async/await** 异步操作
- **@MainActor** UI 线程安全

---

## ☕ 支持项目

如果 KeyValue 对你有帮助，欢迎：

- ⭐ 在 GitHub 上 **Star** 本项目
- 🐛 提交 [Issue](https://github.com/aresnasa/mac-keyvalue/issues) 反馈问题或建议
- 🔀 提交 [Pull Request](https://github.com/aresnasa/mac-keyvalue/pulls) 参与开发
- ☕ 扫码赞赏，支持项目持续开发

### 赞赏码

<p align="center">
  <img src="docs/donate_wechat.png" width="180" alt="微信赞赏码" />
  &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;
  <img src="docs/donate_alipay.png" width="180" alt="支付宝收款码" />
  <br/>
  <sub>微信扫码赞赏 &nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp;&nbsp; 支付宝扫码转账</sub>
</p>

> 你的每一个 Star ⭐ 和反馈都是持续开发的动力！

---

## 📄 许可证

[MIT License](LICENSE) — 自由使用、修改和分发。

---

<p align="center">
  <sub>Made with ❤️ by <a href="https://github.com/aresnasa">aresnasa</a></sub>
</p>