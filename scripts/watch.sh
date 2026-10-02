#!/usr/bin/env bash
# watch.sh — watch an in-flight acquisition.
#
# Progress lines are produced on the helper and only published to S3 when the
# job ends. This polls the helper over SSM, plus multipart upload size and the
# status object.
#
#   scripts/watch.sh
#   scripts/watch.sh --interval 5
#   scripts/watch.sh --once
#   scripts/watch.sh --label my-image
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

INTERVAL=15
ONCE=0
LABEL=""

while [ $# -gt 0 ]; do
  case "$1" in
    --interval) INTERVAL="$2"; shift 2 ;;
    --once)     ONCE=1; shift ;;
    --label)    LABEL="$2"; shift 2 ;;
    -h|--help)  sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require aws
require jq
load_env
TAG="Name=tag:Purpose,Values=${DUMP_PURPOSE}"

remote_tail() {
  local iid="$1" cf out cid
  cf=$(mktemp)
  cat > "$cf" <<'JSON'
{
  "DocumentName": "AWS-RunShellScript",
  "Parameters": {
    "commands": [
      "echo \"--- host=$(hostname)\"",
      "ls -la /tmp/fw_read.log 2>/dev/null || echo '(no log yet)'",
      "tail -n 6 /tmp/fw_read.log 2>/dev/null || true",
      "echo '--- procs:'",
      "pgrep -af 'snapshot_to_s3|ebs_snapshot_read' || echo '(none)'"
    ]
  }
}
JSON
  cid=$(aws ssm send-command --instance-ids "$iid" --cli-input-json "file://$cf" \
        --query 'Command.CommandId' --output text 2>/dev/null || true)
  rm -f "$cf"
  [ -n "$cid" ] || { echo "  (ssm send failed)"; return 0; }
  local _
  for _ in $(seq 1 12); do
    out=$(aws ssm get-command-invocation --command-id "$cid" --instance-id "$iid" \
          --query 'StandardOutputContent' --output text 2>/dev/null || true)
    if [ -n "$out" ] && [ "$out" != "None" ]; then echo "$out"; return 0; fi
    sleep 2
  done
  echo "  (no output)"
}

uploaded_bytes() {
  local total=0 uid key size
  while IFS=$'\t' read -r key uid; do
    [ -n "${uid:-}" ] || continue
    size=$(aws s3api list-parts --bucket "$DUMP_BUCKET" --key "$key" --upload-id "$uid" \
           --query 'Parts[].Size' --output json 2>/dev/null | jq 'add // 0')
    total=$((total + size))
  done < <(aws s3api list-multipart-uploads --bucket "$DUMP_BUCKET" \
             --query 'Uploads[].[Key,UploadId]' --output text 2>/dev/null || true)
  echo "$total"
}

i=0
while :; do
  i=$((i + 1))
  echo "==================================================================="
  echo " $(date -u +%H:%M:%SZ)   poll #$i"
  echo "==================================================================="

  if [ -n "$LABEL" ]; then
    body=$(aws s3 cp "s3://${DUMP_BUCKET}/_status/${LABEL}.json" - --only-show-errors 2>/dev/null || true)
    [ -n "$body" ] && echo "status  : $(jq -c '{state,snapshot,ts,sha256}' <<<"$body")"
  else
    for k in $(aws s3 ls "s3://${DUMP_BUCKET}/_status/" 2>/dev/null | awk '{print $NF}'); do
      body=$(aws s3 cp "s3://${DUMP_BUCKET}/_status/${k}" - --only-show-errors 2>/dev/null || true)
      [ -n "$body" ] && echo "status  : $(jq -c '{label,state,ts}' <<<"$body")"
    done
  fi

  ub=$(uploaded_bytes)
  echo "upload  : $((ub / 1048576)) MiB in flight"
  aws s3 ls "s3://${DUMP_BUCKET}/golden/" 2>/dev/null | while read -r _ _ _ dir; do
    [ -n "${dir:-}" ] || continue
    aws s3 ls --human-readable "s3://${DUMP_BUCKET}/${dir}" 2>/dev/null \
      | awk -v d="$dir" '$NF ~ /\.raw\.zst$/ {printf "done    : %s %s %s\n", d, $3, $4}'
  done

  boots=$(aws ec2 describe-instances --filters "$TAG" "Name=tag:Role,Values=boot" \
          "Name=instance-state-name,Values=pending,running" \
          --query 'Reservations[].Instances[].[InstanceId,State.Name,Tags[?Key==`Label`].Value|[0]]' \
          --output text 2>/dev/null || true)
  if [ -n "$boots" ] && [ "$boots" != "None" ]; then
    echo "boot    : $boots"
  fi

  helpers=$(aws ec2 describe-instances --filters "$TAG" "Name=tag:Role,Values=helper" \
            "Name=instance-state-name,Values=running" \
            --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null || true)
  if [ -z "$helpers" ] || [ "$helpers" = "None" ]; then
    echo "helper  : (none running)"
  else
    for h in $helpers; do
      echo "helper  : $h"
      remote_tail "$h" | sed 's/^/          /'
    done
  fi

  [ "$ONCE" -eq 1 ] && break
  sleep "$INTERVAL"
done
