#!/usr/bin/env bash
# configure.sh — export provisioned AWS resources into .env / .azs.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

require() { command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
require terraform
require jq

tf=$(terraform -chdir=terraform output -json)

jq -r '.dump_env.value' <<<"$tf" > .env
jq -r '.subnet_azs.value | to_entries[] | "\(.key) \(.value)"' <<<"$tf" \
  | jq -Rn '[inputs | split(" ") | {key: .[0], value: .[1]}] | from_entries' > .azs
chmod 600 .env .azs

echo "wrote .env:"
cat .env
echo "wrote .azs:"
cat .azs
