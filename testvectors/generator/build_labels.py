#!/usr/bin/env python3
"""生成 core/Sources/UniPassCore/Resources/labels.json（内置标签库）。

- Safe 官方合约：safe-global/safe-deployments（MIT）固定 commit 的 src/assets/v1.3.0、v1.4.1、v1.5.0，
  取 networkAddresses 里链 1 / 8453 / 11155111 的地址（canonical 和 eip155 两份都收）。
- Permit2：Uniswap/permit2（MIT）test/utils/DeployPermit2.sol 的 PERMIT2_ADDRESS，所有链相同。
- 代币：tokens.json，每条带发行方官方文档的 URL 和原文摘录，拿不准的不收（2026-10-26 核对）。
  decimals：官方文档写明的照抄；没写的用合约自己的 decimals()（公共 RPC 在固定区块读取，来源字段里注明）。
  文档写明的也和链上值逐个核对过，全部一致；所有地址在核对时都有合约代码。

用法：python3 build_labels.py（需要联网下载 safe-deployments；只在开发机上跑）。
"""
import json, os, urllib.request

COMMIT = "8e200b0b4c72dbbfe371cbd61b3a21ae2ec4af62"
VERSIONS = ["v1.3.0", "v1.4.1", "v1.5.0"]
CHAINS = ["1", "8453", "11155111"]
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "core", "Sources", "UniPassCore", "Resources", "labels.json")

KIND = {
    "GnosisSafe": "safeSingleton", "GnosisSafeL2": "safeSingleton", "Safe": "safeSingleton", "SafeL2": "safeSingleton",
    "GnosisSafeProxyFactory": "safeProxyFactory", "SafeProxyFactory": "safeProxyFactory",
    "CompatibilityFallbackHandler": "safeFallbackHandler", "ExtensibleFallbackHandler": "safeFallbackHandler",
    "TokenCallbackHandler": "safeFallbackHandler",
}

def fetch(path):
    url = f"https://raw.githubusercontent.com/safe-global/safe-deployments/{COMMIT}/{path}"
    with urllib.request.urlopen(url) as r:
        return json.load(r)

def listing(version):
    url = f"https://api.github.com/repos/safe-global/safe-deployments/contents/src/assets/{version}?ref={COMMIT}"
    with urllib.request.urlopen(url) as r:
        return [x["name"] for x in json.load(r)]

entries = []
for v in VERSIONS:
    for f in sorted(listing(v)):
        d = fetch(f"src/assets/{v}/{f}")
        deps, na = d.get("deployments", {}), d.get("networkAddresses", {})
        for ch in CHAINS:
            e = na.get(ch)
            if e is None:
                continue
            for t in ([e] if isinstance(e, str) else e):
                addr = deps[t]["address"] if t in deps else t
                entries.append({
                    "chainId": int(ch), "address": addr, "kind": KIND.get(d["contractName"], "safeLibrary"),
                    "name": f"Safe {d['contractName']} {v[1:]}" + ("" if t == "canonical" else f" ({t})"),
                    "source": f"safe-deployments@{COMMIT[:7]} src/assets/{v}/{f} ({t})",
                })

for ch in CHAINS:
    entries.append({"chainId": int(ch), "address": "0x000000000022D473030F116dDEE9F6B43aC78BA3", "kind": "permit2",
                    "name": "Uniswap Permit2", "source": "Uniswap/permit2 test/utils/DeployPermit2.sol PERMIT2_ADDRESS"})

for t in json.load(open(os.path.join(HERE, "tokens.json"))):
    entries.append({k: t[k] for k in ["chainId", "address", "kind", "name", "symbol", "decimals", "source"] if k in t})

seen = {}
for e in entries:
    k = (e["chainId"], e["address"].lower())
    assert k not in seen, f"duplicate {k}: {seen[k]['name']} / {e['name']}"
    seen[k] = e
entries.sort(key=lambda e: (e["chainId"], e["kind"], e["name"]))
json.dump({"version": 1, "entries": entries}, open(OUT, "w"), indent=1, ensure_ascii=False)
print(f"wrote {len(entries)} entries to {os.path.relpath(OUT)}")
