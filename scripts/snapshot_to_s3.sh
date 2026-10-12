#!/usr/bin/env bash
# snapshot_to_s3.sh — runs ON the extraction helper (started via SSM Run Command).
#
# Streams an EBS snapshot straight into the S3 golden store:
#
#   EBS direct APIs -> raw stream on stdout -> zstd -> aws s3 cp -
#
# Nothing large lands on the helper's disk: no volume is attached and no
# intermediate raw file is written.
#
# Golden layout written:
#   <prefix>.raw.zst          the image
#   <prefix>.raw.zst.sha256   checksum of the compressed stream
#   <prefix>.stats.json       allocated vs volume bytes, timings
#
# Status + log go to the expiring _status/ and _logs/ prefixes.
set -euo pipefail

SNAPSHOT=""
URI=""
LABEL=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-9}"
WORKERS="${WORKERS:-32}"

while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot-id) SNAPSHOT="$2"; shift 2 ;;
    --s3-uri)      URI="$2"; shift 2 ;;
    --label)       LABEL="$2"; shift 2 ;;
    --region)      REGION="$2"; shift 2 ;;
    --level)       COMPRESSION_LEVEL="$2"; shift 2 ;;
    --workers)     WORKERS="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
: "${SNAPSHOT:?--snapshot-id required}"
: "${URI:?--s3-uri required}"
: "${LABEL:?--label required}"

# boto3 does not read the region from instance metadata, so resolve it here and
# export it for both the AWS CLI and the python reader.
if [ -z "$REGION" ]; then
  _tok=$(curl -sS -X PUT --max-time 5 \
      -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
      http://169.254.169.254/latest/api/token 2>/dev/null || true)
  _az=$(curl -sS --max-time 5 ${_tok:+-H "X-aws-ec2-metadata-token: $_tok"} \
      http://169.254.169.254/latest/meta-data/placement/availability-zone 2>/dev/null || true)
  [ -n "$_az" ] && REGION="${_az%[a-z]}"
fi
[ -n "$REGION" ] || { echo "could not determine AWS region"; exit 5; }
export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"
echo "region: $REGION"

BUCKET="${URI#s3://}"; BUCKET="${BUCKET%%/*}"
# Key, not the s3:// URI. Uploads are s3://${BUCKET}/${key}; a URI here
# stores the sidecars under a doubled "s3://bucket/s3://bucket/..." key.
KEY="${URI#s3://${BUCKET}/}"
PREFIX="${KEY%.raw.zst}"
STATUS_KEY="_status/${LABEL}.json"
LOG_KEY="_logs/${LABEL}.log"
SHA_KEY="${PREFIX}.raw.zst.sha256"
STATS_KEY="${PREFIX}.stats.json"

status() { # $1 = state, $2 = raw json fragment (leading comma) or empty
  printf '{"state":"%s","label":"%s","snapshot":"%s","host":"%s","ts":"%s","s3_uri":"%s"%s}\n' \
    "$1" "$LABEL" "$SNAPSHOT" "$(hostname)" "$(date -u +%FT%TZ)" "$URI" "${2:-}" > /tmp/fw_status.json
  aws s3 cp /tmp/fw_status.json "s3://${BUCKET}/${STATUS_KEY}" --only-show-errors || true
}

publish_log() {
  aws s3 cp /tmp/fw_read.log "s3://${BUCKET}/${LOG_KEY}" --only-show-errors || true
}

on_err() {
  local rc=$?
  status error ",\"err\":\"exit $rc at line ${1}\"" || true
  publish_log || true
  exit "$rc"
}
trap 'on_err $LINENO' ERR

exec > >(tee -a /tmp/fw_read.log) 2>&1
echo "=== snapshot_to_s3: label=$LABEL snapshot=$SNAPSHOT uri=$URI"

status running

have_boto3() {
  local cand
  PY=""
  for cand in /opt/fw-dump/bin/python3 python3; do
    if command -v "$cand" >/dev/null 2>&1 && "$cand" -c 'import boto3' >/dev/null 2>&1; then
      PY="$cand"
      return 0
    fi
  done
  return 1
}

# SSM is Online before user-data finishes. Both installers take this lock so
# two dnf transactions cannot share one cache and delete each other's rpms.
install_tools() {
  local i
  for i in $(seq 1 30); do
    have_boto3 && command -v zstd >/dev/null 2>&1 && return 0
    echo "tools not ready (attempt $i); waiting on package install"
    flock /var/run/fw-dnf.lock bash -c '
      set -e
      dnf install -y python3 python3-pip zstd jq
      python3 -m venv /opt/fw-dump
      /opt/fw-dump/bin/pip install --quiet --upgrade boto3
    ' || true
    sleep 10
  done
  have_boto3 && command -v zstd >/dev/null 2>&1
}

install_tools || { echo "could not obtain python3 with boto3 and zstd"; exit 4; }
echo "interpreter: $PY"

rm -f /tmp/fw_fifo
mkfifo /tmp/fw_fifo
( sha256sum < /tmp/fw_fifo | awk '{print $1}' > /tmp/fw_sha256 ) &
SHA_PID=$!

echo "--- streaming: ebs-direct -> zstd -$COMPRESSION_LEVEL -> s3"
set -o pipefail
"$PY" /tmp/ebs_snapshot_read.py \
    --snapshot-id "$SNAPSHOT" \
    --region "$REGION" \
    --workers "$WORKERS" \
    --stats-out /tmp/fw_stats.json \
  | zstd "-T0" "-$COMPRESSION_LEVEL" -c \
  | tee /tmp/fw_fifo \
  | aws s3 cp - "$URI" --only-show-errors

wait "$SHA_PID"
SHA=$(cat /tmp/fw_sha256)
echo "sha256(compressed stream) = $SHA"

printf '%s  %s\n' "$SHA" "$(basename "$URI")" > /tmp/fw_sha256.side
aws s3 cp /tmp/fw_sha256.side "s3://${BUCKET}/${SHA_KEY}" --only-show-errors
aws s3 cp /tmp/fw_stats.json "s3://${BUCKET}/${STATS_KEY}" --only-show-errors

VB=$(grep -o '"volume_bytes": *[0-9]*' /tmp/fw_stats.json | grep -o '[0-9]*' || echo 0)
AB=$(grep -o '"allocated_bytes": *[0-9]*' /tmp/fw_stats.json | grep -o '[0-9]*' || echo 0)
BL=$(grep -o '"allocated_blocks": *[0-9]*' /tmp/fw_stats.json | grep -o '[0-9]*' || echo 0)

status ok ",\"sha256\":\"$SHA\",\"volume_bytes\":$VB,\"allocated_bytes\":$AB,\"allocated_blocks\":$BL"

publish_log
echo "=== snapshot_to_s3 done"
