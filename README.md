# OpenInAgent

从 macOS Finder 当前目录打开 Codex、DeepSeek Harness（DSH）、终端或其他本地 Agent。

默认显示 **Codex、DSH、终端**。点击 **显示设置…** 可启用或隐藏 Hermes、ZCode、Kimi 等入口，选择会自动保存，并同步到工具栏、本地右键菜单和主窗口。

## 安装

要求 macOS 14 或更新版本；安装包同时支持 Apple Silicon 和 Intel。

从仓库 Releases 下载 DMG 与 SHA-256 校验文件。打开 DMG，将 `OpenInAgent.app` 拖入“应用程序”，启动后点击“管理 Finder 扩展…”并启用 OpenInAgent。再在 Finder 中选择“显示 → 自定工具栏…”，把 OpenInAgent 拖到工具栏。

升级时替换原安装位置中的 App，不要在 `/Applications` 与 `~/Applications` 保留两份。通过源码脚本安装的默认位置是 `~/Applications/OpenInAgent.app`。

如果此前使用过其他来源的同名版本，请先停用其 Finder 扩展并保留备份，再换用本独立版本；显示设置可能需要重新配置。源码安装器会拒绝覆盖应用标识不同的同名 App。

公开预发布包使用 **ad-hoc 本地签名**，不嵌入个人开发者证书，也未做 Apple 公证。首次从互联网下载并打开时，macOS 可能要求用户确认来源；本项目不提供关闭 Gatekeeper 或 SIP 的步骤。另一台 Mac 上的首次下载与启用流程仍需用户验证。

## 使用

- **Finder 工具栏**：进入目标目录后点击 OpenInAgent，选择打开方式。
- **本地右键菜单**：对文件夹或文件夹内空白区域右键，选择对应入口。
- **OneDrive 等云盘**：使用工具栏入口；File Provider 可能不提供第三方空白处右键菜单。
- **显示设置…**：勾选需要的入口。全部取消时仍可从该设置重新启用。
- **初始化 Agent 项目…**：填写项目简述，生成 `AGENTS.md`、`SOUL.md` 或两者，默认不覆盖已有文件。

| 入口 | 行为 |
| --- | --- |
| Codex | 将目录交给 Codex 桌面端；初始化可预填“项目启动会话”，需用户核对后发送。 |
| DSH | 登记到 DeepSeek Harness 桌面端的工作区列表并唤醒应用，进入工作区仍需点击侧栏。 |
| 终端 | 使用 macOS 自带 Terminal，工作目录为所选目录。 |
| Hermes | 调用 `hermes desktop --cwd`，需要已安装相应 CLI。 |
| ZCode | 使用 `zcode://workspace/open` 入口。 |
| Kimi | 在 Terminal 中从所选目录启动 `kimi`，需要已安装 Kimi Code CLI。 |

Finder 调用成功后 OpenInAgent 自动退出，不打开主窗口。隐藏入口只影响界面，命令行显式指定的接口仍可使用。

## 从源码构建

需要 macOS、Xcode 与 macOS SDK，默认不需要 Apple 开发证书。

```zsh
Scripts/build-openinagent.sh
Scripts/install-openinagent.sh
Scripts/package-openinagent.sh
Scripts/test-openinagent.sh
```

构建与打包缓存位于系统临时目录下的独立子目录，可用 `OPENINAGENT_WORK_DIR` 指定本地工作目录。DMG 输出到 `dist/`。构建不会采集或嵌入当前电脑的云盘路径。

`OPENINAGENT_SIGNING_IDENTITY` 可供开发者在本地构建时显式指定自己的证书；公开打包脚本只允许 ad-hoc 签名，防止误带个人证书。主 App 与扩展使用同一个公开偏好域共享显示设置，扩展只有该域的只读权限，无需固定个人 Team ID。

安装器会备份被替换的 OpenInAgent、CLI 和服务，并在安装失败时尝试回滚。它不迁移或删除其他历史应用。首次使用本独立版本时，旧内部版本的 Finder 扩展入口和偏好可能需要重新配置。

## 命令行

源码安装脚本会把命令行入口安装到 `~/.local/bin/openinagent`：

```zsh
openinagent open . --agent terminal
openinagent open . --agent codex
openinagent init . --description "整理项目资料并制定执行计划" --type generic
openinagent new "Example Project" ~/Documents --description "构建示例应用" --type software
```

## 数据和接口说明

OpenInAgent 不附带用户文件、聊天记录、登录凭据或偏好。项目说明使用本地模板生成，生成过程不调用模型；向所选 Agent 打开目录后，后续数据处理由对应 Agent 决定。

DSH 集成使用本机桌面端接口：仅向经过进程校验的本地服务发送所选目录，并按该服务端口精确读取所需本地认证 Cookie，不保存到发布包或日志中。Codex 项目确认依赖当前桌面端的本地状态结构。这些集成并非相关厂商承诺稳定的公共 API，应用升级后可能需要适配。

## 授权状态

本仓库公开源码，但**暂未授予开源许可证**。除平台条款和适用法律允许的范围外，其他使用、修改或分发授权请联系仓库维护者。本项目不是上述 Agent 厂商的官方产品。

版本记录见 [CHANGELOG.md](CHANGELOG.md)。
