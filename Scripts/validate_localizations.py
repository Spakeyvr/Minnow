#!/usr/bin/env python3
"""Check translation coverage, plural forms, and format arguments without Xcode.

The languages to check are read from `AppLanguage` in Minnow/AppLanguage.swift,
so adding a case there is enough to have its translations validated.

Run with `--self-test` to check the validator's own rules.
"""

from collections import Counter
import json
from pathlib import Path
import re
import sys

# Plural categories that may name their quantity in words ("Eine Minute" for
# "%lld minutes"), so their format arguments may be a subset of the key's.
WORDED_PLURAL_CATEGORIES = {"zero", "one"}


def units(node, plural_category=None):
    """Yields (plural category or None, stringUnit) for every unit under `node`."""
    if "stringUnit" in node:
        yield plural_category, node["stringUnit"]
    for name, value in node.items():
        if not isinstance(value, dict):
            continue
        if name == "plural":
            for category, variant in value.items():
                if isinstance(variant, dict):
                    yield from units(variant, category)
        else:
            yield from units(value, plural_category)


def placeholders(text):
    # Ignore positional argument numbers: translations may reorder arguments.
    return Counter(re.sub(r"^%\d+\$", "%", match) for match in re.findall(
        r"%(?:\d+\$)?(?:[-+ #0]*\d*(?:\.\d+)?(?:ll|l|h|z)?[diuoxXfFeEgGaAcCsSp@]|%)", text
    ))


def placeholders_match(value, key, plural_category):
    found = placeholders(value)
    expected = placeholders(key)
    if plural_category in WORDED_PLURAL_CATEGORIES:
        # Every argument used must exist in the key; dropping some is allowed.
        return not (found - expected)
    return found == expected


def app_languages(root):
    source = (root / "Minnow" / "AppLanguage.swift").read_text()
    enum = re.search(r"enum AppLanguage\b[^{]*\{(.*?)\n\}", source, re.S)
    if enum is None:
        raise SystemExit("Could not find `enum AppLanguage` in Minnow/AppLanguage.swift")
    languages = re.findall(r'^\s*case\s+\w+\s*=\s*"([^"]+)"', enum.group(1), re.M)
    if not languages:
        raise SystemExit("`enum AppLanguage` declares no languages")
    return languages


def validate_catalog(name, catalog, languages):
    errors = []
    count = 0
    for key, entry in catalog["strings"].items():
        if not entry.get("shouldTranslate", True):
            continue
        count += 1
        localizations = entry.get("localizations", {})
        for language in languages:
            translation = localizations.get(language, {})
            values = list(units(translation))
            if not values:
                errors.append(f"{name}: {language}: missing {key!r}")
            plural = translation.get("variations", {}).get("plural")
            if plural is not None and not {"one", "other"} <= plural.keys():
                errors.append(f"{name}: {language}: incomplete plurals for {key!r}")
            for plural_category, unit in values:
                if unit.get("state") != "translated" or not unit.get("value"):
                    errors.append(f"{name}: {language}: unfinished {key!r}")
                if not placeholders_match(unit.get("value", ""), key, plural_category):
                    form = f" ({plural_category} form)" if plural_category else ""
                    errors.append(f"{name}: {language}: mismatched placeholders{form} for {key!r}")
    return count, errors


def self_test():
    def entry(one, other):
        return {"localizations": {"de": {"variations": {"plural": {
            "one": {"stringUnit": {"state": "translated", "value": one}},
            "other": {"stringUnit": {"state": "translated", "value": other}},
        }}}}}

    catalog = {"strings": {
        "%lld minutes": entry("Eine Minute", "%lld Minuten"),
        "%lld hours": entry("%lld Stunde", "Stunden"),
        "%lld days": entry("%@ Tag", "%lld Tage"),
    }}
    _, errors = validate_catalog("Test.xcstrings", catalog, ["de"])
    expected = [
        "Test.xcstrings: de: mismatched placeholders (other form) for '%lld hours'",
        "Test.xcstrings: de: mismatched placeholders (one form) for '%lld days'",
    ]
    assert errors == expected, errors
    assert app_languages(Path(__file__).resolve().parents[1])[0] == "en"
    print("Self-test passed.")
    return 0


def main():
    if "--self-test" in sys.argv[1:]:
        return self_test()

    root = Path(__file__).resolve().parents[1]
    languages = app_languages(root)
    errors = []
    count = 0
    for path in sorted((root / "Minnow").glob("*.xcstrings")):
        catalog_count, catalog_errors = validate_catalog(path.name, json.loads(path.read_text()), languages)
        count += catalog_count
        errors += catalog_errors
    if errors:
        print("\n".join(errors), file=sys.stderr)
        return 1
    print(f"Validated {count} entries in {', '.join(languages)}.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
