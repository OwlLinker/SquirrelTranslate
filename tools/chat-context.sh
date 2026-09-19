#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-full}"

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
OUT_DIR="${ROOT}/.chatgpt"

MAX_FILE_BYTES="${MAX_FILE_BYTES:-524288}"       # 单文件 512 KB
MAX_TOTAL_BYTES="${MAX_TOTAL_BYTES:-12582912}"   # 总计约 12 MB

mkdir -p "${OUT_DIR}"

# 不修改项目 .gitignore，只在本地 Git exclude 中忽略 .chatgpt
if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_EXCLUDE="$(git -C "${ROOT}" rev-parse --git-path info/exclude)"
    mkdir -p "$(dirname "${GIT_EXCLUDE}")"

    if ! grep -qxF '/.chatgpt/' "${GIT_EXCLUDE}" 2>/dev/null; then
        printf '\n/.chatgpt/\n' >> "${GIT_EXCLUDE}"
    fi
fi

file_size() {
    local file="$1"

    if stat -f '%z' "${file}" >/dev/null 2>&1; then
        stat -f '%z' "${file}"
    else
        stat -c '%s' "${file}"
    fi
}

is_secret_path() {
    local path="$1"
    local base="${path##*/}"

    case "${path}" in
        .env|.env.*|*/.env|*/.env.*)
            return 0
            ;;
        *.pem|*.key|*.p12|*.pfx|*.mobileprovision)
            return 0
            ;;
        */.ssh/*|.ssh/*)
            return 0
            ;;
    esac

    case "${base}" in
        id_rsa|id_rsa.pub|id_ed25519|id_ed25519.pub)
            return 0
            ;;
        credentials|credentials.*|credentials_*|credentials-*)
            return 0
            ;;
        secrets|secrets.*|secrets_*|secrets-*)
            return 0
            ;;
    esac

    return 1
}

should_include() {
    local path="$1"
    local base="${path##*/}"

    case "${path}" in
        .git/*|*/.git/*)
            return 1
            ;;
        .chatgpt/*|*/.chatgpt/*)
            return 1
            ;;
        node_modules/*|*/node_modules/*)
            return 1
            ;;
        vendor/*|*/vendor/*)
            return 1
            ;;
        dist/*|*/dist/*)
            return 1
            ;;
        build/*|*/build/*)
            return 1
            ;;
        .cache/*|*/.cache/*)
            return 1
            ;;
        __pycache__/*|*/__pycache__/*)
            return 1
            ;;
    esac

    if is_secret_path "${path}"; then
        return 1
    fi

    # 常见文本/代码文件
    case "${path}" in
        *.lua|\
        *.json|\
        *.md|\
        *.txt|\
        *.sh|\
        *.bash|\
        *.zsh|\
        *.py|\
        *.js|\
        *.mjs|\
        *.cjs|\
        *.ts|\
        *.tsx|\
        *.jsx|\
        *.css|\
        *.scss|\
        *.html|\
        *.xml|\
        *.yaml|\
        *.yml|\
        *.toml|\
        *.ini|\
        *.conf|\
        *.cfg|\
        *.plist|\
        *.sql)
            return 0
            ;;
    esac

    # 常见无扩展名文本文件
    case "${base}" in
        README|LICENSE|Makefile|Dockerfile|Rakefile|Gemfile)
            return 0
            ;;
    esac

    return 1
}

append_file() {
    local output="$1"
    local rel="$2"
    local abs="${ROOT}/${rel}"

    [[ -f "${abs}" ]] || return 0
    should_include "${rel}" || return 0

    local size
    size="$(file_size "${abs}")"

    if (( size > MAX_FILE_BYTES )); then
        printf '\n===== SKIPPED LARGE FILE: %s (%s bytes) =====\n' \
            "${rel}" "${size}" >> "${output}"
        return 0
    fi

    printf '\n\n===== BEGIN FILE: %s =====\n' "${rel}" >> "${output}"
    cat "${abs}" >> "${output}"

    # 确保 END marker 从新行开始
    if [[ -s "${abs}" ]] && [[ "$(tail -c 1 "${abs}" 2>/dev/null || true)" != "" ]]; then
        printf '\n' >> "${output}"
    fi

    printf '===== END FILE: %s =====\n' "${rel}" >> "${output}"
}

write_header() {
    local output="$1"

    {
        printf '# Local project context\n\n'
        printf 'Project root: `%s`\n\n' "$(basename "${ROOT}")"

        if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
            printf 'Branch: `%s`\n\n' \
                "$(git -C "${ROOT}" branch --show-current 2>/dev/null || true)"

            printf 'HEAD: `%s`\n\n' \
                "$(git -C "${ROOT}" rev-parse --short HEAD 2>/dev/null || true)"
        fi

        cat <<'EOF'
This file is an automatically generated snapshot of a local source tree.

When analysing the project:

- Treat `===== BEGIN FILE: ... =====` as the exact file path.
- Do not invent files that are not present in this snapshot.
- Distinguish existing implementation from proposed changes.
- Ask for a newer diff/context snapshot if the answer depends on code that may have changed.

EOF
    } > "${output}"
}

generate_full() {
    local output="${OUT_DIR}/project-context.md"
    local tmp="${output}.tmp"

    write_header "${tmp}"

    {
        printf '\n# Repository status\n\n'
        printf '```text\n'

        if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
            git -C "${ROOT}" status --short || true
        else
            printf 'Not a Git repository.\n'
        fi

        printf '```\n'

        printf '\n# Project file tree\n\n'
        printf '```text\n'
    } >> "${tmp}"

    local files=()

    if git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        while IFS= read -r -d '' file; do
            should_include "${file}" || continue
            files+=("${file}")
        done < <(
            git -C "${ROOT}" \
                ls-files \
                --cached \
                --others \
                --exclude-standard \
                -z
        )
    else
        while IFS= read -r -d '' abs; do
            local rel="${abs#"${ROOT}/"}"
            should_include "${rel}" || continue
            files+=("${rel}")
        done < <(
            find "${ROOT}" \
                -type f \
                -not -path '*/.git/*' \
                -not -path '*/.chatgpt/*' \
                -print0
        )
    fi

    if (( ${#files[@]} > 0 )); then
        printf '%s\n' "${files[@]}" | LC_ALL=C sort >> "${tmp}"
    fi

    printf '```\n' >> "${tmp}"

    local total=0

    while IFS= read -r file; do
        [[ -n "${file}" ]] || continue

        local abs="${ROOT}/${file}"
        [[ -f "${abs}" ]] || continue

        local size
        size="$(file_size "${abs}")"

        if (( total + size > MAX_TOTAL_BYTES )); then
            {
                printf '\n\n# Context size limit reached\n\n'
                printf 'Remaining files were omitted after reaching %s bytes.\n' \
                    "${MAX_TOTAL_BYTES}"
            } >> "${tmp}"
            break
        fi

        append_file "${tmp}" "${file}"

        if (( size <= MAX_FILE_BYTES )); then
            total=$((total + size))
        fi
    done < <(
        if (( ${#files[@]} > 0 )); then
            printf '%s\n' "${files[@]}" | LC_ALL=C sort
        fi
    )

    mv "${tmp}" "${output}"

    printf 'Generated:\n%s\n' "${output}"
    printf 'Size: %s bytes\n' "$(file_size "${output}")"
}

generate_diff() {
    local output="${OUT_DIR}/project-diff.md"
    local tmp="${output}.tmp"

    if ! git -C "${ROOT}" rev-parse --git-dir >/dev/null 2>&1; then
        printf 'diff mode requires a Git repository.\n' >&2
        exit 1
    fi

    write_header "${tmp}"

    {
        printf '\n# Current Git status\n\n'
        printf '```text\n'
        git -C "${ROOT}" status --short || true
        printf '```\n'

        printf '\n# Changes since the attached full snapshot\n'
    } >> "${tmp}"

    declare -A changed=()

    while IFS= read -r -d '' file; do
        changed["${file}"]=1
    done < <(
        git -C "${ROOT}" diff --name-only -z
    )

    while IFS= read -r -d '' file; do
        changed["${file}"]=1
    done < <(
        git -C "${ROOT}" diff --cached --name-only -z
    )

    while IFS= read -r -d '' file; do
        changed["${file}"]=1
    done < <(
        git -C "${ROOT}" \
            ls-files \
            --others \
            --exclude-standard \
            -z
    )

    if (( ${#changed[@]} == 0 )); then
        printf '\nNo local changes.\n' >> "${tmp}"
        mv "${tmp}" "${output}"
        printf 'Generated:\n%s\n' "${output}"
        exit 0
    fi

    while IFS= read -r file; do
        [[ -n "${file}" ]] || continue
        should_include "${file}" || continue

        printf '\n\n## %s\n' "${file}" >> "${tmp}"

        if git -C "${ROOT}" ls-files --error-unmatch -- "${file}" \
            >/dev/null 2>&1; then

            printf '\n### Unstaged diff\n\n```diff\n' >> "${tmp}"
            git -C "${ROOT}" \
                --no-pager \
                diff \
                --no-ext-diff \
                -- "${file}" >> "${tmp}" || true
            printf '\n```\n' >> "${tmp}"

            printf '\n### Staged diff\n\n```diff\n' >> "${tmp}"
            git -C "${ROOT}" \
                --no-pager \
                diff \
                --cached \
                --no-ext-diff \
                -- "${file}" >> "${tmp}" || true
            printf '\n```\n' >> "${tmp}"
        else
            printf '\n### New untracked file\n' >> "${tmp}"
            append_file "${tmp}" "${file}"
        fi
    done < <(
        printf '%s\n' "${!changed[@]}" | LC_ALL=C sort
    )

    mv "${tmp}" "${output}"

    printf 'Generated:\n%s\n' "${output}"
    printf 'Size: %s bytes\n' "$(file_size "${output}")"
}

case "${MODE}" in
    full)
        generate_full
        ;;
    diff)
        generate_diff
        ;;
    *)
        printf 'Usage: %s [full|diff]\n' "$0" >&2
        exit 2
        ;;
esac
