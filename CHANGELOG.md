# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)（规则见 [AGENTS.md](AGENTS.md#版本号与发布)）。

## [Unreleased]

### 文档

- README 增加菜单栏与管理窗口截图（示例数据）。

## [0.1.0] - 2026-09-30

首个公开版本，对应 tailcat v0.7.0。

### 新增

- 菜单栏按“转发 / SOCKS / 服务 / 收件箱”分组显示规则，一键开关、复制本地端口或服务地址。
- 客户端：远端地址簿；`forward` 端口映射（断线指数退避重启、唤醒/网络变化后重连、定时 `ping` 健康检查、直连/中继与延迟）；常驻 `socks` 代理；在终端中打开 SSH；`ls` 浏览、下载与 `cp` 发送文件（支持拖放）；`perf` 测速面板（需要比 v0.7.0 更新的 tailcat）。
- 服务端：`serve`（端口/范围/映射、ssh、no-auth-ssh、exit-node、all、perf、共享目录、exec）与安全护栏、“给对方的命令”；`recv` 收件箱与新文件通知；实验性在线客户端列表。
- 密钥（`genkey` / `printpub`、地址缓存）、通讯录（按名字勾选 `--allow`）、DNS 发布向导。
- 设置：tailcat 路径与版本/能力检测、DERP map URL、`--verbose`、系统通知、登录启动。
- 诊断：复制等价 CLI 命令与打码后的诊断信息；日志默认折叠，出错时自动展开。
- tc 地址按凭据处理：数据文件 0600、目录 0700、原子写入，界面与日志默认打码。
- 以 universal（Apple 芯片 + Intel）DMG 发布，ad-hoc 签名，未经 Apple 公证。

### 升级提示

- Bundle ID 由 `app.tailcat.menubar` 改为 `io.github.zhdsmy.TailCat`。自己构建过旧版本的用户：规则、远端等数据（`~/Library/Application Support/TailCat/`）不受影响，偏好设置会在首次启动时自动迁移；“登录时启动”需要重新打开，并在“系统设置 › 通用 › 登录项”里删掉旧条目；系统会重新询问通知权限。

[Unreleased]: https://github.com/zhdsmy/TailCat/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/zhdsmy/TailCat/releases/tag/v0.1.0
