#!/usr/bin/env bash
# pull.sh — copy specific images out of the S3 golden store, verified.
#
# Acquisition happens inside AWS. This is the only step that uses local bandwidth.
#
#   scripts/pull.sh my-image
#   scripts/pull.sh --all
#   scripts/pull.sh --raw my-image     # also materialise a sparse .raw
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ALL=0
RAW=0
LABELS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --all) ALL=1; shift ;;
    --raw) RAW=1; shift ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) LABELS+=("$1"); shift ;;
  esac
done

require aws
require jq
load_env
manifest_init
MANIFEST=$(manifest_path)

if [ "$ALL" -eq 1 ]; then
  mapfile -t LABELS < <(jq -r '.images | keys[]' "$MANIFEST" | sort -V)
fi
[ "${#LABELS[@]}" -gt 0 ] || die "nothing selected (pass labels, or --all)"

mkdir -p "$DUMP_ROOT/artifacts"
failed=0
pulled=0

for label in "${LABELS[@]}"; do
  found=0
  while IFS=$'\t' read -r dkey dsha; do
    [ -n "$dkey" ] || continue
    found=1
    dest="$DUMP_ROOT/artifacts/$(basename "$dkey")"

    if [ -f "$dest" ] && [ "$(sha256_file "$dest")" = "$dsha" ]; then
      log "OK (cached, verified) $(basename "$dkey")"
      pulled=$((pulled + 1))
      continue
    fi

    log "pulling $(basename "$dkey")"
    aws s3 cp "s3://${DUMP_BUCKET}/${dkey}" "$dest" --only-show-errors --no-progress

    got=$(sha256_file "$dest")
    if [ "$got" != "$dsha" ]; then
      warn "sha256 mismatch for $dkey: expected=$dsha got=$got"
      failed=$((failed + 1))
      continue
    fi
    log "verified $(basename "$dkey")"
    pulled=$((pulled + 1))
  done < <(jq -r --arg l "$label" '
      .images[$l] | (.disks // [{s3_key: .s3_key, sha256: .sha256}])[]
      | [(.s3_key // ""), (.sha256 // "")] | @tsv' "$MANIFEST")

  if [ "$found" -eq 0 ]; then
    warn "$label not in manifest — skipping"
    failed=$((failed + 1))
    continue
  fi

  manifest_apply --arg l "$label" '
    .images[$l].downloaded = true
    | .images[$l].local_path = ("artifacts/" + (.images[$l].s3_key | split("/") | last))
    | .images[$l].disks = [ .images[$l].disks[]
        | . + { local_path: ("artifacts/" + (.s3_key | split("/") | last)) } ]
  '

  [ "$RAW" -eq 1 ] && "$DUMP_ROOT/scripts/unpack.sh" "$label"
done

[ "$failed" -eq 0 ] || die "$failed label(s) failed"
log "done — $(du -sh "$DUMP_ROOT/artifacts" | cut -f1) local, $pulled object(s) verified"
