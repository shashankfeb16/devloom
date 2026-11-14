#!/usr/bin/env bash
set -Eeuo pipefail

if [[ $(id -u) == 0 ]]; then
  chmod 1777 /tmp
  mkdir -p /home/jenkins/agent /tmp/devloom-ci /var/lib/devloom-terraform
  chown jenkins:jenkins /home/jenkins/agent /tmp/devloom-ci /var/lib/devloom-terraform
  chmod 0700 /tmp/devloom-ci /var/lib/devloom-terraform
  exec setpriv --reuid=jenkins --regid=jenkins --init-groups "$0" "$@"
fi

for attempt in {1..120}; do
  if [[ -s /run/devloom-agent/secret ]] && docker info >/dev/null 2>&1; then
    # Remoting reads @file, so the secret itself does not appear in argv.
    exec /usr/local/bin/jenkins-agent -secret @/run/devloom-agent/secret "$@"
  fi
  sleep 1
done

echo 'Agent startup timed out waiting for its secret and Docker daemon.' >&2
exit 1
