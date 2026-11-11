#!/usr/bin/env python3
"""Builds App/Resources/Localizable.xcstrings from what the compiler extracted and the Russian translations.

The UI is written in English and the English texts are the keys. English is the base language (every device
language other than Russian), so a key needs no English value; its Russian value comes from Tools/strings/ru.json.

  * A key the Russian UI shows as is ("REC", "go2rtc %@") maps to itself in ru.json and is marked
    shouldTranslate: false. Keys without letters ("%@", "—") need no entry.
  * When one English text needs a second Russian text, the second key gets a context after "|":
    `Button("Cancel|verb")`, ru.json "Cancel|verb": "Отменить". The catalog gives it the English value "Cancel".

  1. Build both apps with SWIFT_EMIT_LOC_STRINGS=YES (the project's default), e.g.
       xcodebuild -scheme WaitingPaws-iOS   -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/wp-dd build
       xcodebuild -scheme WaitingPaws-macOS-Direct -destination 'generic/platform=macOS'  -derivedDataPath /tmp/wp-dd build
     (the Direct Mac target: the same sources plus the updates under `#if WP_DIRECT`; keys no build uses are dropped)
  2. Tools/strings/build_catalog.py /tmp/wp-dd            → writes the catalog, lists keys without Russian
     Tools/strings/build_catalog.py /tmp/wp-dd --missing  → only prints the untranslated keys as JSON (with sources)
"""
import glob
import json
import os
import re
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(ROOT, "App/Resources/Localizable.xcstrings")
TRANSLATIONS = os.path.join(ROOT, "Tools/strings/ru.json")
SPECIFIER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|(?:\.\d+)?l?f|llu|lu|u|%)")
CONTEXT = "|"


def stringsdata(derived_data):
    pattern = os.path.join(derived_data, "Build/Intermediates.noindex/WaitingPaws.build/**/*.stringsdata")
    return sorted(glob.glob(pattern, recursive=True))


def extracted(derived_data):
    """key → sorted list of "File.swift:line" where the app's code uses it (table Localizable)."""
    keys = {}
    for path in stringsdata(derived_data):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        source = os.path.basename(data.get("source", path))
        for entry in data.get("tables", {}).get("Localizable", []):
            line = entry.get("location", {}).get("startingLine", 0)
            keys.setdefault(entry["key"], set()).add(f"{source}:{line}")
    return {k: sorted(v) for k, v in keys.items()}


def has_letters(key):
    return any(ch.isalpha() for ch in SPECIFIER.sub("", key))


def english(key):
    """The English text of a key: the key itself, without a context ("Cancel|verb" → "Cancel")."""
    return key.split(CONTEXT, 1)[0]


def sort_nested(value):
    if isinstance(value, dict):
        return {k: sort_nested(value[k]) for k in sorted(value)}
    return value


def xcode_order(keys):
    """The order Xcode writes catalog keys in (Foundation's localizedStandardCompare)."""
    script = ("import Foundation\n"
              "let keys = try! JSONDecoder().decode([String].self, from: FileHandle.standardInput.readDataToEndOfFile())\n"
              "let sorted = keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending }\n"
              "FileHandle.standardOutput.write(try! JSONEncoder().encode(sorted))\n")
    with tempfile.NamedTemporaryFile("w", suffix=".swift", delete=False) as f:
        f.write(script)
    try:
        result = subprocess.run(["swift", f.name], input=json.dumps(keys).encode(), capture_output=True, check=True)
    finally:
        os.unlink(f.name)
    return json.loads(result.stdout)


def check_specifiers(key, value):
    """The Russian value must use the same placeholders (possibly reordered with %n$)."""
    def kinds(text):
        return sorted(re.sub(r"\d+\$", "", s) for s in SPECIFIER.findall(text) if s != "%%")
    return kinds(key) == kinds(value)


def unit(text):
    return {"stringUnit": {"state": "translated", "value": text}}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    keys = extracted(sys.argv[1])
    translations = json.load(open(TRANSLATIONS, encoding="utf-8")) if os.path.exists(TRANSLATIONS) else {}
    # Partial files (Tools/strings/ru-*.json) are merged in; ru.json wins on conflicts.
    for path in sorted(glob.glob(os.path.join(ROOT, "Tools/strings/ru-*.json"))):
        for k, v in json.load(open(path, encoding="utf-8")).items():
            translations.setdefault(k, v)

    missing = {k: v for k, v in keys.items() if has_letters(k) and k not in translations}
    if "--missing" in sys.argv:
        print(json.dumps(missing, ensure_ascii=False, indent=1, sort_keys=True))
        return

    strings = {}
    problems = []
    for key in sorted(keys):
        russian = translations.get(key)
        if russian is None:
            # "%@", "—": the same in every language; a key with letters but no Russian is listed as missing.
            strings[key] = {"shouldTranslate": False} if not has_letters(key) else {}
            continue
        if russian == key:
            # "REC", "go2rtc %@": the Russian UI shows the English text.
            strings[key] = {"shouldTranslate": False}
            continue
        if not check_specifiers(key, russian):
            problems.append(f"placeholders differ: {key!r} → {russian!r}")
        localizations = {"ru": unit(russian)}
        if CONTEXT in key:
            localizations["en"] = unit(english(key))
        strings[key] = {"localizations": localizations}

    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    # Xcode's own layout (keys in localizedStandardCompare order, "key" : value, no final newline), so saving the
    # catalog in Xcode or its build-time sync changes nothing.
    catalog["strings"] = {key: sort_nested(strings[key]) for key in xcode_order(list(strings))}
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, separators=(",", " : "))

    unused = sorted(set(translations) - set(keys))
    print(f"{len(keys)} keys, {len(missing)} without Russian, {len(unused)} translations the Swift apps don't use "
          f"(the Windows app may)")
    for p in problems:
        print("  !", p)
    for k in sorted(missing)[:40]:
        print("  missing:", k, "—", ", ".join(missing[k][:2]))


if __name__ == "__main__":
    main()
