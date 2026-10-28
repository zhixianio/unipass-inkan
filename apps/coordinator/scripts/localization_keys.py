"""列出 App 用到的全部本地化 key（按字符串表分组）：编译器从 App 源码抽出的（*.stringsdata）
+ CoordinatorFlow 里的 LocalizedStringResource 字面量（Swift package 不参与 App 的抽取，所以按源码找）。

字符串表：
- Localizable → Coordinator/Localizable.xcstrings，译文源 scripts/zh-Hans.json
- AttackDemo  → Coordinator/AttackDemo.xcstrings，译文源 scripts/zh-Hans-attack-demo.json（只在 DEBUG 构建里用，Release 不带）"""
import glob, json, os, re, sys

TABLES = {
    "Localizable": ("Coordinator/Localizable.xcstrings", "scripts/zh-Hans.json"),
    "AttackDemo": ("Coordinator/AttackDemo.xcstrings", "scripts/zh-Hans-attack-demo.json"),
}

def app_tables(derived_data):
    objs = glob.glob(os.path.join(derived_data, "Build/Intermediates.noindex/UniPassCoordinator.build/*/UniPassCoordinator.build/Objects-normal/*/*.stringsdata"))
    tables = {t: {} for t in TABLES}
    for f in objs:
        d = json.load(open(f))
        for table, entries in d.get("tables", {}).items():
            if table not in tables:
                sys.exit(f"未知的字符串表 {table}（{d['source']}）：在 localization_keys.TABLES 里登记")
            for e in entries:
                tables[table].setdefault(e["key"], f"{os.path.basename(d['source'])}:{e['location']['startingLine']}")
    return tables, len(objs)

def flow_keys(root):
    keys = {}
    for f in glob.glob(os.path.join(root, "Packages/CoordinatorKit/Sources/CoordinatorFlow/*.swift")):
        src = open(f).read()
        for m in re.finditer(r'LocalizedStringResource\(\s*"((?:[^"\\]|\\.)*)"', src):
            keys.setdefault(m.group(1).replace('\\"', '"'), os.path.basename(f))
    return keys

def all_tables(root, derived_data):
    tables, n = app_tables(derived_data)
    tables["Localizable"].update(flow_keys(root))
    return tables, n

if __name__ == "__main__":
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    t, _ = all_tables(root, sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "build/DerivedData"))
    json.dump(t, sys.stdout, ensure_ascii=False, indent=1, sort_keys=True)
