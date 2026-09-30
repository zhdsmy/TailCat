#!/bin/bash
# Prints the GitHub release body for <version>: its CHANGELOG.md section plus install notes.
# Fails if CHANGELOG.md has no `## [<version>]` section, so a release cannot ship without notes.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: scripts/release-notes.sh <version>}"
# The section ends at the next version heading or at the link definitions closing the file.
SECTION="$(awk -v v="$VERSION" '
  index($0, "## [" v "]") == 1 { found = 1; next }
  found && (/^## \[/ || /^\[[^]]+\]: /) { exit }
  found && (started || NF) { started = 1; print }
' CHANGELOG.md)"
if [[ -z "${SECTION//[[:space:]]/}" ]]; then
  echo "CHANGELOG.md has no entries for $VERSION" >&2
  exit 1
fi

printf '%s\n' "$SECTION"
cat <<EOF

## 安装

1. 先安装 tailcat：\`brew install tailcat\`
2. 下载 \`TailCat-$VERSION.dmg\`，打开后把 TailCat 拖进“应用程序”。
3. App 只做了 ad-hoc 签名、没有经过 Apple 公证，首次打开会被拦下：到“系统设置 › 隐私与安全性”点“仍要打开”，或在终端执行
   \`xattr -dr com.apple.quarantine /Applications/TailCat.app\`

校验下载：\`shasum -a 256 -c TailCat-$VERSION.dmg.sha256\`
EOF
