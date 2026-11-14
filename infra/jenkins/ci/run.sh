#!/usr/bin/env bash
# The Jenkinsfile and manual local checks use these same commands.
set -Eeuo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$root"

# Jenkins supplies a stable value across stages. A manual invocation can set it
# explicitly when running stages separately; `all` generates one automatically.
export CI_PROJECT_NAME=${CI_PROJECT_NAME:-devloom-ci-local-$$}
if [[ ! $CI_PROJECT_NAME =~ ^devloom-ci-[a-z0-9][a-z0-9-]{0,47}$ ]]; then
  echo "CI_PROJECT_NAME must start devloom-ci- and contain 1-48 lowercase letters, digits, or hyphens after it." >&2
  exit 2
fi

compose() {
  docker compose --project-name "$CI_PROJECT_NAME" \
    -f "$root/infra/jenkins/ci/compose.ci.yaml" "$@"
}

prepare() {
  docker build --file infra/jenkins/ci/Dockerfile.ci \
    --tag "devloom-ci:$CI_PROJECT_NAME" .
}

check() {
  compose run --rm --no-deps test sh -ec '
    mix format --check-formatted
    mix deps.unlock --check-unused
    mix compile --warnings-as-errors --all-warnings
  '
}

test_elixir() {
  compose up --detach --wait --wait-timeout 120 db
  compose run --rm --no-deps test mix test
}

precommit() {
  compose up --detach --wait --wait-timeout 120 db
  # This alias may format files, but only inside this disposable container.
  compose run --rm --no-deps test mix precommit
}

javascript() {
  node --test test/js/*_test.mjs
}

infra() (
  export PYTHONDONTWRITEBYTECODE=1
  python3 -m unittest discover -s infra/hostinger/tests -p 'test_*.py'
  python3 -m unittest discover -s infra/jenkins/ci/tests -p 'test_*.py'
  python3 -m unittest discover -s infra/jenkins/tests -p 'test_*.py'
  local_module=$(mktemp -d "${TMPDIR:-/tmp}/devloom-ci-terraform.XXXXXX")
  trap 'rm -rf -- "$local_module"' EXIT
  mkdir "$local_module/scripts" "$local_module/tests"
  cp infra/hostinger/*.tf "$local_module/"
  cp infra/hostinger/scripts/package.py infra/hostinger/scripts/bootstrap.sh \
    infra/hostinger/scripts/remote-deploy.sh "$local_module/scripts/"
  cp infra/hostinger/tests/*.tftest.hcl "$local_module/tests/"
  export TF_DATA_DIR=$local_module/.terraform
  export TF_IN_AUTOMATION=1
  # Copy only source: never load a developer's tfvars or live VPS state.
  # All existing Terraform test cases are plan-only and cannot deploy.
  terraform -chdir="$local_module" fmt -check
  terraform -chdir="$local_module" init -backend=false -input=false
  terraform -chdir="$local_module" validate
  terraform -chdir="$local_module" test -var="source_directory=$root"
)

build() {
  docker build --file Dockerfile.production \
    --tag "devloom-production:$CI_PROJECT_NAME" .
}

smoke() {
  # The Jenkins agent shares the DinD network namespace and these filesystem
  # paths, so the existing loopback-only production smoke test works unchanged.
  DEVLOOM_SMOKE_TAG=$CI_PROJECT_NAME python3 infra/hostinger/tests/smoke.py
}

cleanup() {
  compose down --volumes --remove-orphans
  for image in "devloom-ci:$CI_PROJECT_NAME" "devloom-production:$CI_PROJECT_NAME"; do
    if docker image inspect "$image" >/dev/null 2>&1; then
      docker image rm "$image"
    fi
  done
}

case ${1:-all} in
  prepare) prepare ;;
  check) check ;;
  test) test_elixir ;;
  precommit) precommit ;;
  javascript) javascript ;;
  infra) infra ;;
  build) build ;;
  smoke) smoke ;;
  cleanup) cleanup ;;
  all)
    trap cleanup EXIT
    prepare
    check
    test_elixir
    javascript
    infra
    build
    smoke
    ;;
  *)
    echo "Usage: $0 [prepare|check|test|precommit|javascript|infra|build|smoke|cleanup|all]" >&2
    exit 2
    ;;
esac
