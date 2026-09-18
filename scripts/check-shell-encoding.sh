#!/usr/bin/env bash
#
# 静态检查：shell 里有没有"变量后面紧跟非 ASCII 字符"的写法。
#
# 为什么需要这个检查：
#   把变量写在双引号字符串里、后面**直接跟**一个中文标点时（例如变量名之后紧跟
#   一个全角右括号），在 **UTF-8 区域**下 bash 会把那个多字节标点吞进变量名，
#   于是去找一个"名字里带全角括号"的变量；配合 `set -u` 就是一句
#   `ARCHS<乱码>: unbound variable` 直接中止脚本。
#   而本机 shell 默认没有 LANG/LC_*（C 区域）时**完全正常** —— 于是这类错
#   只在 CI 上炸，本地无论跑多少遍都复现不出来（真实踩过：run 35325919692）。
#
# 用法：
#   scripts/check-shell-encoding.sh
#   命中 → 列出 `文件:行号` 并退出 1；干净 → 退出 0。
#
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# 用法：不带参数 = 扫全仓库（scripts/ 与 .github/workflows/）；
#       带参数 = 只扫给定文件（便于做"阳性对照"：拿一个故意写错的样本验证这个检查真的能抓到）。
if [ "$#" -gt 0 ]; then
    FILES="$*"
else
    # 只扫真正会被 bash 解析的内容：shell 脚本，以及 workflow 里的 run: 块。
    FILES=$( { find scripts -type f -name '*.sh'; find .github/workflows -type f \( -name '*.yml' -o -name '*.yaml' \); } 2>/dev/null | sort -u )
fi
if [ -z "$FILES" ]; then
    echo "没有找到待检查的文件"
    exit 0
fi

# 用 C 区域让 grep 逐字节比较：`[^ -~]` 就是"非可打印 ASCII 字符"。
# GitHub 的表达式 ${{ ... }} 不会被误报（$ 后面是 { 而不是字母），因为它在交给 bash 之前
# 就已经被替换掉了。
HITS=$(LC_ALL=C grep -nE '\$[A-Za-z_][A-Za-z0-9_]*[^ -~]' $FILES 2>/dev/null || true)

if [ -n "$HITS" ]; then
    echo "❌ 发现「变量紧贴非 ASCII 字符」的写法（UTF-8 区域下会被当成变量名的一部分）："
    printf '%s\n' "$HITS" | sed 's/^/    /'
    echo
    echo '修法：改成花括号 ${VAR}，或把变量挪到句尾。参见 scripts/build-release.sh 文件头的说明。'
    exit 1
fi

echo "✅ 未发现「变量紧贴非 ASCII」的写法（已检查 $(printf '%s\n' $FILES | wc -l | tr -d ' ') 个文件）"
