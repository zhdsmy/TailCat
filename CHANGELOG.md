# Changelog

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，版本号遵循 [SemVer](https://semver.org/lang/zh-CN/)（规则见 [AGENTS.md](AGENTS.md#版本号与发布)）。

## [Unreleased]

### 安全

- DNS 发布向导：未设置允许列表时只能开启 SSH（授权公钥认证）；端口（包括转发到本机 sshd 的 22）和其他服务会对所有读到 TXT 记录的人开放，不再允许创建。
- 错误信息（文件浏览、传输、测速、密钥）与系统通知里的 tc 地址同样打码；tailcat 校验失败时会原样回显输入。
- 数据目录已存在且权限较宽时收紧为 0700；重写已有文件时不再沿用旧权限，始终是 0600；`pids.json` 也走同一套安全写入。

### 修复

- SSH 授权公钥来源的提示改为 tailcat 实际支持的 `用户名@github`、文件路径或公钥行；之前提示的 `github:用户名` 和 `https://github.com/用户名.keys` 会导致服务启动失败，现在保存时会提示改写。`ssh` 与 `no-auth-ssh` 同时开启时也会在保存前提示（tailcat 拒绝这种组合）。
- 迁移内联地址时如果 `remotes.json` 保存失败，规则保留原来的地址，不再写入丢失地址的规则。
- 在命令启动前就取消的任务（如文件传输）不再照常启动命令。
- 崩溃后清理孤儿进程时按可执行文件路径和启动时间识别：自定义名称的 tailcat 也能清理，pid 被复用后不会误杀其他进程。兼容读取 0.1.0 的 `pids.json`。
- 健康检查失败会更新所属远端的状态，不再一直显示上次成功的绿色结果。
- 远端编辑里可以选择用途未知的已有 key（例如用 CLI 创建、名字不以 `client` 开头的客户端 key）。
- 文件浏览的提示与“给对方的命令”不再暗示 `ls` 能列出需公钥认证的 `ssh` 服务（`ls` 不带 SSH 公钥）。

### 变更

- 唤醒 / 网络变化的监听移到 App 层，`TailCatCore` 不再依赖 AppKit。
- 去掉管理窗口分栏接缝的私有 AppKit 视图修正，改用系统默认布局。

### 文档

- README 增加菜单栏与管理窗口截图（示例数据）。
- 示例地址统一使用虚构的 `192.168.1.10`。

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
