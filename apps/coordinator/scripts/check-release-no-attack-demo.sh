#!/bin/bash
# 攻击演示只能存在于 DEBUG 构建（docs/demo.md）。这个脚本构建 Release，确认里面没有攻击演示的代码和文字：
#   1. 可执行文件的符号（不含调试 stab）和字符串里没有 AttackDemo、没有演示用的攻击地址；
#   2. App 包里没有 AttackDemo.strings，也没有攻击演示的界面文字；
# 并用 Debug 构建做对照：同样的检查在 Debug 里必须能找到它们（证明检查本身有效）。
# 用法：apps/coordinator/scripts/check-release-no-attack-demo.sh
set -euo pipefail
cd "$(dirname "$0")/.."
LOG="${TMPDIR:-/tmp}/unipass-coordinator-release-check.log"
NEEDLES=(AttackDemo attackDemo 96221423681A6d52E184D440a8eFCEbB105C7242 bDd077f651EBe7f7b3cE16fe5F2b025BE2969516 "ATTACK DEMO" "攻击演示")

build() { # $1 = 配置, $2 = DerivedData
  rm -rf "$2/Build/Products/$1"
  if ! xcodebuild -project UniPassCoordinator.xcodeproj -scheme UniPassCoordinator -configuration "$1" \
       -derivedDataPath "$2" CODE_SIGNING_ALLOWED=NO build >"$LOG" 2>&1; then
    tail -30 "$LOG"; echo "$1 构建失败" >&2; exit 2
  fi
}

# 在 App 包里找：Mach-O 的符号表和字符串、资源文件的内容。
hits() { # $1 = .app
  local app="$1" found=()
  while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q "Mach-O"; then
      # nm 不带 -a：不看调试用的 stab 条目（Release 里 AttackDemo.swift 编译成空目标文件，stab 里只剩文件名）。
      local text; text="$(nm "$f" 2>/dev/null; strings -a "$f")"
    else
      local text; text="$(cat "$f" 2>/dev/null; plutil -p "$f" 2>/dev/null || true)"
    fi
    for n in "${NEEDLES[@]}"; do
      if grep -qF -- "$n" <<<"$text"; then found+=("$(basename "$f"): $n"); fi
    done
  done < <(find "$app" -type f -print0)
  [[ -e "$app/Contents/Resources/en.lproj/AttackDemo.strings" ]] && found+=("en.lproj/AttackDemo.strings")
  printf '%s\n' "${found[@]+"${found[@]}"}"
}

xcodegen generate -q
build Release build/DerivedData-release
build Debug build/DerivedData-debugcheck
RELEASE="build/DerivedData-release/Build/Products/Release/UniPass Inkan Desktop.app"
DEBUG="build/DerivedData-debugcheck/Build/Products/Debug/UniPass Inkan Desktop.app"

debug_hits="$(hits "$DEBUG")"
if [[ -z "$debug_hits" ]]; then
  echo "对照失败：Debug 构建里也没找到攻击演示，检查本身可能失效了" >&2; exit 3
fi
release_hits="$(hits "$RELEASE")"
if [[ -n "$release_hits" ]]; then
  echo "Release 构建里有攻击演示的痕迹：" >&2; echo "$release_hits" >&2; exit 1
fi
echo "OK：Release 里没有攻击演示（Debug 对照找到 $(wc -l <<<"$debug_hits" | tr -d ' ') 处）"
