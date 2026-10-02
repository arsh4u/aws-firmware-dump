#!/usr/bin/env bash
# ls.sh — show the S3 golden store and manifest. No heavy I/O, no egress.
#
#   scripts/ls.sh [--local] [--json]
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SHOW_LOCAL=0
AS_JSON=0

while [ $# -gt 0 ]; do
  case "$1" in
    --local) SHOW_LOCAL=1; shift ;;
    --json)  AS_JSON=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require aws
require jq
load_env
manifest_init
MANIFEST=$(manifest_path)

if [ "$AS_JSON" -eq 1 ]; then
  jq '.' "$MANIFEST"
  exit 0
fi

echo "=== golden store: s3://${DUMP_BUCKET}/golden/ ==="
aws s3 ls --recursive --human-readable --summarize "s3://${DUMP_BUCKET}/golden/" 2>/dev/null \
  | awk '/\.raw\.zst$/ {printf "  %8s %10s  %s\n", $3, $4, $5} /^Total/ {print "  " $0}' \
  || true
echo

echo "=== manifest (${MANIFEST##*/}) ==="
jq -r '
  [ .images | to_entries[] ] as $e
  | if ($e | length) == 0 then "  (empty — nothing acquired yet)"
    else
      "  \($e | length) image(s)",
      "  compressed total: \((($e | map([.value.disks[]?.compressed_bytes] | add // .value.compressed_bytes // 0) | add // 0) / 1073741824 * 100 | round) / 100) GiB",
      "",
      ($e | sort_by(.key)[] |
        "  \(.key)\n    \(.value.architecture // "?")  \(.value.ami // "")  \(.value.name // "")\n    sha256 \(.value.sha256[0:16])…  \(.value.fetched_utc // "")")
    end
' "$MANIFEST"

if [ "$SHOW_LOCAL" -eq 1 ]; then
  echo
  echo "=== local artifacts ==="
  if [ -d "$DUMP_ROOT/artifacts" ] && [ -n "$(ls -1 "$DUMP_ROOT/artifacts" 2>/dev/null || true)" ]; then
    du -sh "$DUMP_ROOT/artifacts"
    ls -lh "$DUMP_ROOT/artifacts" | awk 'NR>1 {printf "  %8s  %s\n", $5, $9}'
  else
    echo "  (none — the golden store in S3 is the source of truth)"
  fi
fi
