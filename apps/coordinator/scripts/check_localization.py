"""核对界面文字的中英双语。
- 代码里用到的每个 key（编译器抽取 + CoordinatorFlow 的 LocalizedStringResource）都在 Localizable.xcstrings 里；
- 每个 key 的 en 和 zh-Hans 都是非空的 translated；
- 两种语言的占位符（%@、%lld …）个数和类型一致（允许 %1$@ 这种带位置的写法）；
- 每个字符串表（localization_keys.TABLES）分开核对；目录里没有代码不用的 key；InfoPlist.xcstrings 里 App 名称和相机说明两种语言都有。"""
import json, os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(root, "scripts"))
import localization_keys as lk

LANGS = ("en", "zh-Hans")
SPEC = re.compile(r"%(?:(\d+)\$)?([-+ 0#]*\d*(?:\.\d+)?)(lld|ld|d|@|lf|f|%)")

def specs(s):
    found = [(int(p) if p else None, t) for p, _, t in SPEC.findall(s) if t != "%"]
    if any(p is not None for p, _ in found):
        return sorted(t for _, t in sorted(found, key=lambda x: x[0] or 0))
    return sorted(t for _, t in found)

def check_catalog(path, required, allow_extra=False):
    errors = []
    strings = json.load(open(path))["strings"]
    for key, where in sorted(required.items()):
        entry = strings.get(key)
        if entry is None:
            errors.append(f"缺少 key（{where}）：{key!r}")
            continue
        values = {}
        for lang in LANGS:
            unit = entry.get("localizations", {}).get(lang, {}).get("stringUnit", {})
            v = unit.get("value", "")
            if unit.get("state") != "translated" or not v.strip():
                errors.append(f"{lang} 没有译文：{key!r}")
            values[lang] = v
        if values["en"] and values["zh-Hans"] and specs(values["en"]) != specs(values["zh-Hans"]):
            errors.append(f"占位符不一致：{key!r} en={values['en']!r} zh-Hans={values['zh-Hans']!r}")
        if specs(key) != specs(values["en"]):
            errors.append(f"en 和 key 的占位符不一致：{key!r}")
    if not allow_extra:
        for key in sorted(set(strings) - set(required)):
            errors.append(f"目录里多余的 key（代码没用）：{key!r}")
    return errors

def main(derived):
    tables, files = lk.all_tables(root, derived)
    if files == 0:
        sys.exit(f"没找到 *.stringsdata：先构建 App（SWIFT_EMIT_LOC_STRINGS=YES），DerivedData = {derived}")
    errors = []
    for table, (catalog, _) in lk.TABLES.items():
        errors += [f"[{table}] {e}" for e in check_catalog(os.path.join(root, catalog), tables[table])]
    info = {k: "Info.plist" for k in ("CFBundleDisplayName", "CFBundleName", "NSCameraUsageDescription")}
    errors += check_catalog(os.path.join(root, "Coordinator/InfoPlist.xcstrings"), info, allow_extra=True)
    if errors:
        print("\n".join(errors))
        sys.exit(1)
    print("OK：" + "，".join(f"{t} {len(k)} 个 key" for t, k in tables.items()) + "；en / zh-Hans 齐全，占位符一致")

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else os.path.join(root, "build/DerivedData"))
