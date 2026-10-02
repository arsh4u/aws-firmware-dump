#!/usr/bin/env bash
# cleanup.sh — inventory and tear down resources this pipeline bills for.
#
#   scripts/cleanup.sh --list        show live billable resources
#   scripts/cleanup.sh --helpers     terminate extraction helpers only
#   scripts/cleanup.sh --snapshots   delete snapshots (skips Keep=true unless --force)
#   scripts/cleanup.sh --staging     empty the S3 staging prefix
#   scripts/cleanup.sh --all         helpers + boot instances + volumes + snapshots + staging
#
# Discovery is by tag Purpose=<DUMP_PURPOSE>. Nothing else is touched.
# --register-ami / --keep-snapshot tag snapshots Keep=true so a routine cleanup
# does not delete the disks behind a registered AMI. Pass --force to delete those too.
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DO_LIST=0; DO_HELPERS=0; DO_STAGING=0; DO_VOLUMES=0; DO_SNAPSHOTS=0; DO_ALL=0; FORCE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --list)      DO_LIST=1; shift ;;
    --helpers)   DO_HELPERS=1; shift ;;
    --staging)   DO_STAGING=1; shift ;;
    --volumes)   DO_VOLUMES=1; shift ;;
    --snapshots) DO_SNAPSHOTS=1; shift ;;
    --all)       DO_ALL=1; DO_LIST=1; DO_HELPERS=1; DO_STAGING=1; DO_VOLUMES=1; DO_SNAPSHOTS=1; shift ;;
    --force)     FORCE=1; shift ;;
    -h|--help)   sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

require aws
require jq
[ -f "$DUMP_ROOT/.env" ] && . "$DUMP_ROOT/.env" || true
: "${DUMP_PURPOSE:=firmware-dump}"
TAG="Name=tag:Purpose,Values=${DUMP_PURPOSE}"

list_all() {
  echo "=== EC2 instances (Purpose=${DUMP_PURPOSE}) ==="
  aws ec2 describe-instances --filters "$TAG" "Name=instance-state-name,Values=running,pending,stopped,stopping" \
    --query 'Reservations[].Instances[].[InstanceId,InstanceType,State.Name,Tags[?Key==`Role`].Value|[0],Tags[?Key==`Name`].Value|[0]]' \
    --output text | sort || true
  echo "=== EBS volumes ==="
  aws ec2 describe-volumes --filters "$TAG" \
    --query 'Volumes[].[VolumeId,Size,State,AvailabilityZone,Tags[?Key==`Name`].Value|[0]]' \
    --output text | sort || true
  echo "=== snapshots ==="
  aws ec2 describe-snapshots --owner-ids self --filters "$TAG" \
    --query 'Snapshots[].[SnapshotId,VolumeSize,State,Tags[?Key==`Keep`].Value|[0],Tags[?Key==`Name`].Value|[0]]' \
    --output text | sort || true
  echo "=== local artifacts ==="
  if [ -d "$DUMP_ROOT/artifacts" ]; then
    du -sh "$DUMP_ROOT/artifacts" 2>/dev/null || true
  else
    echo "(none)"
  fi
  if [ -n "${DUMP_BUCKET:-}" ]; then
    echo "=== S3 staging ==="
    aws s3 ls --summarize --recursive "s3://${DUMP_BUCKET}/staging/" 2>/dev/null | tail -2 || true
  fi
}

terminate_matching() {
  local extra="$1" ids
  if [ -n "$extra" ]; then
    ids=$(aws ec2 describe-instances --filters "$TAG" "$extra" \
          "Name=instance-state-name,Values=running,pending,stopped,stopping" \
          --query 'Reservations[].Instances[].InstanceId' --output text)
  else
    ids=$(aws ec2 describe-instances --filters "$TAG" \
          "Name=instance-state-name,Values=running,pending,stopped,stopping" \
          --query 'Reservations[].Instances[].InstanceId' --output text)
  fi
  if [ -n "$ids" ] && [ "$ids" != "None" ]; then
    log "terminating: $ids"
    # shellcheck disable=SC2086
    aws ec2 terminate-instances --instance-ids $ids \
      --query 'TerminatingInstances[].InstanceId' --output text
  else
    log "no matching instances"
  fi
}

terminate_helpers() {
  # --all stops boot instances too. --helpers leaves an in-flight boot alone.
  if [ "$DO_ALL" -eq 1 ]; then
    terminate_matching ""
  else
    terminate_matching "Name=tag:Role,Values=helper"
  fi
  rm -f "$DUMP_ROOT/.run"/helper*.id "${DUMP_STATE_DIR:-$DUMP_ROOT/.run}"/helper*.id
}

delete_volumes() {
  local vols v
  vols=$(aws ec2 describe-volumes --filters "$TAG" \
         --query 'Volumes[?State==`available`].VolumeId' --output text)
  for v in $vols; do
    [ "$v" = "None" ] && continue
    [ -n "$v" ] || continue
    log "deleting volume $v"
    aws ec2 delete-volume --volume-id "$v" || warn "could not delete $v"
  done
  [ -z "$vols" ] || [ "$vols" = "None" ] && log "no deletable volumes"
}

delete_snapshots() {
  local raw snaps s keep
  raw=$(aws ec2 describe-snapshots --owner-ids self --filters "$TAG" --output json)
  if [ "$FORCE" -eq 1 ]; then
    snaps=$(jq -r '.Snapshots[].SnapshotId // empty' <<<"$raw")
  else
    snaps=$(jq -r '
      .Snapshots[]
      | select([.Tags[]? | select(.Key == "Keep" and .Value == "true")] | length == 0)
      | .SnapshotId' <<<"$raw")
    keep=$(jq -r '
      .Snapshots[]
      | select([.Tags[]? | select(.Key == "Keep" and .Value == "true")] | length > 0)
      | .SnapshotId' <<<"$raw")
    if [ -n "$keep" ]; then
      log "keeping snapshots tagged Keep=true (pass --force to delete): $(printf '%s' "$keep" | tr '\n' ' ')"
    fi
  fi
  if [ -z "$snaps" ]; then
    log "no snapshots to delete"
    return 0
  fi
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    log "deleting snapshot $s"
    aws ec2 delete-snapshot --snapshot-id "$s" || warn "could not delete $s (a registered AMI may still reference it)"
  done <<<"$snaps"
}

empty_staging() {
  [ -n "${DUMP_BUCKET:-}" ] || { warn "DUMP_BUCKET unset; skipping staging"; return 0; }
  log "emptying s3://${DUMP_BUCKET}/staging/"
  aws s3 rm "s3://${DUMP_BUCKET}/staging/" --recursive --only-show-errors || warn "staging not emptied"
}

[ "$DO_LIST" -eq 1 ] && list_all
[ "$DO_HELPERS" -eq 1 ] && terminate_helpers
[ "$DO_VOLUMES" -eq 1 ] && delete_volumes
[ "$DO_SNAPSHOTS" -eq 1 ] && delete_snapshots
[ "$DO_STAGING" -eq 1 ] && empty_staging
exit 0
