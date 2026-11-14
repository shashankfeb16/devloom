#!/usr/bin/env bash
# Terraform uploads this script and a source archive; all secrets stay on the VPS.
set -Eeuo pipefail
umask 077

read_config() {
  python3 - "$1" <<'PY'
import json
import re
import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        data = json.load(stream)
    domain = data["domain"]
    email = data["acme_email"]
    port = data["ssh_port"]
    release_id = data["release_id"]
    label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
    if not isinstance(domain, str) or len(domain) > 253 or not re.fullmatch(rf"{label}(?:\.{label})+", domain):
        raise ValueError("domain must be a lowercase DNS hostname without a scheme or path")
    if not isinstance(email, str) or not re.fullmatch(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}", email):
        raise ValueError("acme_email must be a normal email address without whitespace")
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError("ssh_port must be an integer from 1 to 65535")
    if not isinstance(release_id, str) or not re.fullmatch(r"[0-9a-f]{16,64}", release_id):
        raise ValueError("release_id must contain 16–64 lowercase hexadecimal characters")
    print(domain, email, port, release_id, sep="\n")
except (OSError, ValueError, TypeError, KeyError) as exc:
    sys.exit(f"Invalid deployment configuration: {exc}")
PY
}

if [[ ${1:-} == --check-config ]]; then
  read_config "${2:?Expected deploy-config.json path}" >/dev/null
  echo "Deployment configuration is valid."
  exit 0
fi

stage=${1:?Expected the Terraform upload directory}
if [[ $EUID -ne 0 ]]; then
  echo "Run remote-deploy.sh as root or through passwordless sudo." >&2
  exit 1
fi
if ! command -v python3 >/dev/null; then
  echo "Use the standard Ubuntu 24.04 image with Python 3 installed." >&2
  exit 1
fi

config_values=$(read_config "$stage/deploy-config.json")
mapfile -t config <<< "$config_values"
domain=${config[0]}
ssh_port=${config[2]}
release_id=${config[3]}

app_root=/opt/devloom
shared=$app_root/shared
release=$app_root/releases/$release_id
env_file=$shared/app.env
install -m 0700 -d "$app_root" "$shared" "$app_root/releases" "$shared/backups"

# Serialize deployments from different Terraform workspaces or computers, too.
exec 9>"$shared/deploy.lock"
if ! flock -n 9; then
  echo "Another Devloom deployment is in progress. Retry after it finishes." >&2
  exit 1
fi

bash "$stage/bootstrap.sh" "$ssh_port"

if [[ ! -d $release ]]; then
  # Validate every member before extracting as root. Symlinks, devices and path
  # traversal are rejected; failed extraction never becomes an existing release.
  python3 - "$stage/source.tar.gz" "$release" <<'PY'
import os
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile
import tempfile

destination = Path(sys.argv[2])
temporary = Path(tempfile.mkdtemp(prefix=f".{destination.name}-", dir=destination.parent))
try:
    with tarfile.open(sys.argv[1], "r:gz") as archive:
        for member in archive.getmembers():
            path = PurePosixPath(member.name)
            if path.is_absolute() or ".." in path.parts or not (member.isfile() or member.isdir()):
                raise ValueError(f"Unsafe archive member: {member.name!r}")
        archive.extractall(temporary, filter="data")
    required = ("Dockerfile.production", "compose.production.yaml", "docker/Caddyfile", "mix.exs", "mix.lock")
    for filename in required:
        if not (temporary / filename).is_file():
            raise ValueError(f"Required production file missing from archive: {filename}")
    os.rename(temporary, destination)
except BaseException:
    shutil.rmtree(temporary, ignore_errors=True)
    raise
PY
fi

# An existing database without its credentials requires recovery, not new secrets.
if [[ ! -f $env_file ]] && docker volume inspect devloom-production_pgdata >/dev/null 2>&1; then
  echo "The PostgreSQL volume exists but shared/app.env is missing. Restore its credentials from backup before deploying." >&2
  exit 1
fi

# Generate once, retain across every apply, and update only public configuration.
# Values are data, never sourced/evaluated as shell code. Passwords use URL-safe hex.
python3 - "$stage/deploy-config.json" "$env_file" <<'PY'
import json
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile

config = json.loads(Path(sys.argv[1]).read_text())
path = Path(sys.argv[2])
values = {}
if path.exists():
    for line in path.read_text().splitlines():
        if line and not line.startswith("#"):
            key, separator, value = line.partition("=")
            if not separator or key in values:
                sys.exit("Existing app.env is malformed; restore it before deploying.")
            values[key] = value
    for key, length in (("POSTGRES_PASSWORD", 64), ("SECRET_KEY_BASE", 128)):
        if not re.fullmatch(rf"[0-9a-f]{{{length}}}", values.get(key, "")):
            sys.exit(f"Existing {key} is missing or changed format. Do not regenerate production credentials automatically.")
else:
    values["POSTGRES_PASSWORD"] = secrets.token_hex(32)
    values["SECRET_KEY_BASE"] = secrets.token_hex(64)

values.update({
    "POSTGRES_USER": "devloom",
    "POSTGRES_DB": "devloom_prod",
    "DATABASE_URL": f"ecto://devloom:{values['POSTGRES_PASSWORD']}@db/devloom_prod",
    "PHX_HOST": config["domain"],
    "DEVLOOM_DOMAIN": config["domain"],
    "ACME_EMAIL": config["acme_email"],
    "PHX_SERVER": "true",
    "PORT": "4000",
    "POOL_SIZE": "10",
})
descriptor, temporary = tempfile.mkstemp(prefix=".app.env-", dir=path.parent)
try:
    with os.fdopen(descriptor, "w") as stream:
        os.fchmod(stream.fileno(), 0o600)
        stream.write("# Generated on the VPS. Preserve this file and keep it private.\n")
        for key, value in values.items():
            stream.write(f"{key}={value}\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PY

export DEVLOOM_ENV_FILE=$env_file
export DEVLOOM_SOURCE_DIR=$release
export DEVLOOM_CADDYFILE=$release/docker/Caddyfile
export RELEASE_ID=$release_id

compose() {
  docker compose --project-name devloom-production --env-file "$env_file" \
    -f "$release/compose.production.yaml" "$@"
}

# Builds do not stop the current web container. A failed build leaves it serving.
compose config --quiet
compose build web
compose up -d --wait --wait-timeout 180 db

backup="$shared/backups/$(date -u +%Y%m%dT%H%M%S)-${release_id:0:16}-$(date +%N).dump"
if compose exec -T db sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' > "$backup.tmp"; then
  mv "$backup.tmp" "$backup"
else
  rm -f "$backup.tmp"
  echo "Database backup failed; migration has not been run." >&2
  exit 1
fi

compose run --rm --no-deps web bin/devloom eval 'Devloom.Release.migrate()'
compose up -d --wait --wait-timeout 180 db web
# Force recreation because a release uses a new Caddyfile bind-mount path.
compose up -d --no-deps --force-recreate caddy

# Verify this VPS with the real certificate, then verify the public DNS route.
# No --insecure: TLS validation must pass before declaring deployment successful.
timeout 360 curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
  --retry 60 --retry-delay 5 --retry-all-errors \
  --resolve "$domain:443:127.0.0.1" "https://$domain/health" >/dev/null
timeout 120 curl --fail --silent --show-error --connect-timeout 5 --max-time 10 \
  --retry 20 --retry-delay 5 --retry-all-errors "https://$domain/health" >/dev/null

ln -sfn "$release" "$app_root/current.next"
mv -Tf "$app_root/current.next" "$app_root/current"
echo "Devloom deployment succeeded: https://$domain"
echo "Database backup saved on the VPS: $backup"
