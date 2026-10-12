#!/bin/bash
# Bootstrap for the extraction helper (Amazon Linux 2023).
#
# The helper never attaches a volume. It reads snapshot content with the EBS
# direct APIs, so it only needs zstd, jq, and python3+boto3.
set -euxo pipefail

# Same lock as snapshot_to_s3.sh. SSM can start that script while this is
# still in dnf; a second transaction corrupts the package cache.
flock /var/run/fw-dnf.lock bash -c '
  set -e
  dnf install -y zstd jq amazon-ssm-agent python3 python3-pip
  python3 -m venv /opt/fw-dump
  /opt/fw-dump/bin/pip install --quiet --upgrade pip boto3
' || true

systemctl enable --now amazon-ssm-agent || true
systemctl restart amazon-ssm-agent || true

/opt/fw-dump/bin/python3 -c 'import boto3; print("boto3", boto3.__version__)' || true
