#!/usr/bin/env bash
# probe.sh — free check that this account can launch an AMI.
#
# `run-instances --dry-run` performs semantic validation and does not boot
# anything. OptInRequired means the Marketplace listing still needs a one-time
# terms acceptance in the console. This script will not accept terms.
#
#   scripts/probe.sh --ami ami-...
#   scripts/probe.sh --ami ami-... --boot-type m5.2xlarge
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AMI=""
BOOT_TYPE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ami)       AMI="$2"; shift 2 ;;
    --boot-type) BOOT_TYPE="$2"; shift 2 ;;
    -h|--help)   sed -n '2,12p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -n "$AMI" ] || die "--ami is required"
validate_ami "$AMI"
require aws
require jq
load_env

src=$(aws ec2 describe-images --image-ids "$AMI" --output json --query 'Images[0]') \
  || die "describe-images failed for $AMI in $AWS_REGION"
[ "$src" != "null" ] && [ -n "$src" ] || die "AMI $AMI not visible in $AWS_REGION"

arch=$(jq -r '.Architecture // "x86_64"' <<<"$src")
name=$(jq -r '.Name // ""' <<<"$src")
owner=$(jq -r '.OwnerId // ""' <<<"$src")
root=$(jq -r '.RootDeviceName // ""' <<<"$src")
codes=$(jq -r '[.ProductCodes[]?.ProductCodeId] | join(",")' <<<"$src")
itype="${BOOT_TYPE:-$(default_boot_type "$arch")}"
sub="${DUMP_SUBNETS%%,*}"

echo "ami:       $AMI"
echo "name:      ${name:-unknown}"
echo "owner:     ${owner:-unknown}"
echo "arch:      $arch"
echo "root:      ${root:-unknown}"
echo "products:  ${codes:-none}"
echo "boot type: $itype"
echo "region:    $AWS_REGION"
echo

out=$(aws ec2 run-instances --image-id "$AMI" --instance-type "$itype" \
      --subnet-id "$sub" --security-group-ids "$DUMP_SECURITY_GROUP" \
      --count 1 --dry-run 2>&1 || true)
case "$out" in
  *DryRunOperation*)
    echo "result: launchable (dry-run accepted)"
    ;;
  *OptInRequired*)
    echo "result: not subscribed"
    echo
    echo "Accept that Marketplace listing in the AWS console, then re-run this probe."
    echo "Subscribing is a terms acceptance. This tool will not accept it for you."
    echo "A software fee, if the listing has one, accrues only while a boot instance runs."
    exit 2
    ;;
  *)
    echo "result: not launchable"
    printf '%s\n' "$out" | tr '\n' ' ' | cut -c1-400
    echo
    echo "Unsupported / InvalidParameter usually means the listing rejects $itype. Pass --boot-type."
    exit 3
    ;;
esac
