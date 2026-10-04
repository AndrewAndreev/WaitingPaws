#!/usr/bin/env python3
"""Builds App/Resources/Localizable.xcstrings from what the compiler extracted and the English translations.

The UI is written in Russian and the Russian texts are the keys. English is the base language (every device
language other than Russian), so each key gets an explicit English value from Tools/strings/en.json and its
Russian value is the key itself.

  1. Build both apps with SWIFT_EMIT_LOC_STRINGS=YES (the project's default), e.g.
       xcodebuild -scheme WaitingPaws-iOS   -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/wp-dd build
       xcodebuild -scheme WaitingPaws-macOS -destination 'generic/platform=macOS'         -derivedDataPath /tmp/wp-dd build
  2. Tools/strings/build_catalog.py /tmp/wp-dd            → writes the catalog, lists keys without English
     Tools/strings/build_catalog.py /tmp/wp-dd --missing  → only prints the untranslated keys as JSON (with sources)
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CATALOG = os.path.join(ROOT, "App/Resources/Localizable.xcstrings")
TRANSLATIONS = os.path.join(ROOT, "Tools/strings/en.json")
CYRILLIC = re.compile(r"[А-Яа-яЁё]")
SPECIFIER = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|lf|f|llu|lu|u|%)")


def extracted(derived_data):
    """key → sorted list of "File.swift:line" where the app's code uses it (table Localizable)."""
    keys = {}
    pattern = os.path.join(derived_data, "Build/Intermediates.noindex/WaitingPaws.build/**/*.stringsdata")
    for path in glob.glob(pattern, recursive=True):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        source = os.path.basename(data.get("source", path))
        for entry in data.get("tables", {}).get("Localizable", []):
            line = entry.get("location", {}).get("startingLine", 0)
            keys.setdefault(entry["key"], set()).add(f"{source}:{line}")
    return {k: sorted(v) for k, v in keys.items()}


def check_specifiers(key, value):
    """The English value must use the same placeholders (possibly reordered with %n$)."""
    def kinds(text):
        return sorted(re.sub(r"\d+\$", "", s) for s in SPECIFIER.findall(text) if s != "%%")
    return kinds(key) == kinds(value)


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    keys = extracted(sys.argv[1])
    translations = json.load(open(TRANSLATIONS, encoding="utf-8")) if os.path.exists(TRANSLATIONS) else {}
    # Partial files (Tools/strings/en-*.json) are merged in; en.json wins on conflicts.
    for path in sorted(glob.glob(os.path.join(ROOT, "Tools/strings/en-*.json"))):
        for k, v in json.load(open(path, encoding="utf-8")).items():
            translations.setdefault(k, v)

    missing = {k: v for k, v in keys.items() if CYRILLIC.search(k) and k not in translations}
    if "--missing" in sys.argv:
        print(json.dumps(missing, ensure_ascii=False, indent=1, sort_keys=True))
        return

    strings = {}
    problems = []
    for key in sorted(keys):
        if not CYRILLIC.search(key):
            # "%@", "SD", "go2rtc %@"…: the same in every language.
            strings[key] = {"shouldTranslate": False}
            continue
        english = translations.get(key)
        item = {"localizations": {"ru": {"stringUnit": {"state": "translated", "value": key}}}}
        if isinstance(english, dict):
            # {"one": "%lld exit", "other": "%lld exits"}: English plural forms (keys with one number only).
            for form, text in english.items():
                if not check_specifiers(key, text):
                    problems.append(f"placeholders differ: {key!r} → {text!r}")
            item["localizations"]["en"] = {"variations": {"plural": {
                form: {"stringUnit": {"state": "translated", "value": text}} for form, text in english.items()}}}
        elif english is not None:
            if not check_specifiers(key, english):
                problems.append(f"placeholders differ: {key!r} → {english!r}")
            item["localizations"]["en"] = {"stringUnit": {"state": "translated", "value": english}}
        strings[key] = item

    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    with open(CATALOG, "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")

    unused = sorted(set(translations) - set(keys))
    print(f"{len(keys)} keys, {len(missing)} without English, {len(unused)} translations no longer used")
    for p in problems:
        print("  !", p)
    for k in sorted(missing)[:40]:
        print("  missing:", k, "—", ", ".join(missing[k][:2]))


if __name__ == "__main__":
    main()
