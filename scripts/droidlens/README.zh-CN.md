# DroidLens

[English](README.md)

DroidLens 让 AI 代理通过 ADB 查看、分析和操作 Android 应用界面。

它面向 Claude Code、Codex 等编码代理。开发者只需要用自然语言描述想要的结果，AI 会把 DroidLens 当作 Android 界面工具链来使用。

```text
分析当前 app UI。
打开 Settings 页面，找出 UX 问题。
对比这个页面和设计稿。
跑 UI 回归，必要时可以重置本地测试数据。
复现这个按钮为什么点了没反应。
```

下面的命令参考主要面向维护者、集成者、CI 和高级排障场景。

## 快速开始

正常使用时，在 Android 项目的 Claude Code 或 Codex 会话中直接描述结果：

```text
使用 DroidLens 检查当前 App UI，并报告 UX 问题。
使用 DroidLens 打开设置页，验证主题切换行为。
使用 DroidLens 复现登录按钮问题，并收集证据。
```

AI 应该自动完成环境检查、解析 App、观察设备状态、导航、抓取必要的截图和 XML，并输出结论。开发者不需要记住 DroidLens 命令。

如果要手动做一次冒烟验证，可以在项目根目录运行：

```bash
scripts/droidlens/droidlens doctor --ensure --json
scripts/droidlens/droidlens observe --app auto
scripts/droidlens/droidlens summary
scripts/droidlens/droidlens snap /tmp/droidlens-smoke.webp --thumb --json
```

## 能力

- 从项目配置、Gradle 或 ADB 启动入口信息解析目标应用。
- 抓取小体积 WebP 截图和界面 XML。
- 提取当前屏幕可见文本，用于快速分析 UI。
- 按文本、内容描述、资源 ID、XML 边界或截图元数据点击。
- 学习页面路径，并按 app 版本、设备尺寸、density 分桶复用。
- 从任意设备状态恢复，例如 Launcher、系统浮层、未知 App 页面。
- 提供面向 AI 代理的 ADB 操作层。
- 支持无人值守场景下的操作授权。
- 失败时输出结构化诊断包。

## 可以完成的开发任务

DroidLens 适合需要真机或模拟器 UI 证据的任务：

| 任务 | DroidLens 收集什么 | 典型输出 |
|---|---|---|
| UI 巡检 | 屏幕摘要、XML、截图 | 按优先级排列的 UX 问题 |
| Bug 复现 | 操作记录、终态屏幕、失败诊断包 | 可复现步骤、期望结果、实际结果 |
| 设计稿对比 | 目标页面截图和结构信息 | 差异列表和严重程度 |
| 回归流程 | JSONL 事件、截图、备注 | 通过/失败摘要和失败步骤证据 |
| 无障碍检查 | 可见文本、content-desc、XML bounds | 缺失标签、歧义控件、点击区域风险 |
| 导航冒烟测试 | 学习过的路径、观察到的页面 | 路径状态和失效边报告 |
| 发版前检查 | App 启动、关键页面、弹窗 | 是否阻塞发布的建议和证据 |

## AI 输出模板示例

建议输出简短、证据优先的报告。优先引用 UI 文本、XML 选择器和文件路径，避免大段描述截图。

### UI 巡检

```markdown
## 问题

1. 严重程度：High
   页面：Settings
   证据：`Current theme` 行可以打开弹窗，但当前选中的主题没有在页面文本中展示。
   影响：用户返回设置页后无法确认当前主题。
   建议：在该行副标题或右侧文本中显示当前值。

2. 严重程度：Medium
   页面：Settings
   证据：`Scan library` 操作位于首屏下方，并且没有持续进度状态。
   影响：长时间扫描时用户可能以为操作没有生效。
   建议：在该行和通知区域展示扫描状态。

## 证据

- Summary: `/tmp/droidlens-settings/summary.json`
- Screenshot: `/tmp/droidlens-settings/screen.webp`
- XML: `/tmp/droidlens-settings/hierarchy.xml`
```

### Bug 复现

```markdown
## 复现结果

目标：Settings -> Library sync
结果：已复现

步骤：
1. 从前台干净状态启动 App。
2. 打开 Settings。
3. 点击 `Sync now`。

期望：
App 开始同步，或展示可恢复错误。

实际：
按钮保持可点击，没有出现进度文本，也没有 snackbar 或 dialog。

证据：
- Last screen: `/tmp/droidlens-sync-failure/screen.webp`
- UI summary: `/tmp/droidlens-sync-failure/summary.json`
- Action log: `/tmp/droidlens-sync-failure/events.jsonl`
```

### 回归结果

```markdown
## 回归结果

流程：`.droidlens/flows/settings.flow`
状态：失败
失败步骤：`wait-text "Dark" 6`

现象：
主题弹窗已打开，但当前视口中没有出现 `Dark`。

可能原因：
弹窗内容或主题文案已变化，流程选择器过期。

下一步：
检查弹窗 XML，并把流程选择器更新为当前文本或 content-desc。
```

## 支持环境

| 环境 | 状态 |
|---|---|
| macOS Bash/Zsh | 支持目标 |
| Linux Bash | 支持目标 |
| Windows Git Bash / MSYS2 / Cygwin | 支持目标 |
| WSL | 支持目标 |
| 原生 PowerShell | v0.1.0 暂不支持 |

最低依赖：

- Android SDK platform-tools / `adb`
- Bash
- `python3`
- 一台已授权的 Android 设备或模拟器
- 推荐：`cwebp`，用于默认 WebP 截图
- 可选：`pngquant`，用于 PNG 压缩

## 安装

将 `scripts/droidlens/` 添加到 Android 项目中：

```text
scripts/droidlens/
  droidlens
  *.sh
  *.py
  LICENSE
  docs/
  flows/
```

在 Claude Code / Codex 中使用时，AI 应该自动完成初始化。手动验证可以在项目根目录运行：

```bash
scripts/droidlens/droidlens doctor --ensure --json
```

`doctor --ensure` 会检测本机工具、选择已授权设备、解析 App、写入 `.droidlens/env.sh`，并通过 `adb shell svc power stayon true` 保持设备常亮。

如果缺少必要工具：

```bash
scripts/droidlens/droidlens doctor --ensure --install-missing
```

## 自然语言使用

在 Claude Code 或 Codex 中，直接描述结果：

```text
分析当前 UI。
检查 Settings 页面是否符合设计。
跑保存好的 UI 回归。
调查删除弹窗行为异常的问题。
```

AI 应该：

1. 运行 DroidLens 环境检查。
2. 观察当前设备和 App 状态。
3. 按需导航、检查、点击或运行流程文件。
4. 优先使用 summary 和 XML，再读取截图。
5. 只在物理设备操作、缺少凭据、目标不明确或危险操作审批时询问用户。
6. 用具体 UI 证据报告结果。

## 安全模型

DroidLens 提供受控 ADB 能力。常规命令可直接执行；破坏性动作需要授权。

危险操作示例：

- 清除 App 数据
- 卸载 App
- 点击删除、支付、允许、授权、卸载等危险 UI

无人值守任务中，用户可以用自然语言批准意图，AI 会创建本次任务需要的授权。

示例：

```text
跑一遍设置页回归。为了完成测试，可以重置目标应用的本地数据，最多 3 次。不要卸载应用。
```

手动等价命令：

```bash
scripts/droidlens/droidlens policy grant \
  --action clear-app-data \
  --app auto \
  --ttl 2h \
  --max-runs 3 \
  --reason "AFK regression reset" \
  --json
```

授权会绑定操作、App、设备、有效期和次数。每次授权、允许、拒绝、撤销都会写入 `.droidlens/audit.jsonl`。

`DROIDLENS_ALLOW_DANGEROUS=1` 只作为单条命令逃生口，不应该 export 或持久化。

## 项目记忆

DroidLens 把通用工具、项目记忆和本机状态分开：

```text
scripts/droidlens/          可复用 DroidLens 引擎
.droidlens/profile.json     项目应用配置；内容通用时可纳入版本库
.droidlens/env.sh           生成的本机环境；本机文件，不纳入版本库
.droidlens/flows/           项目专属回归流程
.droidlens/policy.json      本机危险动作授权；本机文件，不纳入版本库
.droidlens/audit.jsonl      本机危险动作审计日志；本机文件，不纳入版本库
~/.droidlens/page-tree.json 用户跨会话路径记忆
```

数据格式见 [docs/schema.md](docs/schema.md)。

## 命令参考

优先使用统一入口：

```bash
scripts/droidlens/droidlens doctor --ensure --json
scripts/droidlens/droidlens observe --app auto
scripts/droidlens/droidlens summary
scripts/droidlens/droidlens snap /tmp/screen.webp --thumb --json
scripts/droidlens/droidlens dump /tmp/state --thumb --json
scripts/droidlens/droidlens tap "Settings"
scripts/droidlens/droidlens goto --app auto "Settings"
scripts/droidlens/droidlens flow --jsonl /tmp/out .droidlens/flows/regression.flow
scripts/droidlens/droidlens adb current
scripts/droidlens/droidlens policy list --json
```

### App 解析

```bash
scripts/droidlens/droidlens app resolve --app auto --json
scripts/droidlens/droidlens app launch --app auto
scripts/droidlens/droidlens app launch --app auto --fresh
```

`--app auto` 解析顺序：

1. CLI 或环境变量指定的 App
2. `.droidlens/profile.json`
3. Gradle Android application id 和 suffix
4. ADB 启动入口

### 截图和 XML

```bash
scripts/droidlens/droidlens snap /tmp/screen.webp --thumb --json
scripts/droidlens/droidlens snap /tmp/screen.webp --ai --json
scripts/droidlens/droidlens dump /tmp/state --thumb --json
scripts/droidlens/droidlens summary
```

截图模式：

- `--thumb`：360px 宽 WebP，默认快速巡检
- `--ai`：540px 宽 WebP，用于看更多细节
- `--lossy`：原尺寸 WebP
- `--png`：压缩 PNG
- `--raw`：原始 PNG

每次截图会写 `.meta.json`，记录设备尺寸和压缩图尺寸。AI 用它把压缩图坐标换算回设备坐标。

### 点击

```bash
scripts/droidlens/droidlens tap "Visible Text"
scripts/droidlens/droidlens tap --desc "More options"
scripts/droidlens/droidlens tap --id "com.example:id/save"
scripts/droidlens/droidlens tap --contains "Item"
scripts/droidlens/droidlens tap --re "Item.*"
scripts/droidlens/droidlens tap --xml /tmp/state.xml "Save"
scripts/droidlens/droidlens tap --meta /tmp/screen.meta.json 180 650 --json
```

优先使用语义选择器和 XML 边界。只有带 `.meta.json` 时才建议用截图坐标。

### Flow

流程文件是放在 `.droidlens/flows/` 下的项目专属小脚本：

```text
launch auto
wait-text "Home" 6
tap-desc "Settings"
wait-text "Settings"
snap
note "Settings screen reached"
```

运行：

```bash
scripts/droidlens/droidlens flow --jsonl /tmp/droidlens-run .droidlens/flows/settings.flow
```

常用流程命令：

```text
launch auto
wait-text "Text" [seconds]
tap "Text"
tap-desc "content-desc"
tap-nth N "Text"
tap-xy X Y
key BACK
sleep 2
snap
note "free text"
```

### 安全 ADB 包装

```bash
scripts/droidlens/droidlens adb devices
scripts/droidlens/droidlens adb current
scripts/droidlens/droidlens adb wm
scripts/droidlens/droidlens adb density
scripts/droidlens/droidlens adb wake
scripts/droidlens/droidlens adb back
scripts/droidlens/droidlens adb home
scripts/droidlens/droidlens adb tap 50 80
scripts/droidlens/droidlens adb swipe 50 80 50 20 300
scripts/droidlens/droidlens adb install-apk app-debug.apk --json
scripts/droidlens/droidlens adb start-app --app auto --fresh --json
scripts/droidlens/droidlens adb force-stop --app auto --json
```

ADB 安全边界见 [docs/ai-adb.md](docs/ai-adb.md)。

## 环境变量

| 变量 | 用途 |
|---|---|
| `DROIDLENS_ADB` | 强制指定 adb 路径 |
| `DROIDLENS_SERIAL` | 多设备时选择目标设备 |
| `DROIDLENS_APP` | 默认 App：`auto`、`PKG` 或 `PKG/.Activity` |
| `DROIDLENS_APP_VARIANT` | 选择 Gradle flavor / build variant |
| `DROIDLENS_PROFILE` | 配置文件路径，默认 `<project>/.droidlens/profile.json` |
| `DROIDLENS_PROJECT_ROOT` | 项目根目录覆盖 |
| `DROIDLENS_STAY_AWAKE=0` | 关闭自动 `adb shell svc power stayon true` |
| `DROIDLENS_MAX_IMAGE_BYTES=256000` | 拒绝过大的非 raw 截图 |
| `DROIDLENS_ALLOW_LARGE_IMAGE=1` | 显式允许大截图 |
| `DROIDLENS_OUTPUT_DIR=/tmp` | 失败诊断包根目录 |
| `DROIDLENS_REDACT_TEXT=1` | 失败诊断包不写界面文本摘要 |
| `DROIDLENS_POLICY_FILE` | 授权策略文件路径 |
| `DROIDLENS_AUDIT_FILE` | audit log 路径 |

## 失败诊断包

结构化失败会返回 `errorCode`，通常还有 `bundle` 目录：

```text
reason.json
observe.json
screen.webp
screen.meta.json
hierarchy.xml
summary.json
*.err / *.log
```

AI 应该先检查诊断包，再决定是否重试。

常见错误码：

```text
adb_not_found
device_not_authorized
multiple_devices
app_not_installed
app_resolve_ambiguous
screencap_failed
xml_dump_failed
tap_target_not_found
approval_required
meta_device_mismatch
permission_dialog
crash_or_anr_dialog
external_chooser
unknown_page
route_not_found
edge_stale
terminal_mismatch
```

## 开发

提交前建议运行：

```bash
bash -n scripts/droidlens/*.sh scripts/droidlens/droidlens tests/droidlens/run.sh
shellcheck -x -P scripts/droidlens scripts/droidlens/*.sh scripts/droidlens/droidlens tests/droidlens/run.sh
python3 -m py_compile scripts/droidlens/*.py
tests/droidlens/run.sh
```

测试尽可能使用模拟 ADB，不依赖真机。

## 许可证

DroidLens 使用 [Apache License 2.0](LICENSE) 发布。

Copyright 2026 DroidLens contributors.
