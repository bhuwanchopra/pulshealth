#!/usr/bin/env bash
# Checks that the app's bundled knowledge base is up to date.
#
# PulsHealth/Sources/Resources/knowledge.json is generated from
# knowledge-base/**/*.yaml by scripts/gen-knowledge-json.py and checked in,
# so the app build needs no YAML parser. This script regenerates it to a
# temporary file and diffs; a difference means someone edited the YAML (or
# the generator) without rerunning it — or edited the JSON by hand.
#
# Usage: scripts/check-knowledge-json.sh
#   Exits 0 when the checked-in file matches, 1 with a diff otherwise.
#   Needs python3 with PyYAML (pip install pyyaml). Runs in the `validate`
#   job of .github/workflows/ci.yml.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

generator='scripts/gen-knowledge-json.py'
checked_in='PulsHealth/Sources/Resources/knowledge.json'

tmp=$(mktemp -t knowledge-json.XXXXXX)
trap 'rm -f "$tmp"' EXIT

python3 "$generator" --output "$tmp"

if [[ ! -f $checked_in ]]; then
  echo "check-knowledge-json: $checked_in is missing; run $generator" >&2
  exit 1
fi

if diff -u "$checked_in" "$tmp" >&2; then
  echo "check-knowledge-json: $checked_in is up to date"
  exit 0
fi

echo >&2
echo "check-knowledge-json: $checked_in is out of date: run $generator and commit the result" >&2
exit 1
