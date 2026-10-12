#!/usr/bin/env bash
# dump.sh — acquire disk images from AMIs you can launch, into the S3 golden store.
#
#   AMI you supply
#     -> boot an instance, snapshot every EBS volume it owns
#     -> read those snapshots with the EBS direct APIs (no volume, no attach)
#     -> raw -> zstd -> s3://<bucket>/golden/<label>/<label>.raw.zst
#     -> record sha256 + provenance in manifest.json
#
# There is no catalog. Every AMI id comes from the command line or a batch file.
#
# Why not snapshot -> volume -> attach? A volume derived from a Marketplace
# snapshot carries the product code, and AWS only allows that volume to be
# attached as the root device of a stopped instance. The EBS direct APIs read
# the bytes over HTTPS, so nothing is attached.
#
# S3 is the store. Nothing is pulled locally unless you pass --download.
#
# Usage:
#   scripts/dump.sh --ami ami-... --label my-image
#   scripts/dump.sh --ami ami-... --label my-image --boot-type m5.xlarge --dwell 60
#   scripts/dump.sh --batch images.tsv --jobs 4
#   scripts/dump.sh --ami ami-... --label my-image --dry-run
#
# Batch file: one image per line, blank lines and '#' comments ignored.
#   LABEL  AMI  [BOOT_TYPE]
#
# Options:
#   --ami ID            source AMI (required unless --batch)
#   --label NAME        stable label (required unless --batch)
#   --batch FILE        LABEL AMI [BOOT_TYPE] lines
#   --jobs N            N workers, each with its own helper slot
#   --boot-type TYPE    instance type used to realise the image
#                       (default m5.xlarge, or m6g.xlarge for arm64)
#   --dwell SECONDS     seconds to let the guest run before snapshot (default 180)
#   --workers N         EBS direct API concurrency per disk (default 32)
#   --snapshot-id SNAP  resume from an existing snapshot; skips boot (single image only)
#   --download          also pull the .raw.zst here and verify sha256
#   --register-ami      register a launchable AMI in this account (keeps snapshots)
#   --keep-snapshot     keep derived snapshots (billed monthly)
#   --force             re-fetch even if the object is already in S3
#   --dry-run           describe the AMI and print the plan; do not launch
set -euo pipefail

# shellcheck source=./lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AMI=""
LABEL=""
BATCH=""
BOOT_TYPE="${DUMP_BOOT_TYPE:-}"
DWELL="${DUMP_DWELL:-180}"
WORKERS="${DUMP_WORKERS:-32}"
RESUME_SNAP=""
KEEP_SNAPSHOT=0
DO_DOWNLOAD=0
REGISTER_AMI=0
FORCE=0
DRY_RUN=0
JOBS="${DUMP_JOBS:-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --ami)           AMI="$2"; shift 2 ;;
    --label)         LABEL="$2"; shift 2 ;;
    --batch)         BATCH="$2"; shift 2 ;;
    --boot-type)     BOOT_TYPE="$2"; shift 2 ;;
    --dwell)         DWELL="$2"; shift 2 ;;
    --jobs)          JOBS="$2"; shift 2 ;;
    --workers)       WORKERS="$2"; shift 2 ;;
    --snapshot-id)   RESUME_SNAP="$2"; shift 2 ;;
    --download)      DO_DOWNLOAD=1; shift ;;
    --register-ami)  REGISTER_AMI=1; KEEP_SNAPSHOT=1; shift ;;
    --keep-snapshot) KEEP_SNAPSHOT=1; shift ;;
    --force)         FORCE=1; shift ;;
    --dry-run)       DRY_RUN=1; shift ;;
    -h|--help)       sed -n '2,40p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
case "$JOBS" in ''|*[!0-9]*) die "--jobs must be a positive integer" ;; esac
[ "$JOBS" -ge 1 ] || die "--jobs must be >= 1"
case "$DWELL" in ''|*[!0-9]*) die "--dwell must be a non-negative integer" ;; esac
case "$WORKERS" in ''|*[!0-9]*) die "--workers must be a positive integer" ;; esac
[ "$WORKERS" -ge 1 ] || die "--workers must be >= 1"

if [ -n "$BATCH" ] && [ -n "$AMI$LABEL" ]; then
  die "--batch cannot be combined with --ami/--label"
fi
if [ -n "$BATCH" ] && [ -n "$RESUME_SNAP" ]; then
  die "--snapshot-id cannot be combined with --batch"
fi
if [ -z "$BATCH" ]; then
  [ -n "$AMI" ] || die "--ami is required unless --batch"
  [ -n "$LABEL" ] || die "--label is required unless --batch"
fi
[ -n "$AMI" ] && validate_ami "$AMI"
[ -n "$LABEL" ] && validate_label "$LABEL"

require aws
require jq
require flock
load_env
manifest_init
STATE=$(state_dir)
MANIFEST=$(manifest_path)
PURPOSE="${DUMP_PURPOSE}"

# ---------------------------------------------------------------------------
# helper instance lifecycle (one per worker slot)
# ---------------------------------------------------------------------------
helper_file() { echo "${STATE}/helper${DUMP_SLOT:+.$DUMP_SLOT}.id"; }

TRACK_INSTANCES=()
TRACK_SNAPSHOTS=()

track_instance() { TRACK_INSTANCES+=("$1"); }
track_snapshot() { TRACK_SNAPSHOTS+=("$1"); }

reclaim() {
  local rc=$? x
  # Snapshots are not deleted here. The remote read is detached and can still
  # be running if this process dies; deleting the snapshot would destroy the
  # transfer. Success path deletes them. Leftovers: scripts/cleanup.sh --snapshots
  if [ "${#TRACK_SNAPSHOTS[@]}" -gt 0 ] && [ "$KEEP_SNAPSHOT" -eq 0 ]; then
    for x in "${TRACK_SNAPSHOTS[@]}"; do
      [ -n "$x" ] || continue
      warn "snapshot $x left in place (a detached read may still need it); reclaim with scripts/cleanup.sh --snapshots"
    done
  fi
  if [ "${#TRACK_INSTANCES[@]}" -gt 0 ]; then
    for x in "${TRACK_INSTANCES[@]}"; do
      [ -n "$x" ] || continue
      aws ec2 terminate-instances --instance-ids "$x" >/dev/null 2>&1 || true
    done
  fi
  return "$rc"
}
trap reclaim EXIT

helper_id() {
  local id="" f st
  f=$(helper_file)
  [ -f "$f" ] && id=$(cat "$f")
  if [ -n "$id" ]; then
    st=$(aws ec2 describe-instances --instance-ids "$id" \
         --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "gone")
    [ "$st" = "running" ] && { echo "$id"; return 0; }
  fi
  return 1
}

helper_az() {
  aws ec2 describe-instances --instance-ids "$1" \
    --query 'Reservations[0].Instances[0].Placement.AvailabilityZone' --output text
}

wait_ssm_online() {
  local id="$1" i
  for i in $(seq 1 60); do
    if [ "$(aws ssm describe-instance-information \
            --filters "Key=InstanceIds,Values=$id" \
            --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)" = "Online" ]; then
      return 0
    fi
    sleep 10
  done
  die "helper $id never came Online in SSM"
}

terminate_slot_helper() {
  local f id
  f=$(helper_file); [ -f "$f" ] || return 0
  id=$(cat "$f"); [ -n "$id" ] || return 0
  aws ec2 terminate-instances --instance-ids "$id" >/dev/null 2>&1 || true
  rm -f "$f"
}

launch_helper() {
  local sub id ud root_dev root_gb helper_ami pub=()
  sub=$(subnet_for_az "${PREFERRED_AZ:-}")
  root_gb="${DUMP_HELPER_DISK_GB:-30}"
  mapfile -t pub < <(public_ip_args)

  helper_ami=$(aws ssm get-parameter \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-6.1-x86_64 \
    --query 'Parameter.Value' --output text)
  root_dev=$(aws ec2 describe-images --image-ids "$helper_ami" \
    --query 'Images[0].RootDeviceName' --output text)

  log "launching helper (${DUMP_HELPER_TYPE:-t3.medium}, ${root_gb} GiB root) in $sub"
  ud=$(mktemp)
  cp "$DUMP_ROOT/scripts/helper_user_data.sh" "$ud"

  id=$(aws ec2 run-instances \
        --image-id "$helper_ami" \
        --instance-type "${DUMP_HELPER_TYPE:-t3.medium}" \
        --subnet-id "$sub" \
        --security-group-ids "$DUMP_SECURITY_GROUP" \
        --iam-instance-profile "Name=$DUMP_INSTANCE_PROFILE" \
        "${pub[@]}" \
        --user-data "file://$ud" \
        --block-device-mappings "DeviceName=${root_dev},Ebs={VolumeSize=${root_gb},VolumeType=gp3,DeleteOnTermination=true}" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=firmware-dump-helper${DUMP_SLOT:+-$DUMP_SLOT}},{Key=Purpose,Value=${PURPOSE}},{Key=Role,Value=helper}]" \
        --query 'Instances[0].InstanceId' --output text)
  rm -f "$ud"
  echo "$id" > "$(helper_file)"
  aws ec2 wait instance-running --instance-ids "$id"
  log "helper $id running; waiting for SSM registration"
  wait_ssm_online "$id"
  log "helper $id online in SSM"
  echo "$id"
}

ensure_helper() {
  local id az
  if id=$(helper_id); then
    az=$(helper_az "$id")
    if [ -z "${PREFERRED_AZ:-}" ] || [ "$az" = "$PREFERRED_AZ" ]; then
      echo "$id"; return 0
    fi
    log "helper $id is in $az, want $PREFERRED_AZ; relaunching"
    terminate_slot_helper
  fi
  launch_helper
}

run_remote_read() {
  local hid="$1" snap="$2" key="$3" label="$4" cmd_file
  cmd_file=$(mktemp)
  jq -n --arg bucket "$DUMP_BUCKET" --arg snap "$snap" --arg key "$key" \
        --arg label "$label" --arg workers "$WORKERS" --arg region "${AWS_REGION}" '{
    DocumentName: "AWS-RunShellScript",
    TimeoutSeconds: 600,
    Parameters: { commands: [
      "set -euo pipefail",
      "aws s3 cp s3://\($bucket)/_scripts/snapshot_to_s3.sh /tmp/snapshot_to_s3.sh --only-show-errors",
      "aws s3 cp s3://\($bucket)/_scripts/ebs_snapshot_read.py /tmp/ebs_snapshot_read.py --only-show-errors",
      "chmod +x /tmp/snapshot_to_s3.sh",
      "rm -f /tmp/fw_read.log",
      "nohup /tmp/snapshot_to_s3.sh --snapshot-id \($snap) --s3-uri s3://\($bucket)/\($key) --label \($label) --region \($region) --workers \($workers) >/tmp/fw_nohup.log 2>&1 &"
    ]}
  }' > "$cmd_file"

  aws ssm send-command --instance-ids "$hid" --cli-input-json "file://$cmd_file" \
    --query 'Command.CommandId' --output text >/dev/null
  rm -f "$cmd_file"
}

# Wait for a terminal status. state=running is not completion.
await_status() {
  local label="$1" limit="$2"
  local body state deadline waited
  deadline=$((SECONDS + limit))
  waited=0
  while [ "$SECONDS" -lt "$deadline" ]; do
    if body=$(aws s3 cp "s3://${DUMP_BUCKET}/_status/${label}.json" - --only-show-errors 2>/dev/null); then
      state=$(jq -r '.state // ""' <<<"$body" 2>/dev/null || echo "")
      case "$state" in
        ok|error)
          echo "$body"
          return 0
          ;;
        running)
          if [ "$waited" -ge 60 ]; then
            log "  ... still reading snapshot ($label)"
            waited=0
          fi
          ;;
      esac
    fi
    sleep 15
    waited=$((waited + 15))
  done
  return 1
}

wait_snapshots() {
  local deadline pending bad
  deadline=$((SECONDS + 7200))
  while [ "$SECONDS" -lt "$deadline" ]; do
    bad=$(aws ec2 describe-snapshots --snapshot-ids "$@" \
      --query 'Snapshots[?State==`error`].SnapshotId' --output text)
    if [ -n "$bad" ] && [ "$bad" != "None" ]; then
      die "snapshot entered error state: $bad"
    fi
    pending=$(aws ec2 describe-snapshots --snapshot-ids "$@" \
      --query 'Snapshots[?State!=`completed`].SnapshotId' --output text)
    if [ -z "$pending" ] || [ "$pending" = "None" ]; then
      return 0
    fi
    log "  snapshots still pending: $pending"
    sleep 20
  done
  die "snapshots did not complete within 2h: $*"
}

untrack_snapshot() {
  local snap="$1" i
  for i in "${!TRACK_SNAPSHOTS[@]}"; do
    if [ "${TRACK_SNAPSHOTS[$i]}" = "$snap" ]; then
      TRACK_SNAPSHOTS[$i]=""
    fi
  done
}

download_local() {
  local label="$1" key="$2" want_sha="$3"
  local local_file="$DUMP_ROOT/artifacts/${label}.raw.zst" got
  mkdir -p "$DUMP_ROOT/artifacts"

  if [ -f "$local_file" ] && [ "$(sha256_file "$local_file")" = "$want_sha" ]; then
    log "local copy of $label already verified"
    return 0
  fi

  log "downloading s3://$DUMP_BUCKET/$key"
  aws s3 cp "s3://${DUMP_BUCKET}/${key}" "$local_file" --only-show-errors --no-progress

  got=$(sha256_file "$local_file")
  [ "$got" = "$want_sha" ] || die "sha256 mismatch for $label: expected=$want_sha got=$got"
  log "verified local copy: $local_file"
}

describe_source() {
  local ami="$1" src
  if ! src=$(aws ec2 describe-images --image-ids "$ami" --output json --query 'Images[0]' 2>/dev/null); then
    die "describe-images failed for $ami in $AWS_REGION (wrong region, or this account cannot see it)"
  fi
  [ "$src" != "null" ] && [ -n "$src" ] || die "AMI $ami not visible in $AWS_REGION"
  printf '%s\n' "$src"
}

# ---------------------------------------------------------------------------
# one image
# ---------------------------------------------------------------------------
fetch_one() {
  local label="$1" ami="$2" boot_override="${3:-}"
  local key="golden/${label}/${label}.raw.zst"
  local existing_sha existing_key src arch root_dev virt ena boot_mode name owner created codes
  local btype pub=()

  validate_label "$label"
  if [ "$ami" != "resume" ]; then
    validate_ami "$ami"
  fi

  if [ "$FORCE" -eq 0 ] && [ -z "$RESUME_SNAP" ]; then
    existing_sha=$(jq -r --arg l "$label" '.images[$l].sha256 // empty' "$MANIFEST")
    existing_key=$(jq -r --arg l "$label" '.images[$l].s3_key // empty' "$MANIFEST")
    if [ -n "$existing_sha" ] && [ -n "$existing_key" ] \
       && aws s3api head-object --bucket "$DUMP_BUCKET" --key "$existing_key" >/dev/null 2>&1; then
      log "SKIP $label (already in S3: s3://$DUMP_BUCKET/$existing_key)"
      [ "$DO_DOWNLOAD" -eq 1 ] && download_local "$label" "$existing_key" "$existing_sha"
      return 0
    fi
  fi

  if [ -n "$RESUME_SNAP" ]; then
    src='{}'
    arch="x86_64"
    root_dev="/dev/xvda"
    virt="hvm"
    ena="false"
    boot_mode=""
    name=""
    owner=""
    created=""
    codes='[]'
    log "=== $label (resume $RESUME_SNAP)"
  else
    src=$(describe_source "$ami")
    arch=$(jq -r '.Architecture // "x86_64"' <<<"$src")
    root_dev=$(jq -r '.RootDeviceName // "/dev/xvda"' <<<"$src")
    virt=$(jq -r '.VirtualizationType // "hvm"' <<<"$src")
    ena=$(jq -r '.EnaSupport // false' <<<"$src")
    boot_mode=$(jq -r '.BootMode // empty' <<<"$src")
    name=$(jq -r '.Name // empty' <<<"$src")
    owner=$(jq -r '.OwnerId // empty' <<<"$src")
    created=$(jq -r '.CreationDate // empty' <<<"$src")
    codes=$(jq -c '[.ProductCodes[]? | {id: .ProductCodeId, type: .ProductCodeType}]' <<<"$src")
    log "=== $label ($ami name=${name:-unknown} arch=$arch root=$root_dev)"
  fi

  if [ -n "$boot_override" ]; then
    btype="$boot_override"
  elif [ -n "$BOOT_TYPE" ]; then
    btype="$BOOT_TYPE"
  else
    btype=$(default_boot_type "$arch")
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    log "dry-run: would boot $btype from ${ami:-snapshot}, dwell ${DWELL}s, snapshot every EBS disk, EBS-direct read -> s3://$DUMP_BUCKET/$key"
    return 0
  fi

  aws s3 cp "$DUMP_ROOT/scripts/snapshot_to_s3.sh" \
    "s3://${DUMP_BUCKET}/_scripts/snapshot_to_s3.sh" --only-show-errors
  aws s3 cp "$DUMP_ROOT/scripts/ebs_snapshot_read.py" \
    "s3://${DUMP_BUCKET}/_scripts/ebs_snapshot_read.py" --only-show-errors

  local boot_instance=""
  local -a dev_names=() dev_snaps=()
  local disks_json='[]'
  mapfile -t pub < <(public_ip_args)

  if [ -n "$RESUME_SNAP" ]; then
    dev_names=("resume")
    dev_snaps=("$RESUME_SNAP")
    log "resuming from existing snapshot $RESUME_SNAP (boot skipped)"
  else
    log "launching $btype from $ami"
    if ! boot_instance=$(aws ec2 run-instances \
      --image-id "$ami" \
      --instance-type "$btype" \
      --subnet-id "$(subnet_for_az)" \
      --security-group-ids "$DUMP_SECURITY_GROUP" \
      "${pub[@]}" \
      --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=firmware-dump-boot-$label},{Key=Purpose,Value=${PURPOSE}},{Key=Role,Value=boot},{Key=Label,Value=$label}]" \
      --query 'Instances[0].InstanceId' --output text); then
      die "run-instances failed for $label. OptInRequired means accept that listing in the AWS console (scripts/probe.sh --ami $ami). Unsupported means the listing rejects $btype; pass --boot-type."
    fi
    log "boot instance $boot_instance"
    track_instance "$boot_instance"
    aws ec2 wait instance-running --instance-ids "$boot_instance"
    if [ "$DWELL" -gt 0 ]; then
      log "letting $label run for ${DWELL}s before snapshot"
      sleep "$DWELL"
    fi

    local inst_root
    inst_root=$(aws ec2 describe-instances --instance-ids "$boot_instance" \
      --query 'Reservations[0].Instances[0].RootDeviceName' --output text)
    [ -n "$inst_root" ] && [ "$inst_root" != "None" ] && root_dev="$inst_root"

    # Snapshot every EBS device, not just the root. Some images ship a small
    # root plus a data disk; capturing only the root drops the rest. Snapshots
    # must be taken before terminate, because DeleteOnTermination is commonly set.
    while IFS=$'\t' read -r dname dvol; do
      [ -n "$dname" ] && [ "$dname" != "None" ] || continue
      [ -n "$dvol" ] && [ "$dvol" != "None" ] || continue
      dev_names+=("$dname")
      dev_snaps+=("$dvol")
    done < <(aws ec2 describe-instances --instance-ids "$boot_instance" \
        --query 'Reservations[0].Instances[0].BlockDeviceMappings[].[DeviceName,Ebs.VolumeId]' \
        --output text)

    [ "${#dev_names[@]}" -gt 0 ] || die "no EBS devices found on $boot_instance"

    # Root first, so golden/<label>/<label>.raw.zst is the root disk.
    local -a ordered_names=() ordered_vols=()
    local i
    for i in "${!dev_names[@]}"; do
      if [ "${dev_names[$i]}" = "$root_dev" ]; then
        ordered_names+=("${dev_names[$i]}")
        ordered_vols+=("${dev_snaps[$i]}")
      fi
    done
    for i in "${!dev_names[@]}"; do
      if [ "${dev_names[$i]}" != "$root_dev" ]; then
        ordered_names+=("${dev_names[$i]}")
        ordered_vols+=("${dev_snaps[$i]}")
      fi
    done
    if [ "${ordered_names[0]}" != "$root_dev" ]; then
      warn "root device $root_dev not in block-device map; treating ${ordered_names[0]} as root"
    fi
    dev_names=("${ordered_names[@]}")
    dev_snaps=("${ordered_vols[@]}")
    log "devices on $boot_instance: ${dev_names[*]} (root ${dev_names[0]})"

    local keep_tag="false"
    [ "$KEEP_SNAPSHOT" -eq 1 ] && keep_tag="true"
    for i in "${!dev_snaps[@]}"; do
      local s
      s=$(aws ec2 create-snapshot --volume-id "${dev_snaps[$i]}" \
        --description "firmware-dump $label ${dev_names[$i]} ($ami)" \
        --tag-specifications "ResourceType=snapshot,Tags=[{Key=Name,Value=firmware-dump-$label},{Key=Purpose,Value=${PURPOSE}},{Key=Role,Value=snapshot},{Key=Label,Value=$label},{Key=Keep,Value=$keep_tag}]" \
        --query 'SnapshotId' --output text)
      track_snapshot "$s"
      dev_snaps[$i]="$s"
      log "  ${dev_names[$i]} snapshot $s"
    done

    log "terminating boot instance; waiting for ${#dev_snaps[@]} snapshot(s)"
    aws ec2 terminate-instances --instance-ids "$boot_instance" \
      --query 'TerminatingInstances[0].CurrentState.Name' --output text >/dev/null
    # Clear the track so the EXIT trap does not terminate an already-gone instance.
    untrack_instance "$boot_instance"
    wait_snapshots "${dev_snaps[@]}"
  fi

  if [ "$REGISTER_AMI" -eq 1 ]; then
    local ami_name reg_args mappings registered
    ami_name="firmware-dump-${label}-$(date -u +%Y%m%d)"
    reg_args=()
    log "registering launchable AMI $ami_name from ${#dev_snaps[@]} disk(s)"
    mappings=$(jq -n --argjson names "$(printf '%s\n' "${dev_names[@]}" | jq -R . | jq -s .)" \
      --argjson snaps "$(printf '%s\n' "${dev_snaps[@]}" | jq -R . | jq -s .)" \
      '[range(0; ($names|length)) | {DeviceName: $names[.], Ebs: {SnapshotId: $snaps[.], DeleteOnTermination: true}}]')
    reg_args=(
      --name "$ami_name"
      --description "firmware-dump $label (from $ami)"
      --architecture "$arch"
      --root-device-name "$root_dev"
      --virtualization-type "$virt"
      --block-device-mappings "$mappings"
      --tag-specifications "ResourceType=image,Tags=[{Key=Name,Value=$ami_name},{Key=Purpose,Value=${PURPOSE}},{Key=Role,Value=image},{Key=Label,Value=$label}]"
    )
    [ "$ena" = "true" ] && reg_args+=(--ena-support)
    [ -n "$boot_mode" ] && reg_args+=(--boot-mode "$boot_mode")
    registered=$(aws ec2 register-image "${reg_args[@]}" --query 'ImageId' --output text)
    log "registered $registered"
  fi

  PREFERRED_AZ=$(az_of_subnet "$(subnet_for_az)")
  local hid
  hid=$(ensure_helper)

  local idx
  for idx in "${!dev_snaps[@]}"; do
    local dname="${dev_names[$idx]}" snap="${dev_snaps[$idx]}"
    local dsafe dlabel dkey is_root
    dsafe=$(printf '%s' "$dname" | sed 's#^/dev/##; s#/#_#g')
    if [ "$idx" -eq 0 ]; then
      is_root=true
      dlabel="$label"
      dkey="golden/${label}/${label}.raw.zst"
    else
      is_root=false
      dlabel="${label}.${dsafe}"
      dkey="golden/${label}/${label}.${dsafe}.raw.zst"
    fi

    log "reading disk ${idx} (${dname}) via EBS direct APIs -> $dkey ($WORKERS workers)"
    aws s3 rm "s3://${DUMP_BUCKET}/_status/${dlabel}.json" --only-show-errors >/dev/null 2>&1 || true
    run_remote_read "$hid" "$snap" "$dkey" "$dlabel"

    local status
    if ! status=$(await_status "$dlabel" 10800); then
      die "snapshot read for $dlabel timed out; see s3://$DUMP_BUCKET/_logs/${dlabel}.log"
    fi
    if [ "$(jq -r '.state' <<<"$status")" != "ok" ]; then
      aws s3 cp "s3://${DUMP_BUCKET}/_logs/${dlabel}.log" - --only-show-errors >&2 || true
      die "snapshot read for $dlabel failed: $status"
    fi

    local remote_sha volume_bytes alloc_bytes obj_size disk_obj
    remote_sha=$(jq -r '.sha256' <<<"$status")
    volume_bytes=$(jq -r '.volume_bytes // 0' <<<"$status")
    alloc_bytes=$(jq -r '.allocated_bytes // 0' <<<"$status")
    obj_size=$(aws s3api head-object --bucket "$DUMP_BUCKET" --key "$dkey" --query 'ContentLength' --output text)
    aws s3api head-object --bucket "$DUMP_BUCKET" --key "${dkey}.sha256" >/dev/null \
      || die "checksum sidecar missing: s3://$DUMP_BUCKET/${dkey}.sha256"
    aws s3api head-object --bucket "$DUMP_BUCKET" --key "${dkey%.raw.zst}.stats.json" >/dev/null \
      || die "stats sidecar missing: s3://$DUMP_BUCKET/${dkey%.raw.zst}.stats.json"

    disk_obj=$(jq -n --arg dev "$dname" --arg snap "$snap" --arg key "$dkey" \
      --arg sha "$remote_sha" --argjson cbytes "$obj_size" \
      --argjson vbytes "$volume_bytes" --argjson abytes "$alloc_bytes" \
      --argjson root "$is_root" \
      '{device:$dev, snapshot:$snap, s3_key:$key, sha256:$sha,
        compressed_bytes:$cbytes, volume_bytes:$vbytes,
        allocated_bytes:$abytes, root:$root}')

    disks_json=$(jq -c --argjson d "$disk_obj" '. + [$d]' <<<"$disks_json")

    log "OK $dlabel -> s3://$DUMP_BUCKET/$dkey ($((obj_size / 1048576)) MiB compressed; $((alloc_bytes / 1048576)) MiB allocated of $((volume_bytes / 1073741824)) GiB)"

    if [ "$DO_DOWNLOAD" -eq 1 ]; then
      download_local "$dlabel" "$dkey" "$remote_sha"
    fi

    if [ "$KEEP_SNAPSHOT" -eq 0 ]; then
      if aws ec2 delete-snapshot --snapshot-id "$snap" >/dev/null 2>&1; then
        untrack_snapshot "$snap"
      else
        warn "could not delete $snap"
      fi
    fi
  done

  local root_key root_sha root_vb root_ab registered_ami
  root_key=$(jq -r '.[0].s3_key' <<<"$disks_json")
  root_sha=$(jq -r '.[0].sha256' <<<"$disks_json")
  root_vb=$(jq -r '.[0].volume_bytes' <<<"$disks_json")
  root_ab=$(jq -r '.[0].allocated_bytes' <<<"$disks_json")
  registered_ami="${registered:-}"

  manifest_apply \
    --arg l "$label" --arg ami "$ami" --arg name "$name" --arg owner "$owner" \
    --arg created "$created" --arg arch "$arch" --arg key "$root_key" --arg sha "$root_sha" \
    --argjson vbytes "$root_vb" --argjson abytes "$root_ab" \
    --arg ts "$(date -u +%FT%TZ)" --argjson codes "$codes" \
    --argjson disks "$disks_json" --arg reg "$registered_ami" --arg btype "$btype" \
    --argjson downloaded "$DO_DOWNLOAD" '
    .images[$l] = {
      ami: $ami,
      name: $name,
      owner: $owner,
      creation_date: $created,
      architecture: $arch,
      boot_type: $btype,
      product_codes: $codes,
      s3_key: $key,
      sha256: $sha,
      volume_bytes: $vbytes,
      allocated_bytes: $abytes,
      disks: $disks,
      registered_ami: (if $reg == "" then null else $reg end),
      fetched_utc: $ts,
      downloaded: ($downloaded == 1)
    }
  '
}

untrack_instance() {
  local id="$1" i
  for i in "${!TRACK_INSTANCES[@]}"; do
    if [ "${TRACK_INSTANCES[$i]}" = "$id" ]; then
      TRACK_INSTANCES[$i]=""
    fi
  done
}

# ---------------------------------------------------------------------------
# driver
# ---------------------------------------------------------------------------
PREFERRED_AZ=""

run_batch() {
  local file="$1" line lab ami btype
  [ -f "$file" ] || die "batch file not found: $file"
  local -a labels=() amis=() types=()
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    lab=""; ami=""; btype=""
    # shellcheck disable=SC2086
    read -r lab ami btype <<<"$line"
    [ -n "$lab" ] && [ -n "$ami" ] || die "batch line needs LABEL and AMI: $line"
    validate_label "$lab"
    validate_ami "$ami"
    labels+=("$lab")
    amis+=("$ami")
    types+=("$btype")
  done < "$file"
  [ "${#labels[@]}" -gt 0 ] || die "batch file has no images: $file"
  log "fetching ${#labels[@]} image(s), jobs=$JOBS"

  fetch_index() {
    local i="$1"
    fetch_one "${labels[$i]}" "${amis[$i]}" "${types[$i]}"
  }

  if [ "$JOBS" -le 1 ]; then
    local i
    for i in "${!labels[@]}"; do fetch_index "$i"; done
    return 0
  fi

  local workdir idx slot
  workdir=$(mktemp -d)
  idx=0
  for i in "${!labels[@]}"; do
    printf '%s\n' "$i" >> "$workdir/chunk.$((idx % JOBS))"
    idx=$((idx + 1))
  done
  local -a pids=()
  local rc=0 p
  for slot in $(seq 0 $((JOBS - 1))); do
    [ -f "$workdir/chunk.$slot" ] || continue
    (
      export DUMP_SLOT="$slot"
      while read -r i; do fetch_index "$i"; done < "$workdir/chunk.$slot"
    ) &
    pids+=($!)
  done
  for p in "${pids[@]}"; do wait "$p" || rc=$?; done
  rm -rf "$workdir"
  [ "$rc" -eq 0 ] || die "one or more workers failed (rc=$rc)"
}

if [ -n "$BATCH" ]; then
  run_batch "$BATCH"
else
  [ -n "$AMI" ] || die "--ami is required unless --batch"
  [ -n "$LABEL" ] || die "--label is required unless --batch"
  fetch_one "$LABEL" "$AMI"
fi

log "done"
