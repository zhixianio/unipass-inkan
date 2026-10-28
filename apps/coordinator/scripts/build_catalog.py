"""用 scripts/zh-Hans*.json 生成各个字符串表的 .xcstrings（en 取 key 原文，两种语言都写明 translated）。
key 的集合以 localization_keys.py 抽出的为准；新增 / 改动界面文字后先构建，再补译文、跑这个脚本。"""
import json, os, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(root, "scripts"))
import localization_keys as lk

tables, _ = lk.all_tables(root, os.path.join(root, "build/DerivedData"))
def unit(v):
    return {"stringUnit": {"state": "translated", "value": v}}
for table, (catalog, source) in lk.TABLES.items():
    keys = tables[table]
    zh = json.load(open(os.path.join(root, source)))
    missing = sorted(k for k in keys if k not in zh)
    if missing:
        sys.exit(f"{source} 缺少：\n" + "\n".join(missing))
    strings = {k: {"localizations": {"en": unit(k), "zh-Hans": unit(zh[k])}} for k in sorted(keys)}
    with open(os.path.join(root, catalog), "w") as f:
        json.dump({"sourceLanguage": "en", "strings": strings, "version": "1.0"}, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"{table}: {len(strings)} keys")
