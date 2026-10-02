#!/usr/bin/env bash
# Public-tree gate for the PulsHealth repository.
#
# Fails when any tracked file carries owner-specific or private-infrastructure
# content: tailnet hostnames, personal mailboxes, home directories, an Apple
# Developer Team ID, host-name gates, the retired private deploy tooling, or
# the bare production host name in prose, config, and code files.
#
# Every pattern is a CLASS of identifier, never a literal personal value, so
# this script is itself safe to publish. When a scrub finds a new kind of
# leak, add the class here; never add the leaked value.
#
# Usage: scripts/check-public-tree.sh
#   Scans `git ls-files` (this script excluded). Prints one `path:line:text`
#   per hit and exits 1; exits 0 on a clean tree. Runs in the `public-tree`
#   job of .github/workflows/ci.yml.

set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

self='scripts/check-public-tree.sh'

# Identifier classes checked in every tracked text file (case-insensitive).
patterns=(
  '[a-z0-9-]+\.[a-z0-9-]+\.ts\.net'   # a concrete tailnet FQDN (placeholders like <tailnet>.ts.net pass)
  '@gmail\.com'                       # personal mailboxes
  '/home/[a-z]'                       # a home directory on someone's host
  'DEVELOPMENT_TEAM *= *[A-Z0-9]{10}' # an Apple Developer Team ID
  'hostname -s'                       # host-name gates in scripts
  'superpowers'                       # private planning artifacts
  'Shipyard'                          # a private deploy platform
  'deploy-grey'                       # the retired production deploy workflow
  'Graffit'                           # a private downstream consumer
)

# The production host's bare name, matched as a whole word, but only in prose,
# config, and code files: the same word is a colour in CSS/TSX and fine there.
host_word='grey'
host_word_files='\.(md|yml|yaml|sh|go|sql)$'

# Lines that match a class above but are dictated by a third party.
allow=(
  '/home/postgres/pgdata' # PGDATA inside the timescaledb-ha image
  'you@gmail.com'         # placeholder next to the Gmail SMTP example in .env.example
  'sagepub.com/home/'     # a journal's own URL, cited by a knowledge-base entry
)

# NUL-separated list of every tracked file except this script.
tracked() {
  git ls-files -z | grep -zvxF -- "$self" || true
}

# scan <grep options...>: grep the NUL-separated file list on stdin.
# -I skips binaries; /dev/null guarantees a file operand so grep never reads
# stdin; xargs -r skips the run entirely when the list is empty.
scan() {
  xargs -0 -r grep -nHI "$@" -- /dev/null 2>/dev/null || true
}

hits=$(
  {
    args=()
    for pattern in "${patterns[@]}"; do
      args+=(-e "$pattern")
    done
    tracked | scan -iE "${args[@]}"

    tracked | grep -zE -- "$host_word_files" | scan -iw -e "$host_word"
  } | sort -u
)

if [[ -n $hits ]]; then
  args=()
  for entry in "${allow[@]}"; do
    args+=(-e "$entry")
  done
  hits=$(printf '%s\n' "$hits" | grep -vF "${args[@]}" || true)
fi

if [[ -z $hits ]]; then
  echo "public-tree: clean ($(git ls-files | wc -l | tr -d ' ') tracked files scanned)"
  exit 0
fi

{
  echo "public-tree: private content found in tracked files:"
  printf '%s\n' "$hits"
  echo
  echo "public-tree: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') hit(s)." \
    "Scrub or relocate the content; the classes are listed at the top of $self."
} >&2
exit 1
