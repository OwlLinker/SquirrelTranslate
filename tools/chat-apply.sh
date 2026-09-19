#!/bin/zsh
set -euo pipefail

# Hammerspoon 由图形界面启动时可能没有继承终端的 UTF-8 locale。
# pbpaste/pbcopy 会依据 locale 转码，缺少 UTF-8 时中文会被替换成 ?。
export LANG="en_US.UTF-8"
export LC_ALL="en_US.UTF-8"

# Hammerspoon 调用模式：复用本脚本的完整逻辑，但只返回一行状态。
if [[ "${1:-}" == "--hammerspoon" ]]; then
    shift

    script_dir="${0:A:h}"
    project_root="${script_dir:h}"
    output_file="$(mktemp -t chat-apply-hammerspoon)"

    cleanup_hammerspoon() {
        rm -f "$output_file"
    }

    trap cleanup_hammerspoon EXIT

    if cd "$project_root" && "$0" "$@" >"$output_file" 2>&1; then
        print -r -- "修改成功"
        exit 0
    fi

    exit_code=$?

    if grep -Fq "错误类型：Patch 很可能已经应用过" "$output_file" ||
       grep -Fq "Type: already applied" "$output_file"
    then
        print -r -- "Patch已应用，无需重复修改"
    else
        print -r -- "Patch损坏，诊断已复制"
    fi

    exit "$exit_code"
fi

# ============================================================
# ChatGPT → Local Project Patch Bridge
#
# 用法：
#
#   复制 ChatGPT 输出的完整 unified diff，然后执行：
#
#       ./tools/chat-apply.sh
#
#   Patch 检查通过后自动应用到本地原文件。
#
#   如果 Patch 失败：
#
#       1. 自动诊断错误
#       2. 只保留最近一次失败：
#
#            .chatgpt/failed.patch
#            .chatgpt/patch-error.txt
#
#       3. 自动把：
#
#            修复要求
#            + 当前错误诊断
#            + 当前失败 Patch
#
#          复制到 macOS 剪贴板
#
#       4. 自动切回 ChatGPT
#
#      然后只需要：
#
#            Command + V
#
#      并发送。
#
#   撤销最近一次成功应用的 Chat Patch：
#
#       ./tools/chat-apply.sh --undo
#
# ============================================================


# ------------------------------------------------------------
# 项目根目录
# ------------------------------------------------------------

if ! ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    echo "错误：当前目录不在 Git 项目中。"
    exit 1
fi

cd "$ROOT"


# ------------------------------------------------------------
# Bridge 文件
# ------------------------------------------------------------

BRIDGE_DIR="$ROOT/.chatgpt"

LAST_PATCH="$BRIDGE_DIR/last-applied.patch"
FAILED_PATCH="$BRIDGE_DIR/failed.patch"
ERROR_REPORT="$BRIDGE_DIR/patch-error.txt"

mkdir -p "$BRIDGE_DIR"


# ------------------------------------------------------------
# 通用工具
# ------------------------------------------------------------

print_hr() {
    printf '%s\n' "------------------------------------------------------------"
}


is_integer() {
    [[ "${1:-}" == <-> ]]
}


# ------------------------------------------------------------
# 显示 Patch 指定行附近内容
# ------------------------------------------------------------

show_patch_context() {
    local patch="$1"
    local line="$2"

    is_integer "$line" || return 0

    local start=$(( line - 8 ))
    local end=$(( line + 8 ))

    (( start < 1 )) && start=1

    echo
    echo "Patch 故障位置附近："
    echo

    nl -ba "$patch" |
        sed -n "${start},${end}p" |
        awk -v bad="$line" '
        {
            number=$1
            $1=""
            sub(/^[ \t]+/, "", $0)

            if (number == bad)
                printf "> %5s | %s\n", number, $0
            else
                printf "  %5s | %s\n", number, $0
        }'
}


# ------------------------------------------------------------
# 显示当前源码指定行附近内容
# ------------------------------------------------------------

show_source_context() {
    local file="$1"
    local line="$2"

    [[ -f "$file" ]] || return 0
    is_integer "$line" || return 0

    local start=$(( line - 8 ))
    local end=$(( line + 8 ))

    (( start < 1 )) && start=1

    echo
    echo "当前本地源码附近："
    echo

    nl -ba "$file" |
        sed -n "${start},${end}p"
}


# ------------------------------------------------------------
# 创建诊断报告
#
# 注意：
# 使用 >，不是 >>
#
# 因此报告始终覆盖旧内容，
# 永远只代表当前这一次失败。
# ------------------------------------------------------------

write_report_header() {
    {
        echo "Chat Bridge Patch 诊断报告"
        echo
        echo "Project: $ROOT"
        echo "Branch: $(git branch --show-current 2>/dev/null || true)"
        echo "HEAD: $(git rev-parse --short HEAD 2>/dev/null || true)"
        echo
        echo "Git status:"
        echo
        git status --short || true
        echo
    } > "$ERROR_REPORT"
}


# ------------------------------------------------------------
# 从 corrupt patch 错误中提取 Patch 行号
#
# 支持：
#
#   error: corrupt patch at line 122
#
#   error: corrupt patch at /var/.../xxx.patch:122
# ------------------------------------------------------------

extract_corrupt_line() {
    local error_file="$1"
    local line=""

    line="$(
        sed -nE \
            's/.*corrupt patch at line ([0-9]+).*/\1/p' \
            "$error_file" |
        head -1
    )"

    if [[ -z "$line" ]]; then
        line="$(
            sed -nE \
                's/.*corrupt patch at .*:([0-9]+)[[:space:]]*$/\1/p' \
                "$error_file" |
            head -1
        )"
    fi

    printf '%s' "$line"
}


# ------------------------------------------------------------
# 把本次失败诊断 + 本次失败 Patch
# 自动复制到 macOS 剪贴板
#
# 不读取任何历史记录。
# ------------------------------------------------------------

copy_failure_bundle_to_clipboard() {
    local patch="$1"

    {
        cat <<'EOF'
下面是本地 Chat Bridge 自动生成的最新一次 Patch 失败诊断。

请仅根据本次错误和本次失败 Patch 修复。

要求：

1. 保持原修改目标不变，不要重新设计功能。
2. 只修复导致 Patch 无法应用的问题。
3. 必须基于下面提供的真实 Patch 和错误信息。
4. 输出一个完整、连续的 unified diff。
5. 必须使用标准：
   diff --git a/... b/...
6. 所有修改必须放在同一个 diff 代码块中。
7. diff 内不要插入解释文字。
8. 不要使用 ... 省略任何代码。
9. 所有文件路径使用项目根目录相对路径。
10. 确保每个 hunk 完整。
11. Patch 必须能够通过：

    git apply --recount --check

只输出修正后的完整 Patch。

===== BEGIN LATEST PATCH ERROR REPORT =====

EOF

        if [[ -f "$ERROR_REPORT" ]]; then
            cat "$ERROR_REPORT"
        else
            echo "(没有生成 patch-error.txt)"
        fi

        cat <<'EOF'

===== END LATEST PATCH ERROR REPORT =====


===== BEGIN LATEST FAILED PATCH =====

EOF

        if [[ -f "$patch" ]]; then
            cat "$patch"
        else
            echo "(没有找到 failed.patch)"
        fi

        cat <<'EOF'

===== END LATEST FAILED PATCH =====
EOF

} | /usr/bin/pbcopy
}


# ------------------------------------------------------------
# 自动激活 ChatGPT
# ------------------------------------------------------------

activate_chatgpt() {
    osascript \
        -e 'tell application "ChatGPT" to activate' \
        >/dev/null 2>&1 ||
    open -a "ChatGPT" \
        >/dev/null 2>&1 ||
    true
}


# ------------------------------------------------------------
# Patch 失败诊断
# ------------------------------------------------------------

diagnose_failure() {
    local patch="$1"
    local error_file="$2"

    #
    # failed.patch 永远覆盖旧版本。
    #
    cp "$patch" "$FAILED_PATCH"

    #
    # patch-error.txt 永远重新创建。
    #
    write_report_header

    {
        echo "Git error:"
        echo
        cat "$error_file"
        echo
    } >> "$ERROR_REPORT"


    echo
    print_hr
    echo


    # ========================================================
    # 1. Patch 本身结构损坏
    # ========================================================

    if grep -q 'corrupt patch at' "$error_file"; then

        local line
        line="$(extract_corrupt_line "$error_file")"

        echo "错误类型：Patch 结构损坏"
        echo
        echo "Git 无法解析这个 unified diff。"
        echo
        echo "这不是本地源码冲突，而是 Patch 本身格式不合法。"

        if [[ -n "$line" ]] && is_integer "$line"; then
            echo
            echo "Git 报告的故障行：$line"

            show_patch_context "$patch" "$line"
        fi

        echo
        echo "常见原因："
        echo
        echo "  1. @@ hunk 行数与实际内容不一致"
        echo "  2. 某个 hunk 被截断"
        echo "  3. diff 中混入了解释文字"
        echo "  4. Patch 复制不完整"
        echo "  5. 某行缺少 unified diff 要求的前缀"
        echo "  6. 多个代码块没有完整复制"
        echo
        echo "已经自动尝试："
        echo
        echo "  ✓ UTF-8 BOM 清理"
        echo "  ✓ CRLF → LF"
        echo "  ✓ Markdown code fence 提取"
        echo "  ✓ git apply --recount"
        echo
        echo "上述处理后仍然失败，因此需要修正 Patch。"

        {
            echo "Diagnosis:"
            echo
            echo "Type: corrupt patch"
            echo "Patch structure is invalid."
            echo "Corrupt patch line: ${line:-unknown}"
            echo
        } >> "$ERROR_REPORT"

        if [[ -n "$line" ]] && is_integer "$line"; then

            local report_start=$(( line - 8 ))
            local report_end=$(( line + 8 ))

            (( report_start < 1 )) && report_start=1

            {
                echo "Patch context:"
                echo

                nl -ba "$patch" |
                    sed -n "${report_start},${report_end}p"

                echo
            } >> "$ERROR_REPORT"
        fi

        return
    fi


    # ========================================================
    # 2. Patch 很可能已经应用过
    #
    # 必须在普通 patch failed 判断之前进行。
    # ========================================================

    if git apply \
        --recount \
        --check \
        -R \
        "$patch" \
        >/dev/null 2>&1
    then
        echo "错误类型：Patch 很可能已经应用过"
        echo
        echo "该 Patch 无法再次正向应用，"
        echo "但能够通过反向安全检查："
        echo
        echo "  git apply --recount --check -R"
        echo
        echo "这通常表示相同修改已经存在于当前源码中。"
        echo
        echo "源码没有再次修改。"

        {
            echo "Diagnosis:"
            echo
            echo "Type: already applied"
            echo
            echo "Reverse apply check succeeded."
            echo "The patch appears to already be applied."
            echo
        } >> "$ERROR_REPORT"

        return
    fi


    # ========================================================
    # 3. Patch 与当前源码不匹配
    # ========================================================

    if grep -qE 'patch failed: .+:[0-9]+' "$error_file"; then

        local failed=""
        local file=""
        local line=""

        failed="$(
            sed -nE \
                's/^error: patch failed: (.+):([0-9]+)$/\1|\2/p' \
                "$error_file" |
            head -1
        )"

        if [[ -z "$failed" ]]; then
            failed="$(
                sed -nE \
                    's/.*patch failed: (.+):([0-9]+).*/\1|\2/p' \
                    "$error_file" |
                head -1
            )"
        fi

        if [[ -n "$failed" ]]; then
            file="${failed%%|*}"
            line="${failed##*|}"
        fi

        echo "错误类型：Patch 与当前源码不匹配"

        if [[ -n "$file" ]]; then
            echo
            echo "文件："
            echo
            echo "  $file"
        fi

        if [[ -n "$line" ]] && is_integer "$line"; then
            echo
            echo "Patch 目标位置："
            echo
            echo "  line $line"

            show_source_context "$file" "$line"
        fi

        echo
        echo "判断："
        echo
        echo "  Patch 语法通常没有问题。"
        echo "  但生成 Patch 时使用的源码上下文"
        echo "  与当前本地源码已经不一致。"
        echo
        echo "常见原因："
        echo
        echo "  - 本地代码在生成 Patch 后又修改过"
        echo "  - Chat 使用的是旧 project-context.md"
        echo "  - 前一轮 Patch 已修改了附近代码"
        echo "  - 当前 Git branch 已变化"
        echo "  - Patch 基于另一版本生成"

        {
            echo "Diagnosis:"
            echo
            echo "Type: source context mismatch"
            echo
            echo "Patch syntax appears valid,"
            echo "but source context does not match."
            echo
            echo "File: ${file:-unknown}"
            echo "Target line: ${line:-unknown}"
            echo
        } >> "$ERROR_REPORT"

        if [[ -n "$file" ]] &&
           [[ -f "$file" ]] &&
           [[ -n "$line" ]] &&
           is_integer "$line"
        then

            local report_start=$(( line - 8 ))
            local report_end=$(( line + 8 ))

            (( report_start < 1 )) && report_start=1

            {
                echo "Current source context:"
                echo

                nl -ba "$file" |
                    sed -n "${report_start},${report_end}p"

                echo
            } >> "$ERROR_REPORT"
        fi

        return
    fi


    # ========================================================
    # 4. 文件路径错误
    # ========================================================

    if grep -qE \
        'No such file or directory|does not exist in index|unable to find|No such file' \
        "$error_file"
    then
        echo "错误类型：Patch 文件路径与当前项目不一致"
        echo
        echo "可能原因："
        echo
        echo "  1. Patch 使用了错误文件路径"
        echo "  2. 文件已经移动"
        echo "  3. 文件已经重命名"
        echo "  4. Patch 来自其他项目或分支"

        {
            echo "Diagnosis:"
            echo
            echo "Type: invalid file path"
            echo
            echo "Patch refers to a path that cannot be resolved"
            echo "in the current project."
            echo
        } >> "$ERROR_REPORT"

        return
    fi


    # ========================================================
    # 5. 其他 Patch 内容异常
    # ========================================================

    if grep -qE \
        'cannot apply binary patch|unrecognized input|invalid path' \
        "$error_file"
    then
        echo "错误类型：Patch 内容或目标异常"
        echo
        echo "Git 原始错误："
        echo
        cat "$error_file"

        {
            echo "Diagnosis:"
            echo
            echo "Type: invalid patch content"
            echo
            echo "Patch target or patch content is invalid."
            echo
        } >> "$ERROR_REPORT"

        return
    fi


    # ========================================================
    # 6. 无法自动分类
    # ========================================================

    echo "错误类型：无法自动分类"
    echo
    echo "Git 原始错误："
    echo
    cat "$error_file"

    {
        echo "Diagnosis:"
        echo
        echo "Type: unclassified"
        echo
        echo "Unclassified git apply failure."
        echo
    } >> "$ERROR_REPORT"
}


# ------------------------------------------------------------
# 处理真实 Patch 失败后的公共流程
# ------------------------------------------------------------

finish_failure() {
    echo
    print_hr
    echo
    echo "源码未发生任何修改。"
    echo
    echo "本次故障 Patch："
    echo
    echo "  .chatgpt/failed.patch"
    echo
    echo "本次诊断报告："
    echo
    echo "  .chatgpt/patch-error.txt"

    copy_failure_bundle_to_clipboard "$FAILED_PATCH"

    echo
    echo "✓ 本次诊断信息和失败 Patch"
    echo "  已自动复制到 macOS 剪贴板。"
    echo
    echo "✓ 不包含任何历史错误记录。"
    echo
    echo "✓ 正在切回 ChatGPT..."
    echo
    echo "回到当前会话后只需要："
    echo
    echo "  Command + V"
    echo
    echo "然后发送。"
    echo

    activate_chatgpt
}


# ------------------------------------------------------------
# 撤销最近一次成功 Patch
#
# --undo 不清除失败诊断。
#
# 因为它不是一次新的 Patch 应用请求。
# ------------------------------------------------------------

undo_last_patch() {

    if [[ ! -f "$LAST_PATCH" ]]; then
        echo "没有可撤销的 Bridge Patch。"
        exit 1
    fi

    echo
    echo "准备撤销最近一次 Chat Patch："
    echo

    git apply \
        --recount \
        --stat \
        "$LAST_PATCH" || true

    echo
    echo "执行反向安全检查..."
    echo

    if ! git apply \
        --recount \
        --check \
        -R \
        "$LAST_PATCH"
    then
        echo
        echo "错误：当前源码已经发生额外变化。"
        echo
        echo "无法安全撤销最近一次 Chat Patch。"
        echo
        echo "源码未发生任何修改。"

        exit 1
    fi

    echo "✓ 可以安全撤销"
    echo

    printf "确认撤销最近一次 Chat Patch？ [y/N] "
    read -r answer

    case "$answer" in
        y|Y|yes|YES)
            ;;
        *)
            echo
            echo "已取消。"
            exit 0
            ;;
    esac

    git apply \
        --recount \
        -R \
        "$LAST_PATCH"

    rm -f "$LAST_PATCH"

    echo
    echo "✓ 最近一次 Chat Patch 已撤销。"
    echo

    git status --short
}


# ------------------------------------------------------------
# --undo
#
# 必须放在“清除旧错误”之前。
# ------------------------------------------------------------

if [[ "${1:-}" == "--undo" ]]; then
    undo_last_patch
    exit 0
fi


# ------------------------------------------------------------
# 新一轮 Patch 应用开始
#
# 这里是关键：
#
# 每次正常执行 chat-apply.sh，
# 都先删除上一轮失败记录。
#
# 因此：
#
#   failed.patch
#   patch-error.txt
#
# 要么不存在，
# 要么只属于“当前这一轮”。
#
# 绝不会混入历史错误。
# ------------------------------------------------------------

rm -f "$FAILED_PATCH"
rm -f "$ERROR_REPORT"


# ------------------------------------------------------------
# 临时文件
# ------------------------------------------------------------

TMP_RAW="$(mktemp -t chatgpt-raw)"
TMP_PATCH="$(mktemp -t chatgpt-patch)"
TMP_ERROR="$(mktemp -t chatgpt-error)"


cleanup() {
    rm -f \
        "$TMP_RAW" \
        "$TMP_PATCH" \
        "$TMP_ERROR"
}


trap cleanup EXIT


# ------------------------------------------------------------
# 1. 从 macOS 剪贴板读取 ChatGPT 输出
# ------------------------------------------------------------

/usr/bin/pbpaste -Prefer txt > "$TMP_RAW"

if [[ ! -s "$TMP_RAW" ]]; then
    echo "错误：macOS 剪贴板为空。"
    exit 10
fi


# ------------------------------------------------------------
# 2. 标准化并提取 Patch
#
# 自动处理：
#
#   UTF-8 BOM
#   CRLF
#   CR
#   ```diff
#   ```patch
#   ```
#
# 从第一个：
#
#   diff --git a/... b/...
#
# 开始。
# ------------------------------------------------------------

if ! python3 - "$TMP_RAW" "$TMP_PATCH" <<'PY'
import sys
from pathlib import Path


src = Path(sys.argv[1])
dst = Path(sys.argv[2])


data = src.read_bytes()


# UTF-8 BOM
if data.startswith(b"\xef\xbb\xbf"):
    data = data[3:]


# 统一换行符
data = data.replace(b"\r\n", b"\n")
data = data.replace(b"\r", b"\n")


try:
    text = data.decode("utf-8")
except UnicodeDecodeError as exc:
    print(
        f"错误：剪贴板内容不是有效 UTF-8：{exc}",
        file=sys.stderr,
    )
    sys.exit(2)


lines = text.splitlines()


# ------------------------------------------------------------
# 找第一个 diff --git
# ------------------------------------------------------------

start = None

for index, line in enumerate(lines):
    if line.startswith("diff --git a/"):
        start = index
        break


if start is None:
    print(
        "错误：剪贴板中没有找到标准 Git Patch。",
        file=sys.stderr,
    )
    sys.exit(3)


# ------------------------------------------------------------
# 判断是否位于 Markdown fenced code block
# ------------------------------------------------------------

inside_fence = False
fence_marker = None

for index in range(start - 1, -1, -1):

    stripped = lines[index].strip()

    if not stripped:
        continue

    if stripped.startswith("```"):
        inside_fence = True
        fence_marker = "```"

    elif stripped.startswith("~~~"):
        inside_fence = True
        fence_marker = "~~~"

    break


# ------------------------------------------------------------
# 提取 Patch
# ------------------------------------------------------------

result = []


for line in lines[start:]:

    stripped = line.strip()

    if (
        inside_fence
        and fence_marker is not None
        and stripped == fence_marker
    ):
        break

    result.append(line)


# 清除尾部多余空行
while result and not result[-1].strip():
    result.pop()


if not result:
    print(
        "错误：提取后的 Patch 为空。",
        file=sys.stderr,
    )
    sys.exit(4)


dst.write_text(
    "\n".join(result) + "\n",
    encoding="utf-8",
)
PY
then
    echo
    echo "Patch 提取失败。"
    exit 11
fi


# ------------------------------------------------------------
# 3. 基本格式检查
#
# 这些属于输入问题，不生成诊断文件。
#
# 因为 ChatGPT 不需要根据 failed.patch 来修复。
# ------------------------------------------------------------

if [[ ! -s "$TMP_PATCH" ]]; then
    echo "错误：提取后的 Patch 为空。"
    exit 12
fi


if ! grep -q '^diff --git a/' "$TMP_PATCH"; then
    echo "错误：Patch 缺少标准 diff --git 文件头。"
    exit 13
fi


if ! grep -q '^--- ' "$TMP_PATCH"; then
    echo "错误：Patch 缺少 --- 文件头。"
    exit 14
fi


if ! grep -q '^+++ ' "$TMP_PATCH"; then
    echo "错误：Patch 缺少 +++ 文件头。"
    exit 15
fi


# ------------------------------------------------------------
# 4. 显示准备修改的文件
# ------------------------------------------------------------

echo
echo "准备应用以下修改："
echo

grep '^diff --git ' "$TMP_PATCH" |
    sed -E \
        's#^diff --git a/(.*) b/(.*)$#  \2#'

echo


# ------------------------------------------------------------
# 5. 安全检查
#
# --recount：
#
# ChatGPT 偶尔会生成：
#
#   @@ -120,8 +120,10 @@
#
# 但 hunk 中实际行数与 8 / 10 不完全一致。
#
# --recount 根据实际内容重新计算。
# ------------------------------------------------------------

echo "执行 Patch 结构及源码上下文检查..."
echo

: > "$TMP_ERROR"

if ! git apply \
    --recount \
    --check \
    --verbose \
    "$TMP_PATCH" \
    2>"$TMP_ERROR"
then

    #
    # 只有到这里才是真正值得发送给 ChatGPT
    # 进行 Patch 修复的错误。
    #

    diagnose_failure \
        "$TMP_PATCH" \
        "$TMP_ERROR"

    finish_failure

    exit 20
fi


# ------------------------------------------------------------
# 6. 检查通过
# ------------------------------------------------------------

echo "✓ Patch 结构正确"
echo "✓ Patch 与当前源码匹配"
echo "✓ 安全检查通过"
echo


# ------------------------------------------------------------
# 7. 显示修改统计
# ------------------------------------------------------------

git apply \
    --recount \
    --stat \
    "$TMP_PATCH" || true

echo


# ------------------------------------------------------------
# 8. 自动应用
#
# 不询问 y/N。
#
# 只有 git apply --check 完整通过后，
# 才会执行真正修改。
# ------------------------------------------------------------

echo "安全检查通过，自动应用 Patch..."
echo

: > "$TMP_ERROR"

if ! git apply \
    --recount \
    "$TMP_PATCH" \
    2>"$TMP_ERROR"
then

    #
    # 极少见情况：
    #
    # check 成功，但实际 apply 失败。
    #
    # 仍然只记录当前这一轮错误。
    #

    cp "$TMP_PATCH" "$FAILED_PATCH"

    write_report_header

    {
        echo "Git error during final apply:"
        echo
        cat "$TMP_ERROR"
        echo
        echo "Diagnosis:"
        echo
        echo "Type: final apply failure"
        echo
        echo "The safety check succeeded,"
        echo "but the final git apply command failed."
        echo
        echo "The working tree may have changed"
        echo "between check and apply."
        echo
    } >> "$ERROR_REPORT"

    echo "错误：安全检查通过，但实际应用 Patch 时发生异常。"
    echo
    cat "$TMP_ERROR"

    finish_failure

    exit 21
fi


# ------------------------------------------------------------
# 9. 保存最近一次成功 Patch
# ------------------------------------------------------------

cp "$TMP_PATCH" "$LAST_PATCH"


# ------------------------------------------------------------
# 10. 成功后确保不存在失败记录
#
# 理论上开始执行时已经删除，
# 这里再次清理，保证状态绝对明确。
# ------------------------------------------------------------

rm -f "$FAILED_PATCH"
rm -f "$ERROR_REPORT"


# ------------------------------------------------------------
# 11. 完成
# ------------------------------------------------------------

echo "✓ Patch 已成功应用到原项目文件。"
echo

git status --short

echo
echo "查看实际修改："
echo
echo "  git diff"
echo
echo "撤销本次 Bridge 修改："
echo
echo "  ./tools/chat-apply.sh --undo"
