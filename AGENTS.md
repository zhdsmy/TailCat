# AGENTS.md

给在本仓库工作的开发者和 AI Agent 的约定。等级：【MUST】必须 /【SHOULD】推荐 /【MUST NOT】禁止。

## 项目

TailCat 是 [tailcat](https://github.com/tailscale/tailcat) 的 macOS 菜单栏前端（SwiftUI + Swift Package）。App 不实现网络协议，只以子进程方式调用 `tailcat` 命令行并解析其输出。

| 路径 | 内容 |
| --- | --- |
| `Sources/TailCatCore/` | 模型、持久化、参数构造、输出解析、进程监管。【MUST NOT】依赖 SwiftUI/AppKit，保证可单测 |
| `Sources/TailCat/` | 菜单栏 App 与管理窗口；`Snapshot.swift` 仅 DEBUG 编译 |
| `Tests/TailCatCoreTests/` | Swift Testing 单测，用 `/bin/sh` 脚本冒充 tailcat |
| `Resources/` | `Info.plist`（版本号唯一来源）、`AppIcon.icns`（由脚本生成） |
| `scripts/` | 打包、DMG、发布说明、截图、图标 |
| `docs/screenshots/` | README 用的界面截图（必须来自 `snapshot.sh`，不得用真实用户数据） |
| `.github/workflows/` | CI（build + test）与 Release（推 tag 发布 DMG） |

## 工具链与常用命令

- swift-tools 5.9，最低 macOS 13；本地只需 Command Line Tools。
- 【MUST】不使用 SwiftUI 宏：CLT 没有 `SwiftUIMacros` 插件，`@State` 会被解析成宏而无法编译，`#Preview`、`@Observable` 同理。视图状态用 `@ViewState`（`State` 的别名，按属性包装器展开）。
- 【MUST】新 API 若高于 macOS 13，须 `if #available` 兜底。

```bash
swift build                                                        # debug 构建
swift build --product TailCatPackageTests && swift test --skip-build   # 单测（CLT 下 swift test 需先单独构建测试产物）
./scripts/bundle.sh                        # build/TailCat.app（release，ad-hoc 签名）
UNIVERSAL=1 ./scripts/make-dmg.sh          # build/TailCat-<版本>.dmg + .sha256（arm64 + x86_64）
./scripts/release-notes.sh <版本>          # 打印该版本的 Release 正文
./scripts/snapshot.sh [--dark]             # 用示例数据渲染各页面到 build/snapshots[-dark]/
swift scripts/capture-windows.swift        # 截取正在运行的真实窗口（需屏幕录制权限）
swift scripts/make-icon.swift              # 重新生成 Resources/AppIcon.icns
```

## 代码规范

- 【MUST】改代码同步更新相关注释、单测和 README；复杂逻辑（解析、迁移、状态机、参数构造）必须有单测。
- 【MUST】数据文件格式（`rules.json` 等）变化须向后兼容读取旧格式并带迁移测试；偏好设置键改名同理。
- 【SHOULD】注释解释“为什么”（约束、取舍、tailcat 的行为怪癖），一眼能看懂的代码不写注释。
- 【SHOULD】小而聚焦的改动，贴合周围代码的命名和风格；不做无关重构。
- 界面文案使用简体中文；命令行参数、代码标识符保持英文原样。

## 安全与隐私

- 【MUST】tc 地址等同访问凭据：数据文件 0600、目录 0700、原子写入；界面、日志、诊断信息里默认打码（`Diagnostics.mask`），复制按钮才给完整值。
- 【MUST NOT】读取 tailcat 私钥文件（`~/Library/Application Support/tailcat/keys/*.private.json`）；只通过 `tailcat genkey` / `printpub` 操作密钥。
- 【MUST】调用 tailcat 一律以 argv 形式 exec，不经 shell；用户输入须校验，不能以 `-` 开头以免被当成参数。
- 【MUST NOT】在仓库（代码、测试、示例数据、截图、文档、提交信息）中出现真实的 tc 地址、公钥、主机名、用户名、邮箱或个人路径；示例数据一律虚构（如 `Alice`、`/Users/me`、`192.168.1.10`）。
- 【MUST NOT】自动化流程（Agent、脚本、CI）对真实用户数据启动 App；看界面用 `snapshot.sh`（临时目录 + 假 tailcat）。

## 界面修改

- 【SHOULD】改 UI 前后各跑一次 `./scripts/snapshot.sh` 和 `--dark`，逐页对比；新增状态（空、出错、未安装等）要在 `Snapshot.swift` 里补对应页面。README 截图（`docs/screenshots/`）改完界面后用同一套 snapshot 覆盖。
- snapshot 不含标题栏/工具栏，未聚焦窗口的开关呈灰色，属于渲染限制而非 bug。

## Git 与提交

- 主干分支 `main` 已开分支保护：合入须 `build-test` 通过，禁止 force push / 删除分支；功能开发用短分支 + PR。
- 【MUST】提交信息遵循 Conventional Commits：`<type>(<scope>): <subject>`，type 取 `feat` / `fix` / `refactor` / `docs` / `test` / `build` / `ci` / `chore`；subject 简短，中英文皆可。
- 【MUST】提交前确认可编译、单测通过。
- 【MUST NOT】提交构建产物与本机状态：`.build/`、`build/`、`*.dmg`、`.DS_Store`、编辑器/Agent 目录（已在 `.gitignore`）。
- 【MUST】提交作者使用 GitHub noreply 邮箱，不用个人或公司邮箱。

## 版本号与发布

- 【MUST】遵循 [SemVer](https://semver.org/lang/zh-CN/) `MAJOR.MINOR.PATCH`：
  - 1.0 之前：新功能、数据格式或行为的不兼容变化升 MINOR；仅修复升 PATCH。
  - 1.0 之后：不兼容变化升 MAJOR，新功能升 MINOR，修复升 PATCH。
- 【MUST】版本号唯一来源是 `Resources/Info.plist` 的 `CFBundleShortVersionString`；`CFBundleVersion` 为整数，每次发布加 1，永不回退。
- 【MUST】tag 格式 `vX.Y.Z`，且必须与 `CFBundleShortVersionString` 一致（Release 工作流会校验，不一致直接失败）。
- 【MUST】`CHANGELOG.md` 的变更先记在 `## [Unreleased]` 下，发布时改成 `## [X.Y.Z] - YYYY-MM-DD` 并更新文末链接；发布说明从这一节生成，没有这一节发布会失败。

发布步骤：

1. 更新 `Resources/Info.plist`（`CFBundleShortVersionString`、`CFBundleVersion` + 1）和 `CHANGELOG.md`。
2. 本地验证：单测通过，`UNIVERSAL=1 ./scripts/make-dmg.sh` 成功。
3. 提交 `chore(release): vX.Y.Z`，推送 `main` 并等 CI 通过。
4. `git tag vX.Y.Z && git push origin vX.Y.Z`；`release.yml` 会构建 universal DMG、生成 `.sha256` 并创建 GitHub Release。
5. 发布有误时删除 Release 与 tag，修复后用新的 PATCH 版本重新发布，不复用已发布的版本号。

App 仅 ad-hoc 签名、未经 Apple 公证；如果将来接入 Developer ID 签名与公证，在 `bundle.sh` / `release.yml` 中实现并更新 README 的安装说明。
