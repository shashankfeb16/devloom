#!/usr/bin/env bash
# This helper manages only the devloom-jenkins Compose project.
set -Eeuo pipefail
runtime_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
env_file="$runtime_dir/.env"
action=${1:-help}
if [[ $# -gt 0 ]]; then shift; fi

case "$action" in
  init)
    if [[ -e $env_file ]]; then
      echo "Keeping existing $env_file (credentials unchanged)."
      exit 0
    fi
    command -v openssl >/dev/null || { echo 'Install OpenSSL first.' >&2; exit 1; }
    umask 077
    password=$(openssl rand -hex 24)
    # noclobber also protects against a concurrent init overwriting credentials.
    (set -o noclobber; printf 'JENKINS_ADMIN_USER=admin\nJENKINS_ADMIN_PASSWORD=%s\nJENKINS_PORT=8080\n' "$password" > "$env_file")
    echo "Created $env_file with mode 600. Open this file locally for your login."
    ;;
  up|down|logs|status|doctor|config)
    [[ -f $env_file ]] || { echo "Run bash infra/jenkins/runtime/jenkins.sh init first." >&2; exit 1; }
    command -v docker >/dev/null || { echo 'Install and start Docker Desktop first.' >&2; exit 1; }
    compose=(docker compose --env-file "$env_file" -f "$runtime_dir/compose.yaml")
    case "$action" in
      up) "${compose[@]}" up -d --build --wait --wait-timeout 420 "$@" ;;
      down)
        # Do not accept arbitrary flags: in particular, never remove CI state.
        [[ $# == 0 ]] || { echo 'down accepts no extra flags and preserves volumes.' >&2; exit 1; }
        "${compose[@]}" down
        ;;
      logs) "${compose[@]}" logs --tail 100 "$@" ;;
      status) "${compose[@]}" ps ;;
      config) "${compose[@]}" config --quiet ;;
      doctor)
        "${compose[@]}" exec -T --user jenkins agent bash -lc 'set -e; docker version; docker compose version; node --version; python3 --version; terraform version; test -w /home/jenkins/agent; test -w /var/lib/devloom-terraform; echo "Agent tools and persistent directories are ready."'
        probe="/tmp/devloom-ci/.shared-check-$$"
        "${compose[@]}" exec -T --user jenkins agent sh -c 'printf ready > "$1"' sh "$probe"
        if ! "${compose[@]}" exec -T docker test -s "$probe"; then
          "${compose[@]}" exec -T --user jenkins agent rm -f "$probe"
          echo 'The CI engine cannot see the agent temporary files. Recreate the services with up.' >&2
          exit 1
        fi
        "${compose[@]}" exec -T --user jenkins agent rm -f "$probe"
        echo 'Shared temporary files are visible to the CI Docker engine.'
        ;;
    esac
    ;;
  *)
    echo 'Usage: bash infra/jenkins/runtime/jenkins.sh {init|up|status|doctor|logs|down|config}'
    [[ $action == help ]] || exit 1
    ;;
esac
