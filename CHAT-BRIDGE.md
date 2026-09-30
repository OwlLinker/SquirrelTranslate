# Chat Bridge 使用说明

## 先看它解决什么痛点

使用 Chat 为本地项目编码时，Chat 对话和电脑上的项目文件是分开的。用户通常需要手工复制项目内容和代码，容易遇到以下问题：

- Chat 看不到项目最新状态；
- 不小心发送私密文件，或把旧版本源码提供给 Chat；
- 漏复制代码，或者把同一份修改重复应用；
- Chat 返回的代码缺少安全检查，应用后才发现语法错误；
- 想继续使用 Chat 服务，却不想开发 API 集成或更换编码工具。

ChatBridge 用项目快照、完整 Patch 和本地校验把这些步骤连起来，让 Chat 继续负责理解需求和生成代码，Bridge 负责把修改安全地落到本地 Git 项目。

具体来说，它在落地前后完成敏感信息过滤、Patch 校验、语法检查和失败回滚。

## 安全风险与账号安全

ChatBridge 不能承诺账号绝对不会被限制。它不是 OpenAI 官方工具，用户仍需遵守当前的 [OpenAI 使用条款](https://openai.com/policies/terms-of-use/) 和[使用政策](https://openai.com/policies/usage-policies/)。

它不使用 API Key、私有接口或反向代理，不绕过 Chat 限额，也不会默认自动发送请求、切换账号、规避验证码或提交 Git。若显式开启 Hammerspoon 的失败诊断自动发送，`.chatgpt/patch-error.txt` 和失败 Patch 可能会被自动发送到当前确认的普通 Chat 对话。

需要特别注意：应用或浏览器自动读取 Diff、以及 Hammerspoon，都属于程序化读取界面内容。它们比手工复制更方便，但也带来额外的规则不确定性。当前 OpenAI 条款包含对自动或程序化提取的限制，因此无法保证这种自动化方式一定被允许。

如果最优先考虑账号安全，请使用“复制 Patch → 手工应用”的方式；不要运行无人值守循环、批量任务、多账号并行或规避服务限额的操作。出现警告、验证码、异常登录验证或账号限制时，立即停止自动化并按官方提示处理。

它支持三种应用方式：

1. Terminal 从剪贴板手动应用 Patch；
2. 没有 Hammerspoon 时，脚本自动读取 ChatGPT/Codex 应用、Safari 或 Chrome 系浏览器中的最后一个 `Diff` 并应用；
3. 有 Hammerspoon 时，继续使用 `Tab+A` 自动读取、应用并重载 Hammerspoon 配置。

普通 Chat 不直接访问本地文件。项目内容通过上下文快照或变化快照提供给 Chat，Chat 返回 Patch 后由本地 Bridge 校验和应用。

## 文件命名与职责

当前文件名按“动作 + 运行环境”区分，但不会把不同职责都命名成 `read-last-diff`：

| 文件 | 运行环境 | 职责 |
|---|---|---|
| `tools/chat-apply-shell.sh` | Shell/Terminal | 核心 Patch 应用器；负责校验、应用、语法检查、失败回滚和诊断 |
| `tools/chat-apply-hammerspoon.sh` | Hammerspoon | Hammerspoon 状态包装器；调用 Shell 核心并返回 Toast 状态，不负责读取 ChatGPT 界面 |
| `tools/chat-read-last-diff.sh` | Shell/Terminal | 自动读取 ChatGPT 最后一个 `Diff`，再调用 `chat-apply-shell.sh` |
| `tools/chat-read-last-diff.swift` | macOS 辅助功能 | 被 Shell 入口调用的界面读取器，只负责提取 Diff，不负责应用 |

因此，`chat-read-last-diff.sh` 不是 Hammerspoon 脚本；Hammerspoon 的入口仍然是
`chat-apply-hammerspoon.sh`。两者最终都会复用同一个
`chat-apply-shell.sh` 核心，避免 Shell 和 Hammerspoon 使用两套 Patch 逻辑。

### 选择入口

| 使用场景 | 执行方式 |
|---|---|
| 已经手工复制完整 Patch | `./tools/chat-apply-shell.sh` |
| 不使用 Hammerspoon，直接读取 ChatGPT/Codex、Safari 或 Chrome 系浏览器最后一个 Diff | `./tools/chat-read-last-diff.sh` |
| 使用 Hammerspoon 的 `Tab+A` | 直接按 `Tab+A`，由 Lua 调用 `chat-apply-hammerspoon.sh` |
| 撤销最近一次成功应用 | `./tools/chat-apply-shell.sh --undo` |

## 一、安装到项目

Bridge 需要目标项目是 Git 项目。

安装器本身是单文件，可以放在任意目录。使用绝对路径调用：

```bash
/path/to/chat-bridge-install.sh --force /path/to/your-project
```

例如：

```bash
/path/to/chat-bridge-install.sh --force /path/to/your-project
```

安装完成后，目标项目会有：

```text
your-project/
├── tools/
│   ├── chat-apply-shell.sh
│   ├── chat-apply-hammerspoon.sh
│   ├── chat-read-last-diff.sh
│   ├── chat-bridge-install.sh
│   ├── chat-context.sh
│   └── chat-read-last-diff.swift
└── .chatgpt/
    └── PATCH-BASELINE.md
```

如果目标文件已经存在，必须明确使用 `--force` 才会更新。安装器不会复制旧的失败 Patch、错误报告或项目快照。

安装器默认会先检查全部待安装文件，再开始写入，避免因中途发现冲突而留下半套 Bridge 文件。新安装的 Shell 脚本会自动带有可执行权限。

### 运行依赖

核心 Patch 应用需要：

- macOS、Git、zsh、Python 3、`pbcopy` 和 `pbpaste`；
- 自动读取 ChatGPT/Codex 界面还需要 Xcode Command Line Tools 提供的 `swiftc`，以及终端的辅助功能权限；
- 修改 JavaScript 时需要 Node.js；修改 HTML 时需要 HTML Tidy。可以通过 `CHAT_BRIDGE_TIDY_BIN` 指定 Tidy 的路径。

如果不需要某类文件的检查，不要把该类文件放进本次 Patch；缺少对应检查器会让 Patch 失败并自动回滚。

## 二、生成项目上下文

进入目标项目根目录：

```bash
cd /path/to/your-project
```

### 新对话：完整项目

```bash
./tools/chat-context.sh full
```

生成：

```text
.chatgpt/project-context.md
```

把该文件提供给新 Chat，并发送：

```text
这是当前项目的完整源码快照。后续代码分析以这个文件中的实际项目内容为准。
```

### 已有对话：只发送变化

项目修改后执行：

```bash
./tools/chat-context.sh diff
```

生成：

```text
.chatgpt/project-diff.md
```

把该文件提供给当前 Chat，并发送：

```text
项目代码修改以后，只生成变化。

这是项目相对于之前完整快照的最新变化，以这个 diff 更新当前代码状态。
```

上下文脚本会排除 `.git`、`.chatgpt`、依赖目录、构建目录、缓存目录和常见敏感文件。仍应在发送前检查快照内容，不要把密码、私钥、Token 或环境变量发送给 Chat。

### 项目专用忽略列表

需要追加项目专用规则时，在目标项目创建 `.chatgpt/ignore`，每行写一个 Git ignore 风格模式：

```gitignore
# 本地数据和测试资产
fixtures/
*.sqlite
local-notes.md
```

也可以临时指定其他文件：

```bash
CHAT_BRIDGE_IGNORE_FILE=/path/to/project.ignore \
  ./tools/chat-context.sh full
```

忽略列表只影响 `full` 和 `diff` 快照，不改变 Patch 应用范围；密码、私钥、`.env` 和凭据路径仍由内置规则强制排除。

## 三、让 Chat 输出 Patch

要求 Chat 只输出一个完整的 unified diff：

```text
请根据当前项目源码完成修改。

只输出一个完整、连续的 unified diff 代码块，不要输出解释文字。
Patch 必须使用项目根目录相对路径，并能够通过：

git apply --recount --check
```

Patch 必须包含标准文件头：

```diff
diff --git a/path/to/file b/path/to/file
--- a/path/to/file
+++ b/path/to/file
```

不要把多个独立 Patch 拼接到同一个代码块中，也不要使用 `...` 省略内容。

## 四、应用 Patch

### 方式 A：Terminal 手动剪贴板

复制 Chat 输出的完整 Patch，然后在项目根目录执行：

```bash
./tools/chat-apply-shell.sh
```

也可以明确指定一个已有的 Patch 文件，跳过剪贴板：

```bash
./tools/chat-apply-shell.sh --patch-file /path/to/complete.patch
```

`--patch-file` 适合脚本调用或需要保留 Patch 文件的场景。普通 Terminal 模式会输出完整日志；成功时不会覆盖剪贴板，失败时会把诊断材料写入剪贴板，方便直接粘贴回 Chat。

脚本会自动执行：

1. 读取剪贴板纯文本；
2. 清理 Markdown 代码围栏和换行格式；
3. 执行 `git apply --recount --check`；
4. 应用 Patch；
5. 检查受影响的 Shell、JSON、JavaScript、CSS 和 HTML 文件；
6. 语法检查失败时自动撤销本次 Patch；
7. 失败时保存诊断并复制修复材料到剪贴板。

### 方式 B：没有 Hammerspoon 的一键应用

确保 ChatGPT/Codex macOS 应用、Safari 或支持的 Chrome 系浏览器正在运行，并且最后一个助手回复中包含 `Diff` 代码块，然后执行：

```bash
./tools/chat-read-last-diff.sh
```

该脚本会：

1. 通过 macOS Accessibility API 读取最后一个助手 `Diff`；
2. 自动编译并缓存 `chat-read-last-diff.swift`；
3. 把读取到的内容交给 `chat-apply-shell.sh`；
4. 复用所有 Patch 校验、语法检查、撤销和失败诊断逻辑；
5. 清理本次使用的临时 Patch 文件。

首次使用需要在“系统设置 → 隐私与安全性 → 辅助功能”中允许执行脚本的 Terminal 或 iTerm 控制 ChatGPT/Codex。

该方式不需要 Hammerspoon，也不会执行 Hammerspoon 配置重载。它支持 ChatGPT/Codex macOS 应用、Safari 和 Chrome 系浏览器。浏览器 Accessibility 结构可能随版本变化；读取失败时改用方式 A 或 Hammerspoon 路径。

读取来源可以显式选择：

```bash
CHATGPT_SOURCE=native ./tools/chat-read-last-diff.sh
CHATGPT_SOURCE=chrome ./tools/chat-read-last-diff.sh
CHATGPT_SOURCE=safari ./tools/chat-read-last-diff.sh
CHATGPT_SOURCE=auto ./tools/chat-read-last-diff.sh
```

Chrome 系支持 Chrome、Chromium、Edge、Brave、Vivaldi 和 Arc。特殊应用可以指定 Bundle ID：

```bash
CHATGPT_BUNDLE_ID=com.google.Chrome ./tools/chat-read-last-diff.sh
```

### 方式 C：Hammerspoon Tab+A

在 `OwlLinkerHS.spoon` 中按下 `Tab+A` 一次开启持久监控：

```text
Tab+A
```

Hammerspoon 随后会：

1. 监控 ChatGPT/Codex 的发送和回复完成状态，即使应用不在前台；
2. 读取每次完成回复中的 `Diff`；
3. 写入唯一临时 Patch 文件并调用 `chat-apply-hammerspoon.sh --patch-file`；
4. Toast 显示简短状态；
5. 详细异常输出到 Hammerspoon 控制台；
6. 只有真正修改成功时才调用 `HMReloadConfig.lua`；
7. 重载后继续保持监控，等待下一次发送。

再次按 `Tab+A` 关闭监控。如果同时存在运行中的 Patch 任务，监控不会启动第二个任务。

监控开启且 ChatGPT/Codex 位于前台时，发送按钮周围会显示金黄色描边；应用在后台时监控仍继续，但不会把覆盖层显示在其他应用上。

绿色表示提交成功，红色表示提交失败，黄色表示重复提交或 Patch 已经应用过；下一轮发送开始后恢复为监控状态颜色。

显式开启失败诊断自动发送后，应用失败时监控才会读取 `.chatgpt/patch-error.txt` 和 `.chatgpt/failed.patch`，自动填入普通 Chat 输入框并提交失败诊断；该功能默认关闭。成功、重复应用和非 Chat 窗口不会自动发送诊断。

自动应用只支持普通 Chat 对话；Codex 工作区、设置页和其他非 Chat 窗口不会应用 Patch。

该功能默认关闭，不会自动发送普通提示词或点击发送按钮。同一个 Diff 只处理一次；失败诊断自动发送另有独立开关，默认关闭。它仍属于
程序化读取 ChatGPT 界面的自动化，优先考虑账号安全时应保持关闭。

Hammerspoon 调用关系如下：

```text
Tab+A
  ↓
ChatGPTApplyPatch.lua 自动读取 Diff
  ↓
chat-apply-hammerspoon.sh --patch-file <临时 Patch>
  ↓
chat-apply-shell.sh
  ↓
校验、应用、语法检查
```

`chat-apply-hammerspoon.sh` 的标准输出只用于 Toast：

```text
修改成功
Patch已应用，无需重复修改
Patch损坏，诊断已复制
```

详细 Git、语法检查和失败原因输出到 Hammerspoon 控制台。只有严格返回 `修改成功` 时才会调用 `HMReloadConfig.lua`。

## 五、状态说明

### 修改成功

```text
修改成功
```

表示 Patch 已通过检查、已写入源码，并且受影响文件的语法检查成功。

### 已经应用

```text
Patch已应用，无需重复修改
```

表示源码没有再次修改。Terminal 或 Hammerspoon 控制台会附带：

- Git 分支；
- 当前 HEAD 短哈希；
- Patch-ID；
- 工作区是否有未提交修改；
- 严格反向检查或弱匹配的判定依据。

### Patch 失败

```text
Patch损坏，诊断已复制
```

详细信息会写入：

```text
.chatgpt/failed.patch
.chatgpt/patch-error.txt
```

失败 Patch 不进入源码基线。诊断和失败 Patch 会自动复制到剪贴板，回到 Chat 后直接粘贴并发送，让 Chat 只修复当前 Patch 的失败原因。

## 六、Patch 基线规则

必须始终以最近一个成功、无错误的版本为基线。

- 用户确认 Patch 正常，或没有反馈错误而直接提出新需求时，Patch 才能成为后续基线；
- 用户反馈 Patch 应用失败、语法错误、启动失败、运行时报错或功能异常时，该 Patch 完全视为未应用；
- 修复失败 Patch 时，必须回到失败前最近一个成功版本；
- 禁止在失败 Patch 上继续叠加修改；
- 用户提供真实源码文件时，以该文件作为唯一最新基线；
- `.chatgpt/failed.patch` 和 `.chatgpt/patch-error.txt` 不是源码，不能当作已应用修改。

完整规则保存在：

```text
.chatgpt/PATCH-BASELINE.md
```

## 七、常用文件

```text
.chatgpt/project-context.md   # 完整项目快照
.chatgpt/project-diff.md      # 当前工作区变化
.chatgpt/last-applied.patch   # 最近一次成功 Patch，可用于撤销
.chatgpt/failed.patch         # 最近一次失败 Patch
.chatgpt/patch-error.txt      # 最近一次失败诊断
```

撤销最近一次成功应用的 Patch：

```bash
./tools/chat-apply-shell.sh --undo
```

只有在当前源码没有发生额外变化时，Bridge 才允许安全撤销。

## 八、故障排查

### 找不到 Diff

- 确认 ChatGPT/Codex 应用、Safari 或支持的 Chrome 系浏览器正在运行；
- 确认最后一个助手回复确实包含 `Diff` 代码块；
- 确认 Terminal 或 iTerm 已获得辅助功能权限；
- 浏览器页面读取失败时，请改用剪贴板模式或 `--patch-file`。

默认模式为 `auto`，会尝试原生应用和已运行的支持浏览器。也可以指定来源或 Bundle ID：

```bash
CHATGPT_SOURCE=safari ./tools/chat-read-last-diff.sh
CHATGPT_BUNDLE_ID=com.example.app ./tools/chat-read-last-diff.sh
```

### 找不到 `swiftc`

安装 Xcode Command Line Tools：

```bash
xcode-select --install
```

### 中文乱码

Bridge 已强制使用 UTF-8 locale。重新从 Chat 复制完整 Patch，不要继续使用旧的 `.chatgpt/failed.patch`。

### Patch 与源码不匹配

重新执行：

```bash
./tools/chat-context.sh diff
```

把最新变化提供给 Chat，并要求它基于最新源码重新生成完整 Patch。不要在失败 Patch 上继续叠加修改。

### 本地验证

只检查脚本语法：

```bash
for f in tools/chat-apply-shell.sh tools/chat-apply-hammerspoon.sh \
  tools/chat-read-last-diff.sh tools/chat-bridge-install.sh; do
  zsh -n "$f" || exit 1
done
bash -n tools/chat-context.sh
swiftc -parse tools/chat-read-last-diff.swift
```

应用器的完整流程应使用临时 Git 项目验证，包括：首次应用、重复应用、语法错误后的自动回滚、失败诊断和 `--undo`。验证时不要在真实项目上制造错误 Patch。
