#!/usr/bin/env bash
# Shared helpers for the generic AMI dump pipeline.
# shellcheck shell=bash

set -euo pipefail

DUMP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DUMP_ROOT

: "${AWS_REGION:=us-east-1}"
export AWS_REGION

: "${DUMP_PURPOSE:=firmware-dump}"

log()  { printf '[%s] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { log "FATAL: $*"; exit 1; }
warn() { log "WARN: $*"; }

require() {
  command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"
}

load_env() {
  if [ -z "${DUMP_BUCKET:-}" ]; then
    [ -f "$DUMP_ROOT/.env" ] || die "missing $DUMP_ROOT/.env — run scripts/configure.sh first"
    # shellcheck disable=SC1091
    . "$DUMP_ROOT/.env"
  fi
  : "${DUMP_BUCKET:?DUMP_BUCKET unset}"
  : "${DUMP_INSTANCE_PROFILE:?DUMP_INSTANCE_PROFILE unset}"
  : "${DUMP_SECURITY_GROUP:?DUMP_SECURITY_GROUP unset}"
  : "${DUMP_SUBNETS:?DUMP_SUBNETS unset}"
  : "${DUMP_PURPOSE:=firmware-dump}"
}

state_dir() {
  local d="${DUMP_STATE_DIR:-$DUMP_ROOT/.run}"
  mkdir -p "$d"
  echo "$d"
}

manifest_path() { echo "${DUMP_MANIFEST:-$DUMP_ROOT/manifest.json}"; }

manifest_init() {
  local m
  m=$(manifest_path)
  [ -f "$m" ] || printf '{"images":{}}\n' > "$m"
}

# Serialize read-modify-write of the manifest. Concurrent dump.sh workers and
# separate driver processes share ${manifest}.lock.
manifest_apply() {
  local m tmp
  m=$(manifest_path)
  tmp=$(mktemp)
  (
    flock 9
    jq "$@" "$m" > "$tmp" && mv "$tmp" "$m"
  ) 9>"${m}.lock"
}

# Pick the first subnet, optionally preferring one whose AZ matches $1.
subnet_for_az() {
  local want_az="${1:-}" entry sub az
  for entry in ${DUMP_SUBNETS//,/ }; do
    sub="$entry"
    if [ -n "$want_az" ]; then
      az=$(jq -r --arg s "$sub" '.[$s] // empty' "$DUMP_ROOT/.azs" 2>/dev/null || true)
      [ "$az" = "$want_az" ] && { echo "$sub"; return 0; }
    fi
  done
  echo "${DUMP_SUBNETS%%,*}"
}

az_of_subnet() {
  local sub="$1"
  jq -r --arg s "$sub" '.[$s] // empty' "$DUMP_ROOT/.azs" 2>/dev/null || true
}

sha256_file() { sha256sum "$1" | awk '{print $1}'; }

validate_label() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}$ ]] \
    || die "label must match ^[A-Za-z0-9][A-Za-z0-9._-]{0,62}\$ (got: $1)"
}

validate_ami() {
  [[ "$1" =~ ^ami-[0-9a-f]{8}$ || "$1" =~ ^ami-[0-9a-f]{17}$ ]] \
    || die "not an AMI id: $1"
}

# Marketplace listings pick the allowed types. x86 vs arm is the only generic
# split; pass --boot-type when a listing rejects the default.
default_boot_type() {
  case "$1" in
    arm64) printf '%s\n' "m6g.xlarge" ;;
    *)     printf '%s\n' "m5.xlarge" ;;
  esac
}

public_ip_args() {
  if [ "${DUMP_ASSOCIATE_PUBLIC_IP:-true}" = "true" ]; then
    printf '%s\n' "--associate-public-ip-address"
  else
    printf '%s\n' "--no-associate-public-ip-address"
  fi
}
