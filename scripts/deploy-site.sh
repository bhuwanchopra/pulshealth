#!/usr/bin/env bash
# Deploy the pulshealth.com marketing site (site/) to S3 + CloudFront.
#
#   scripts/deploy-site.sh [--skip-build] [--no-invalidation] [--dry-run]
#
# It builds the static export (`bun run build` in site/, which writes
# site/out/), syncs it to the S3 bucket behind pulshealth.com with --delete,
# and invalidates the whole CloudFront distribution so the edge picks the new
# objects up immediately.
#
# The build reads two sibling directories at the repository root by relative
# path — ../knowledge-base (178 YAML types) and ../blog (MDX + images) — so
# this script always builds from the repository, never from a copy of site/
# on its own. It works from any directory: paths are derived from its own
# location, not the caller's.
#
# Requirements: bun, and the AWS CLI with credentials allowed to write the
# bucket and create invalidations on the distribution. Nothing here reads
# server/.env; the site has no secrets (its .env.production holds only the
# public form endpoint and GA measurement ID, which a static export bakes
# into the HTML anyway).
#
# Portable bash (3.2, macOS's default).

set -euo pipefail

s3_bucket=pulshealth.com
cloudfront_distribution_id=E2B9BMUXL8SCC8

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$script_dir/.." && pwd)
site_dir=$root/site
out_dir=$site_dir/out

skip_build=0
invalidate=1
dry_run=0

usage() {
  sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case $1 in
    --skip-build) skip_build=1 ;;
    --no-invalidation) invalidate=0 ;;
    --dry-run) dry_run=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "deploy-site: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

need() {
  command -v "$1" >/dev/null 2>&1 ||
    { echo "deploy-site: $1 is required but not installed" >&2; exit 1; }
}

# The siblings the build resolves as ../knowledge-base and ../blog. Missing,
# the loaders log and return nothing, so the export silently loses pages
# instead of failing — check first and say so.
for sibling in knowledge-base blog; do
  [ -d "$root/$sibling" ] ||
    { echo "deploy-site: $root/$sibling is missing; site/ must stay a sibling of it" >&2; exit 1; }
done

if [ "$skip_build" -eq 0 ]; then
  need bun
  echo "deploy-site: building site/ (static export)"
  (cd "$site_dir" && bun install --frozen-lockfile && bun run build)
fi

[ -d "$out_dir" ] ||
  { echo "deploy-site: $out_dir does not exist; drop --skip-build" >&2; exit 1; }

# 178 knowledge-base types + blog + the static pages. A build that lost the
# relative path to ../knowledge-base still succeeds, just much smaller, and
# syncing that with --delete would take the knowledge base off the site.
types=$(find "$out_dir/knowledge-base/types" -name index.html 2>/dev/null | wc -l | tr -d ' ')
if [ "$types" -lt 178 ]; then
  echo "deploy-site: only $types knowledge-base type pages in $out_dir (expected 178)." >&2
  echo "deploy-site: refusing to sync a partial export." >&2
  exit 1
fi
echo "deploy-site: $(find "$out_dir" -name '*.html' | wc -l | tr -d ' ') HTML files, $types knowledge-base types"

need aws

dry_run_flag=()
if [ "$dry_run" -eq 1 ]; then
  dry_run_flag=(--dryrun)
  echo "deploy-site: dry run — nothing is written and nothing is invalidated"
fi

echo "deploy-site: syncing to s3://$s3_bucket"
# bash 3.2 (macOS) treats "${arr[@]}" on an EMPTY array as an unbound
# variable under set -u, so a real deploy died here while --dry-run,
# which fills the array, passed. The ${arr[@]+...} guard expands to
# nothing when the array is empty instead of erroring.
aws s3 sync "$out_dir/" "s3://$s3_bucket" --delete ${dry_run_flag[@]+"${dry_run_flag[@]}"}

if [ "$dry_run" -eq 1 ] || [ "$invalidate" -eq 0 ]; then
  echo "deploy-site: skipping the CloudFront invalidation"
  exit 0
fi

echo "deploy-site: invalidating CloudFront $cloudfront_distribution_id"
aws cloudfront create-invalidation \
  --distribution-id "$cloudfront_distribution_id" \
  --paths '/*'

echo "deploy-site: done — https://pulshealth.com"
