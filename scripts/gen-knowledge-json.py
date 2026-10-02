#!/usr/bin/env python3
"""Render the knowledge base into the app's bundled knowledge.json.

Reads every article in knowledge-base/**/*.yaml (schema.yaml excluded) and
writes PulsHealth/Sources/Resources/knowledge.json: one JSON object keyed by
HealthKit identifier, each value a trimmed article with a fixed shape so the
app can decode it with Foundation alone (the app has no YAML parser and no
third-party code — the privacy documents promise the latter).

The output is generated: never edit it by hand. Regenerate after any change
under knowledge-base/; scripts/check-knowledge-json.sh (CI, `validate` job)
fails until the checked-in file matches. Output is deterministic: sorted
keys, 2-space indent, trailing newline, byte-identical on rerun.

Fields kept per article — only what the app's Type page shows (the one-line
description, the canonical unit, the typical range drawn under the value
histogram, and the names of a category type's values); the rest of each
article stays on the site:

  identifier, human_readable_name, short_description, default_unit
                  — string or null
  typical_range   — {min, max, unit, notes} or null. min/max are numbers (or
                    null), unit and notes strings (or null). Three articles
                    use other keys there (systolic/diastolic, frequency/
                    duration_seconds); those are folded into `notes` as
                    "key: value" lines so nothing is lost and the shape holds.
  category_values — list of {value, name, description}, kept as written;
                    null when absent.

Usage: scripts/gen-knowledge-json.py [--output PATH]
  Prints a one-line summary (articles, bytes) to stderr on success.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    print("gen-knowledge-json: PyYAML not installed. Run: pip install pyyaml", file=sys.stderr)
    sys.exit(1)

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "knowledge-base"
DEFAULT_OUTPUT = ROOT / "PulsHealth" / "Sources" / "Resources" / "knowledge.json"

STRING_FIELDS = (
    "identifier",
    "human_readable_name",
    "short_description",
    "default_unit",
)


def text(value) -> str | None:
    """A string field: None stays None, anything else is stringified and trimmed."""
    if value is None:
        return None
    return str(value).strip()


def number(value):
    """A numeric field: ints and floats pass, anything else becomes None."""
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return value
    return None


def typical_range(value):
    if not isinstance(value, dict):
        return None
    notes = [text(value.get("notes"))] if value.get("notes") else []
    for key in sorted(value):
        if key in ("min", "max", "unit", "notes"):
            continue
        notes.append(f"{key}: {value[key]}")
    return {
        "min": number(value.get("min")),
        "max": number(value.get("max")),
        "unit": text(value.get("unit")),
        "notes": "\n".join(notes) if notes else None,
    }


def article(data: dict) -> dict:
    out = {field: text(data.get(field)) for field in STRING_FIELDS}
    out["typical_range"] = typical_range(data.get("typical_range"))
    out["category_values"] = data.get("category_values") or None
    return out


def load_articles() -> dict[str, dict]:
    articles: dict[str, dict] = {}
    files = sorted(p for p in SOURCE.rglob("*.yaml") if p.name != "schema.yaml")
    if not files:
        sys.exit(f"gen-knowledge-json: no YAML files under {SOURCE}")
    for path in files:
        with path.open() as f:
            data = yaml.safe_load(f)
        if not isinstance(data, dict) or not data.get("identifier"):
            sys.exit(f"gen-knowledge-json: {path.relative_to(ROOT)} has no identifier")
        identifier = str(data["identifier"]).strip()
        if identifier in articles:
            sys.exit(f"gen-knowledge-json: duplicate identifier {identifier} in {path.relative_to(ROOT)}")
        articles[identifier] = article(data)
    return articles


def render(articles: dict[str, dict]) -> str:
    return json.dumps(articles, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT, help=f"where to write (default: {DEFAULT_OUTPUT.relative_to(ROOT)})")
    args = parser.parse_args()

    articles = load_articles()
    rendered = render(articles)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(rendered, encoding="utf-8")
    print(f"gen-knowledge-json: {len(articles)} articles, {len(rendered.encode('utf-8'))} bytes -> {args.output}", file=sys.stderr)


if __name__ == "__main__":
    main()
