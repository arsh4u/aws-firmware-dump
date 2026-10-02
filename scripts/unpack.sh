#!/usr/bin/env bash
# unpack.sh — turn downloaded .raw.zst artifacts into sparse raw images + metadata.
#
# Unpacks every disk of a label. The local filename is artifacts/ + basename(s3_key),
# which is what pull.sh writes. disks[].local_path is not required.
#
#   scripts/unpack.sh <label> [<label> ...] [--out DIR] [--force]
#   scripts/unpack.sh --all
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

OUT_DIR="$DUMP_ROOT/artifacts/raw"
FORCE=0
ALL=0
LABELS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --out)   OUT_DIR="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --all)   ALL=1; shift ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    -*) die "unknown argument: $1" ;;
    *) LABELS+=("$1"); shift ;;
  esac
done

require zstd
load_env
manifest_init
MANIFEST=$(manifest_path)

if [ "$ALL" -eq 1 ]; then
  mapfile -t LABELS < <(jq -r '.images | keys[]' "$MANIFEST" | sort -V)
fi
[ "${#LABELS[@]}" -gt 0 ] || die "nothing selected (pass labels, or --all)"

mkdir -p "$OUT_DIR"
n_ok=0; n_skip=0; n_missing=0; n_fail=0

for label in "${LABELS[@]}"; do
  if ! jq -e --arg l "$label" '.images[$l]' "$MANIFEST" >/dev/null 2>&1; then
    warn "$label not in manifest — skipping"
    n_fail=$((n_fail + 1))
    continue
  fi

  mapfile -t SRCS < <(jq -r --arg l "$label" '
      .images[$l]
      | ((.disks // []) | if length == 0 then [{s3_key: .s3_key}] else . end)
      | .[]
      | (.s3_key // .local_path // empty)
      | select(. != "")
      | "artifacts/" + (split("/") | last)' "$MANIFEST")

  if [ "${#SRCS[@]}" -eq 0 ]; then
    warn "$label: no s3_key recorded for any disk — skipping"
    n_fail=$((n_fail + 1))
    continue
  fi

  for rel in "${SRCS[@]}"; do
    SRC="$DUMP_ROOT/$rel"
    if [ ! -f "$SRC" ]; then
      warn "$label: missing $rel  (run: scripts/pull.sh $label)"
      n_missing=$((n_missing + 1))
      continue
    fi

    B=$(basename "$SRC"); B="${B%.zst}"
    DEST="$OUT_DIR/$B"
    META="$OUT_DIR/${B%.raw}.diskmeta.txt"

    if [ "$FORCE" -eq 0 ] && [ -f "$DEST" ] && [ "$DEST" -nt "$SRC" ]; then
      log "up to date  $B  (apparent=$(du -h --apparent-size "$DEST" | cut -f1) on-disk=$(du -h "$DEST" | cut -f1))"
      n_skip=$((n_skip + 1))
      continue
    fi

    log "decompressing $(basename "$SRC") -> $B  (sparse)"
    if ! zstd -dc "$SRC" | dd of="$DEST" bs=1M conv=sparse status=none; then
      warn "$label: failed to unpack $rel"
      n_fail=$((n_fail + 1))
      continue
    fi

    {
      echo "label=$label source=$SRC"
      echo "apparent=$(du -h --apparent-size "$DEST" | cut -f1) on_disk=$(du -h "$DEST" | cut -f1)"
      echo "--- file"
      file "$DEST" 2>/dev/null || true
      echo "--- sfdisk"
      sfdisk -d "$DEST" 2>/dev/null || true
      echo "--- blkid"
      blkid -p "$DEST" 2>/dev/null || true
      echo "--- parted"
      parted -s "$DEST" unit s print 2>/dev/null || true
    } > "$META" 2>&1 || true

    log "  $B  apparent=$(du -h --apparent-size "$DEST" | cut -f1)  on-disk=$(du -h "$DEST" | cut -f1)"
    log "  metadata -> $(basename "$META")"
    log "  mount with: losetup -Pf --show $DEST"
    n_ok=$((n_ok + 1))
  done
done

log "unpacked=$n_ok  up-to-date=$n_skip  missing=$n_missing  failed=$n_fail"
log "raw store: apparent=$(du -sh --apparent-size "$OUT_DIR" | cut -f1)  on-disk=$(du -sh "$OUT_DIR" | cut -f1)"
[ "$n_fail" -eq 0 ] || die "$n_fail label(s)/disk(s) failed"
