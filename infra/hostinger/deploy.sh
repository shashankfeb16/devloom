#!/usr/bin/env bash
# Run from any directory after filling in terraform.tfvars.
set -Eeuo pipefail
module_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for executable in terraform python3; do
  if ! command -v "$executable" >/dev/null; then
    echo "Install $executable first. See docs/hostinger-vps.md." >&2
    exit 1
  fi
done
if [[ ! -f $module_dir/terraform.tfvars ]]; then
  echo "Copy infra/hostinger/terraform.tfvars.example to terraform.tfvars, then follow docs/hostinger-vps.md." >&2
  exit 1
fi
terraform -chdir="$module_dir" init -input=false
terraform -chdir="$module_dir" validate
terraform -chdir="$module_dir" apply "$@"
