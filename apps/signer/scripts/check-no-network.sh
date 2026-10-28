#!/bin/bash
# 检查 Signer 构建产物没有链接或导入任何网络 API。
#
# 用法：
#   check-no-network.sh                 # 构建 Release（generic iOS，不签名）后检查
#   check-no-network.sh Path/To/X.app   # 检查已有的 .app（或单个 Mach-O）
#   check-no-network.sh --self-test     # 用故意联网的小程序确认检查本身能报错
#
# 发现问题时以 1 退出；用法或构建错误以 2 退出。
# 只能看到**静态**引用：dlopen/dlsym 按名字取函数、ObjC 运行时按字符串取类绕得过去，
# 所以 dlopen 和这些字符串也一并检查（见 README 的"无网络检查"）。
set -euo pipefail
# 注意：命令替换 $(…) 里不继承 set -e（macOS 的 bash 3.2 也没有 inherit_errexit），
# 所以 build_release 里对构建失败做显式检查，并且先删掉旧产物。

here="$(cd "$(dirname "$0")" && pwd)"
signer_dir="$(dirname "$here")"

# 直接链接就算失败的库。
deny_libs='CFNetwork\.framework|/Network\.framework|NetworkExtension\.framework|libnetwork\.dylib|WebKit\.framework|SafariServices\.framework|MultipeerConnectivity\.framework|CoreBluetooth\.framework|CloudKit\.framework|GameKit\.framework|NearbyInteraction\.framework'

# 未定义符号（C / ObjC 原始名）。
deny_raw='^_nw_|^_(socket|socketpair|connect|bind|listen|accept|send|sendto|sendmsg|recv|recvfrom|recvmsg|getaddrinfo|getnameinfo|gethostbyname|gethostbyname2|gethostbyaddr|dlopen)$|^_DNSService|^_CFHTTP|^_CFHost|^_CFNetService|^_CFSocket|^_CFNetwork|^_CFStreamCreatePairWithSocket|^_CFReadStreamCreateWith(FTP)?URL|^_OBJC_CLASS_\$_NS(URLSession|URLConnection|URLDownload|URLRequest|MutableURLRequest|NetService|Stream|InputStream|OutputStream)'

# 未定义符号（Swift，demangle 之后）。Data / String(contentsOf: URL) 遇到 http URL 会联网。
deny_swift='URLSession|URLRequest|NSURLConnection|NWConnection|NWPathMonitor|NWListener|NWBrowser|init\(contentsOf: (__shared )?Foundation\.URL'

# 二进制里的字符串（NSClassFromString / dlsym 的参数）。
deny_strings='NSURLSession|NSURLConnection|nw_connection|nw_path|CFNetwork|Network\.framework|dataWithContentsOfURL|initWithContentsOfURL|stringWithContentsOfURL'

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

build_release() {
    command -v xcodegen >/dev/null || { echo "需要 xcodegen（brew install xcodegen）" >&2; exit 2; }
    local app="$signer_dir/build/DerivedData/Build/Products/Release-iphoneos/Signer.app"
    # 先删掉旧产物：构建失败时绝不能拿上一次的二进制来检查。
    rm -rf "$app"
    (cd "$signer_dir" && xcodegen generate --quiet)
    if ! xcodebuild -project "$signer_dir/Signer.xcodeproj" -scheme Signer -configuration Release \
        -destination 'generic/platform=iOS' -derivedDataPath "$signer_dir/build/DerivedData" \
        CODE_SIGNING_ALLOWED=NO -quiet build >&2; then
        echo "Release 构建失败，不检查" >&2
        exit 2
    fi
    [[ -d "$app" ]] || { echo "构建后找不到 $app" >&2; exit 2; }
    echo "$app"
}

macho_files() {
    if [[ -d "$1" ]]; then
        find "$1" -type f -print0 | while IFS= read -r -d '' f; do
            file -b "$f" | grep -q 'Mach-O' && echo "$f"
        done
    else
        echo "$1"
    fi
}

# 检查一个 Mach-O，问题打到 stdout。
scan() {
    local f="$1"
    otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -E "$deny_libs" | sed 's/^/  链接 /' || true
    local undef
    undef="$(nm -u "$f" 2>/dev/null || true)"
    grep -E "$deny_raw" <<<"$undef" | sed 's/^/  导入 /' || true
    grep -E '^_?\$s' <<<"$undef" | xcrun swift-demangle | grep -E "$deny_swift" | sed 's/^/  导入 /' || true
    strings -a "$f" | grep -E "$deny_strings" | sort -u | sed 's/^/  字符串 /' || true
}

check() {
    local target="$1" found=0 files
    files="$(macho_files "$target")"
    [[ -n "$files" ]] || { echo "没找到 Mach-O：$target" >&2; exit 2; }
    while IFS= read -r f; do
        local hits
        hits="$(scan "$f")"
        if [[ -n "$hits" ]]; then
            echo "✗ ${f#"$target"/}"
            echo "$hits"
            found=1
        else
            echo "✓ ${f#"$target"/}"
        fi
    done <<<"$files"
    return $found
}

self_test() {
    local tmp
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' RETURN
    cat >"$tmp/bad.swift" <<'EOF'
import Foundation
import Network
let t = URLSession.shared.dataTask(with: URL(string: "https://example.com")!)
t.resume()
let c = NWConnection(host: "example.com", port: 443, using: .tls)
_ = try? Data(contentsOf: URL(string: "https://example.com")!)
_ = socket(AF_INET, SOCK_STREAM, 0)
EOF
    cat >"$tmp/good.swift" <<'EOF'
import CryptoKit
import Foundation
print(SHA256.hash(data: Data("x".utf8)))
EOF
    xcrun swiftc -O "$tmp/bad.swift" -o "$tmp/bad" 2>/dev/null
    xcrun swiftc -O "$tmp/good.swift" -o "$tmp/good" 2>/dev/null
    local ok=1
    echo "== bad（应当失败）"
    if check "$tmp/bad"; then echo "self-test 失败：bad 没被拦下"; ok=0; fi
    echo "== good（应当通过）"
    if ! check "$tmp/good"; then echo "self-test 失败：good 被误报"; ok=0; fi
    [[ $ok == 1 ]] && echo "self-test 通过" || exit 1
}

case "${1:-}" in
    -h|--help) usage ;;
    --self-test) self_test; exit 0 ;;
    "") target="$(build_release)" ;;
    *) target="${1%/}" ;;
esac

echo "检查 $target"
if check "$target"; then
    echo "通过：没有网络相关的链接或导入"
else
    echo "失败：发现网络相关的链接或导入" >&2
    exit 1
fi
