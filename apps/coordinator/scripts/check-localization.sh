#!/bin/bash
# 构建 App（Debug，包含 DEBUG 页面的文字），再核对 Localizable.xcstrings 的中英双语。
# 用法：apps/coordinator/scripts/check-localization.sh [--no-build]
set -euo pipefail
cd "$(dirname "$0")/.."
# 单独的 DerivedData：不签名的构建不能覆盖平时运行的那份（被覆盖后 App 读不到自己的沙盒和钥匙串，看起来像没配对）。
DERIVED=build/DerivedData-loccheck
if [[ "${1:-}" != "--no-build" ]]; then
  xcodegen generate -q
  if ! xcodebuild -project UniPassCoordinator.xcodeproj -scheme UniPassCoordinator -configuration Debug \
       -derivedDataPath "$DERIVED" CODE_SIGNING_ALLOWED=NO build >"${TMPDIR:-/tmp}/unipass-coordinator-loc-build.log" 2>&1; then
    tail -30 "${TMPDIR:-/tmp}/unipass-coordinator-loc-build.log"
    echo "构建失败" >&2
    exit 2
  fi
fi
python3 -I scripts/check_localization.py "$DERIVED"
