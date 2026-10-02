#!/bin/bash
# Bootstrap for the extraction helper (Amazon Linux 2023).
#
# The helper never attaches a volume. It reads snapshot content with the EBS
# direct APIs, so it only needs zstd, jq, and python3+boto3.
set -euxo pipefail

dnf install -y zstd jq amazon-ssm-agent python3 python3-pip || true

# boto3 into a dedicated venv; AL2023's system python is externally managed.
python3 -m venv /opt/fw-dump || true
/opt/fw-dump/bin/pip install --quiet --upgrade pip boto3 || \
  pip3 install --quiet --break-system-packages boto3 || true

systemctl enable --now amazon-ssm-agent || true
systemctl restart amazon-ssm-agent || true

/opt/fw-dump/bin/python3 -c 'import boto3; print("boto3", boto3.__version__)' || true
