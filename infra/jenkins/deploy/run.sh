#!/usr/bin/env bash
# Invoked only after CI succeeds; Terraform owns the existing SSH deployment.
set -Eeuo pipefail
umask 077

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
source_module="$root/infra/hostinger"
private="$root/.jenkins-deploy"
module="$private/module"
action=${1:-}

if [[ $action == cleanup ]]; then
  rm -rf -- "$private"
  exit 0
fi
if [[ $action != plan && $action != apply ]]; then
  echo 'Usage: bash infra/jenkins/deploy/run.sh plan|apply|cleanup' >&2
  exit 2
fi
for executable in terraform python3; do
  command -v "$executable" >/dev/null || { echo "Missing $executable" >&2; exit 1; }
done
: "${SSH_AUTH_SOCK:?Use the Jenkins devloom-vps-ssh SSH Agent credential}"
: "${DEVLOOM_DEPLOY_CONFIG:?Bind the devloom-production-config secret-file credential}"
: "${CI_REVISION:?Set CI_REVISION to the tested Git commit}"
state_dir=${DEVLOOM_TF_STATE_DIR:-/var/lib/devloom-terraform/production}
mkdir -p -- "$private" "$state_dir"
chmod 700 "$private" "$state_dir"
export TF_DATA_DIR="$private/terraform-data" TF_IN_AUTOMATION=1 TF_INPUT=0
export CHECKOUT_ROOT="$root" DEPLOY_PRIVATE="$private" STATE_DIRECTORY="$state_dir" SOURCE_MODULE="$source_module"

if [[ $action == plan ]]; then
  # Never let a credential select another checkout, private key, or state location.
  python3 - <<'PY'
import json
import os
from pathlib import Path
import shutil

config = json.loads(Path(os.environ['DEVLOOM_DEPLOY_CONFIG']).read_text())
allowed = {'deploy_enabled', 'vps_host', 'ssh_user', 'ssh_port', 'ssh_host_key',
           'domain', 'acme_email', 'deployment_revision'}
if set(config) - allowed:
    raise SystemExit('Production config contains unsupported settings.')
if config.get('deploy_enabled') is not True:
    raise SystemExit('Production config must explicitly set deploy_enabled=true.')
if not all(config.get(key) for key in ('vps_host', 'ssh_host_key', 'domain', 'acme_email')):
    raise SystemExit('Production config must include a VPS IP, verified host key, domain and email.')
config.update(source_directory=os.environ['CHECKOUT_ROOT'], ssh_private_key_path=None)
private = Path(os.environ['DEPLOY_PRIVATE'])
(private / 'production.tfvars.json').write_text(json.dumps(config))
# Stage only versioned module inputs, never local .tfvars or a second state file.
module = private / 'module'
module.mkdir(exist_ok=True)
source = Path(os.environ['SOURCE_MODULE'])
for item in source.glob('*.tf'):
    shutil.copy2(item, module / item.name)
shutil.copytree(source / 'scripts', module / 'scripts', dirs_exist_ok=True)
(module / 'backend_override.tf.json').write_text(json.dumps({
    'terraform': {'backend': {'local': {
        'path': str(Path(os.environ['STATE_DIRECTORY']) / 'terraform.tfstate')
    }}}
}))
# A state directory belongs to exactly one deployment target. Changing servers
# requires a deliberately chosen new state directory, never silently reusing one.
identity = json.dumps({'vps_host': config['vps_host']}, sort_keys=True)
marker = Path(os.environ['STATE_DIRECTORY']) / 'target.json'
if marker.exists() and marker.read_text() != identity:
    raise SystemExit('Persistent state belongs to a different target. Review the state migration first.')
(private / 'target.json').write_text(identity)
PY
  # Refuse a second state history when this checkout already has local state.
  if [[ -f $source_module/terraform.tfstate && ! -f $state_dir/terraform.tfstate ]]; then
    echo 'Existing Terraform state found in infra/hostinger. Migrate it to the durable Jenkins volume first; see docs/jenkins.md.' >&2
    exit 1
  fi
  terraform -chdir="$module" init -input=false
  terraform -chdir="$module" validate
  terraform -chdir="$module" plan -input=false -lock-timeout=60s \
    -var-file="$private/production.tfvars.json" -out="$private/production.tfplan"
  cp -- "$private/target.json" "$state_dir/target.json"
  printf '%s\n' "$CI_REVISION" > "$private/revision"
  echo 'Review the Terraform plan above. The next Jenkins step requires approval.'
else
  [[ -f $private/production.tfplan && -f $private/revision ]] || { echo 'Create a plan before applying.' >&2; exit 1; }
  [[ $(cat "$private/revision") == "$CI_REVISION" ]] || { echo 'The tested commit differs from the planned commit.' >&2; exit 1; }
  terraform -chdir="$module" apply -input=false -lock-timeout=60s "$private/production.tfplan"
fi
