#!/usr/bin/env python3
"""Exercise the production stack locally with isolated volumes and local TLS.

Requires Docker Compose >=2.24.4 and an already built production image:
  docker build -f Dockerfile.production -t devloom-production:verification .
  python3 infra/hostinger/tests/smoke.py
Never invokes Terraform, SSH, Hostinger, UFW, or public certificate issuance.
"""
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import time


def run(*args, capture=False, check=True):
    return subprocess.run(args, check=check, text=True, stdout=subprocess.PIPE if capture else None)


def free_port():
    with socket.socket() as connection:
        connection.bind(("127.0.0.1", 0))
        return connection.getsockname()[1]


def main():
    root = Path(__file__).resolve().parents[3]
    project = "devloom-smoke-" + secrets.token_hex(4)
    http_port, https_port = free_port(), free_port()
    with tempfile.TemporaryDirectory(prefix="devloom-smoke-") as temporary:
        temp = Path(temporary)
        password = secrets.token_hex(32)
        env_file = temp / "app.env"
        env_file.write_text("\n".join([
            "POSTGRES_USER=devloom", "POSTGRES_DB=devloom_prod",
            f"POSTGRES_PASSWORD={password}", f"DATABASE_URL=ecto://devloom:{password}@db/devloom_prod",
            "SECRET_KEY_BASE=" + secrets.token_hex(64), "PHX_HOST=localhost",
            "DEVLOOM_DOMAIN=localhost", "ACME_EMAIL=test@example.com", "PHX_SERVER=true", "PORT=4000",
            "ERL_AFLAGS=" + os.environ.get("DEVLOOM_SMOKE_ERL_AFLAGS", ""), ""
        ]))
        env_file.chmod(0o600)
        caddyfile = temp / "Caddyfile"
        caddyfile.write_text("localhost {\n\ttls internal\n\treverse_proxy web:4000\n}\n")
        override = temp / "override.yaml"
        override.write_text(f"""services:
  caddy:
    ports: !override
      - '127.0.0.1:{http_port}:80'
      - '127.0.0.1:{https_port}:443'
volumes:
  pgdata:
    name: {project}_pgdata
  caddy_data:
    name: {project}_caddy_data
  caddy_config:
    name: {project}_caddy_config
""")
        os.environ.update(DEVLOOM_ENV_FILE=str(env_file), DEVLOOM_SOURCE_DIR=str(root),
                          DEVLOOM_CADDYFILE=str(caddyfile), RELEASE_ID=os.environ.get("DEVLOOM_SMOKE_TAG", "verification"))
        command = ["docker", "compose", "-p", project, "--env-file", str(env_file),
                   "-f", str(root / "compose.production.yaml"), "-f", str(override)]

        def compose(*args, **kwargs):
            return run(*command, *args, **kwargs)

        def sql(query):
            return compose("exec", "-T", "db", "psql", "-U", "devloom", "-d", "devloom_prod", "-Atc", query, capture=True).stdout.strip()

        try:
            configuration = json.loads(compose("config", "--format", "json", capture=True).stdout)
            assert not configuration["services"]["db"].get("ports"), "DB must not be published"
            assert not configuration["services"]["web"].get("ports"), "App must not be published"
            assert all(value["name"].startswith(project) for value in configuration["volumes"].values())
            compose("up", "-d", "--wait", "--wait-timeout", "180", "db")
            migrate = ("run", "--rm", "--no-deps", "web", "bin/devloom", "eval", "Devloom.Release.migrate()")
            compose(*migrate)
            migrations = sql("SELECT count(*) FROM schema_migrations")
            assert int(migrations) > 0
            compose(*migrate)
            assert sql("SELECT count(*) FROM schema_migrations") == migrations
            compose("up", "-d", "--no-build", "--wait", "--wait-timeout", "180", "db", "web", "caddy")
            compose("exec", "-T", "web", "curl", "--fail", "--silent", "http://localhost:4000/health")
            assert compose("exec", "-T", "web", "id", "-u", capture=True).stdout.strip() != "0"
            ca = temp / "root.crt"
            for attempt in range(30):
                result = compose("cp", "caddy:/data/caddy/pki/authorities/local/root.crt", str(ca), check=False, capture=True)
                if result.returncode == 0:
                    break
                time.sleep(1)
            assert ca.is_file(), "Local Caddy CA was not created"
            health = run("curl", "--fail", "--silent", "--show-error", "--max-time", "10", "--retry", "10",
                         "--retry-all-errors", "--retry-delay", "1", "--cacert", str(ca),
                         f"https://localhost:{https_port}/health", capture=True).stdout
            assert json.loads(health)["status"] == "ok", health
            headers = run("curl", "--silent", "--max-time", "10", "-I", f"http://localhost:{http_port}/health", capture=True).stdout
            assert "308" in headers and "https://" in headers, headers
            run("curl", "--fail", "--silent", "--output", os.devnull, "--cacert", str(ca), f"https://localhost:{https_port}/assets/js/app.js")
            sql("CREATE TABLE deploy_smoke (value text); INSERT INTO deploy_smoke VALUES ('persisted')")
            compose("restart", "db")
            compose("up", "-d", "--wait", "--wait-timeout", "180", "db", "web")
            assert sql("SELECT value FROM deploy_smoke") == "persisted"
            compose("stop", "web", "caddy")
            dump = temp / "backup.dump"
            with dump.open("wb") as backup:
                subprocess.run([*command, "exec", "-T", "db", "pg_dump", "-U", "devloom", "-d", "devloom_prod", "-Fc"], stdout=backup, check=True)
            sql("CREATE TABLE newer_than_backup (value text)")
            compose("exec", "-T", "db", "dropdb", "--force", "-U", "devloom", "devloom_prod")
            compose("exec", "-T", "db", "createdb", "-U", "devloom", "-O", "devloom", "devloom_prod")
            with dump.open("rb") as backup:
                subprocess.run([*command, "exec", "-T", "db", "pg_restore", "--no-owner", "--exit-on-error", "-U", "devloom", "-d", "devloom_prod"], stdin=backup, check=True)
            assert sql("SELECT value FROM deploy_smoke") == "persisted"
            assert sql("SELECT to_regclass('public.newer_than_backup') IS NULL") == "t"
            compose("up", "-d", "--wait", "--wait-timeout", "180", "db", "web")
            print(f"PASS: {migrations} migrations, repeat migration, health, HTTPS, redirect, static assets, nonroot runtime, private ports, database persistence and backup/restore.")
        finally:
            compose("down", "--volumes", "--remove-orphans")


if __name__ == "__main__":
    main()
