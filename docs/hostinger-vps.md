# Deploy Devloom to a Hostinger VPS

This setup takes an **existing, dedicated Ubuntu 24.04 VPS** and installs Devloom with PostgreSQL, Docker Compose, and automatic HTTPS. You fill in a small Terraform configuration, review `terraform plan`, and run `terraform apply`.

You can validate the configuration now without a VPS, SSH key, domain, or Hostinger API token. Deployment is disabled by default.

Terraform here configures a server over SSH. It does **not** buy a VPS, register a domain, create DNS records, or configure Hostinger's external firewall. Complete those initial account/network steps when you purchase your services. After that, the server software and application deployment are automated.

## What gets installed

| Component | Purpose |
| --- | --- |
| Docker Engine and Compose | Build and run the application services; start Docker at boot |
| Production Elixir release | Compiled Phoenix application, including built and digested assets |
| PostgreSQL 17 | Persistent application database, with no published database port |
| Caddy | Public HTTP/HTTPS, automatic TLS certificates, and LiveView WebSocket proxying |
| UFW rules | Permit the configured SSH port and TCP ports 80/443 |
| Server-side secrets | Generated once, stored in a root-only file, and reused on later deployments |
| Pre-migration backups | A PostgreSQL custom-format dump before each deployment's migrations |

The existing development `Dockerfile` and `compose.yaml` are separate from this production setup. Production publishes only Caddy's ports 80 and 443; Phoenix and PostgreSQL remain on the Docker network. Docker-published ports bypass UFW, so keep the production Compose port mappings this way.

## 1. What you can do now

Install [Terraform CLI](https://developer.hashicorp.com/terraform/install), version **1.10 or newer, below 2.0**, plus Python 3 and an OpenSSH client. The commands below assume macOS, Linux, or a Linux shell in WSL. You do not need Docker installed locally to deploy: the image builds on the VPS.

From your Devloom checkout:

```bash
cd infra/hostinger
cp terraform.tfvars.example terraform.tfvars
chmod 600 terraform.tfvars
terraform init
terraform fmt -check
terraform validate
terraform test
terraform plan
```

Keep `deploy_enabled = false`. The plan then makes no SSH connection and does not change any server. Example IP/domain values are safe in this mode. The Terraform configuration uses Terraform's built-in `terraform_data` resource and needs no Hostinger provider or API token.

Do not run an enabled apply with placeholder values. Preconditions reject missing required values, the documented example IP ranges, and example/reserved domains.

## 2. Buy and prepare the services later

### VPS

Choose a **clean Ubuntu 24.04 VPS** dedicated to Devloom. The bootstrap rejects other operating-system versions. A machine with 2 vCPUs and 4 GB RAM is a practical starting estimate for compiling the application and running a small instance; capacity has not been load-tested. Build memory and your eventual number of active users determine the size you need.

Record its public IPv4 address and SSH port. The default SSH user is `root`; a different user must already have passwordless sudo. If you use a custom SSH port, configure SSH to listen on that port before deployment. Setting Terraform's `ssh_port` changes how Terraform connects and the UFW allowance; it does not change the SSH daemon configuration.

If Hostinger's VPS firewall is enabled, allow inbound TCP:

- Your actual SSH port, preferably restricted to your administrative IP when practical.
- Port 80 from the internet, for HTTP redirects and certificate validation.
- Port 443 from the internet, for HTTPS and certificate validation.

The script configures UFW inside the VPS, but cannot change a firewall outside the machine. Outbound DNS/HTTPS and package-registry access must work. Ports 80/443 must be free: use a clean server without another web server or control-panel stack already claiming them.

### SSH login key

On your own computer, create a dedicated SSH key with a passphrase:

```bash
ssh-keygen -t ed25519 -a 100 -f ~/.ssh/devloom_vps
cat ~/.ssh/devloom_vps.pub
```

Keep `~/.ssh/devloom_vps` private. Install only the `.pub` file's single-line public key on the VPS using Hostinger's SSH key facility or the Hostinger browser console. For a root login, it belongs in `/root/.ssh/authorized_keys`, with `/root/.ssh` mode `700` and `authorized_keys` mode `600`.

Load the private key into your local SSH agent:

```bash
ssh-add ~/.ssh/devloom_vps
ssh-add -l
```

If no agent is running, start one in the same terminal first with `eval "$(ssh-agent -s)"`. Keep `ssh_private_key_path = null` in Terraform to use the agent. This supports a passphrase-protected key without putting a private key or passphrase into Terraform variables. Run Terraform from this same terminal so it inherits the agent connection.

Alternatively, `ssh_private_key_path` can point to an **unencrypted** private key file. Agent authentication with a passphrase-protected key is recommended. Never paste private key contents into `terraform.tfvars`.

### Verify the server's SSH identity

In the trusted **Hostinger browser console**, run:

```bash
cat /etc/ssh/ssh_host_ed25519_key.pub
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Save the public key line beginning `ssh-ed25519 AAAA...` as Terraform's `ssh_host_key`. This is the **server's public host key**, not your login `.pub` key, not the private host key, and not the `SHA256:...` fingerprint. The fingerprint is useful for independently checking the first interactive SSH connection.

Confirm that your local login works, replacing the address and port:

```bash
ssh -p 22 root@YOUR_VPS_IPV4
```

Compare the displayed host-key fingerprint with the one obtained through the Hostinger console before accepting it. Terraform explicitly verifies the supplied host key instead of silently trusting an unknown server. If you reinstall the VPS, verify its new host key through the console and update Terraform.

### Domain and DNS

Choose one hostname, such as `app.your-domain.com`. At the provider managing the domain's authoritative DNS, add an **A record** for that hostname pointing to the VPS IPv4 address. For an apex domain, the DNS record name is usually `@`; for a subdomain such as `app`, it is usually `app`.

Remove an old/conflicting A record. Remove a stale AAAA record unless you have deliberately configured working IPv6 to this same VPS. If using Cloudflare, use **DNS only** initially so certificate issuance and the first deployment use the VPS directly.

Allow DNS to propagate and confirm the result from your computer:

```bash
dig +short A app.your-domain.com
dig +short AAAA app.your-domain.com
```

The A answer must be your VPS IPv4. Caddy needs a real domain resolving to the VPS and reachable ports 80/443 to obtain a publicly trusted certificate. This production configuration expects HTTPS; it is not an IP-only HTTP deployment mode. An actual reachable email address is also required as the certificate contact.

## 3. Fill in the variables and deploy

Edit `infra/hostinger/terraform.tfvars`:

```hcl
deploy_enabled = true

vps_host   = "YOUR_REAL_VPS_IPV4"
ssh_user   = "root"
ssh_port   = 22
domain     = "app.your-domain.com"
acme_email = "you@your-domain.com"

# Copy the verified server PUBLIC host key from the Hostinger console.
ssh_host_key = "ssh-ed25519 REPLACE_WITH_THE_SERVER_PUBLIC_KEY"

# Use the key already loaded into your SSH agent.
ssh_private_key_path = null

deployment_revision = "1"
```

The strings above are explanatory placeholders. Replace them with valid real values before planning an enabled deployment. Leave `source_directory` unset when running from this checkout; the application root is found automatically. If you deliberately deploy another checkout, set its absolute path with `source_directory`.

In the same terminal where you loaded your SSH key:

```bash
cd /path/to/devloom/infra/hostinger
terraform plan
terraform apply
```

Or, from the repository root, run `./infra/hostinger/deploy.sh`. This runs initialization, validation, and apply for you, with Terraform's usual confirmation prompt.

Review the plan, then enter `yes` when Terraform asks. The apply uploads the selected application files over SSH, installs the server software, builds the release on the VPS, starts PostgreSQL, saves a database backup, runs pending migrations, starts Phoenix/Caddy, and verifies HTTPS `/health`. The health route checks database connectivity as well as the application.

Application code, assets, and production configuration are packaged from the current working files, including **uncommitted edits**. You do not need a public Git repository, GitHub deploy key, repository token, or container registry account. The packager excludes development caches, Terraform state, `.env` files, upload directories, and common private-key file extensions. Keep secrets out of application source files as well: an archive allowlist is not a secret scanner.

When the command succeeds, open the `application_url` Terraform output. Register the intended owner immediately: the current application lets the first registered account claim the migration-created legacy workspace. Public signup is enabled. Email delivery and password-reset infrastructure are not added by this deployment setup; manage invitations according to the application's existing behavior.

## 4. Server files, secrets, and restarts

| Path or Docker volume | Contents |
| --- | --- |
| `/opt/devloom/releases/<release_id>/` | An immutable copy of the deployed application source |
| `/opt/devloom/current` | Symlink to the last release that passed the deployment checks |
| `/opt/devloom/shared/app.env` | Generated PostgreSQL password, Phoenix secret, and runtime configuration; mode `600`, root only |
| `/opt/devloom/shared/backups/` | Custom-format PostgreSQL dumps made before migrations |
| `devloom-production_pgdata` | PostgreSQL database files, preserved across application replacements |
| `devloom-production_caddy_data` | TLS certificates and Caddy's account data |
| `devloom-production_caddy_config` | Caddy's persistent configuration storage |

Application secrets are generated **on the server**, reused across deploys, and never supplied as Terraform inputs or application build arguments. Keep `app.env`: losing it means losing the credentials needed to reconnect to the existing database and the secret used to sign sessions. The script stops if the database volume exists but the environment file is missing; it will not silently invent replacement credentials.

The containers use `restart: unless-stopped`, and Docker is enabled at boot. A normal VPS reboot brings the services back up. If you intentionally stop a container, start it again with Compose.

Protect your local SSH private key, Terraform state, saved plans, and `terraform.tfvars`. Keep the state in one durable location and do not commit it or private configuration. Avoid running independent copies against the same server. The remote deployment lock prevents simultaneous script execution, but separate Terraform states still do not coordinate lifecycle history.

## 5. Deploy updates and understand Terraform's limits

After changing the application, run `terraform plan` and `terraform apply` again from the same Terraform folder. Changes to the selected source files, deployment scripts, domain, server settings, or `deployment_revision` produce a new release identifier and trigger deployment.

To force a redeployment when the source/configuration has not changed, increment `deployment_revision`, for example from `"1"` to `"2"`. A failed creation is normally retried by Terraform on the next apply; inspect the error before retrying.

Terraform tracks the deployment trigger, not every package, container, or file on the VPS. An unchanged plan does not prove the services are healthy and does not repair manual server changes automatically. Use the operations commands below to inspect health, or deliberately trigger a redeploy.

The new image is built before the existing web container is replaced, so a build failure leaves the old web container running. There can be a short interruption while the web/proxy containers are replaced. Migrations must remain compatible with the running version during deployment. This is a single-server deployment, not a zero-downtime or highly available cluster.

There is **no automatic rollback** after migrations or service replacement. If a later step fails, inspect containers and the database backup before choosing recovery. The `current` symlink stays on the previous verified release until all checks pass, but newly started containers may already be running the attempted release. The symlink alone does not roll back containers or database schema.

`terraform destroy` removes Terraform's deployment tracking only. It deliberately does not stop containers, delete PostgreSQL data, remove files, cancel your VPS, or change DNS. Changing `deploy_enabled` back to `false` has the same tracking-only removal behavior; it is not an off switch. Enabling it again causes another deployment. Manage VPS cancellation through Hostinger when you actually want to end the service.

## 6. Routine operations

SSH into the VPS, become root if necessary, and define this helper in the shell:

```bash
sudo -i
export DEVLOOM_ENV_FILE=/opt/devloom/shared/app.env
export DEVLOOM_SOURCE_DIR="$(readlink -f /opt/devloom/current)"
export DEVLOOM_CADDYFILE="$DEVLOOM_SOURCE_DIR/docker/Caddyfile"
export RELEASE_ID="$(basename "$DEVLOOM_SOURCE_DIR")"

dc() {
  docker compose --project-name devloom-production \
    --env-file "$DEVLOOM_ENV_FILE" \
    -f "$DEVLOOM_SOURCE_DIR/compose.production.yaml" "$@"
}

dc ps
dc logs --tail=100 web caddy
curl --fail "https://app.your-domain.com/health"
```

If you already logged in as root, skip `sudo -i`. If the latest deployment failed after replacing containers, inspect `docker ps` and the attempted `/opt/devloom/releases/<release_id>` directory rather than assuming `current` describes those containers.

Useful commands with the helper:

```bash
dc restart web
dc logs --tail=100 db
dc up -d --wait
```

Do not share log output without checking it for private application data. Avoid `docker compose config` without `--quiet`: expanded configuration can print secrets.

### Back up off the VPS

The automatic dump runs before each deployment's migrations, even on the initial empty database. It is not a daily backup schedule. Dumps stay on the same disk as the application, so copy them off the VPS regularly and test recovery. No automatic retention policy deletes old dumps; monitor disk space and remove only backups you have deliberately archived or no longer need.

For a fresh manual backup, as root with `dc` defined:

```bash
umask 077
dc exec -T db sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
  > /opt/devloom/shared/backups/manual-$(date -u +%Y%m%dT%H%M%S).dump
```

Use an encrypted, access-controlled backup destination. Back up both the database dump **and** `/opt/devloom/shared/app.env`; also preserve the deployed source/release identification and Terraform state. PostgreSQL dumps contain user data; `app.env` contains secrets. Caddy can normally obtain fresh certificates if its data is lost, subject to certificate-authority rate limits.

### Restore a database backup

Restoration replaces database contents. Choose a known-good dump and application version compatible with its schema. First preserve a copy of the current database if it might be needed. Then, as root with the helper pointing at the intended release:

```bash
dc stop caddy web
dc up -d --wait db
# Recreate only the application database, keeping the Docker volume and DB role.
dc exec -T db sh -c \
  'dropdb --force -U "$POSTGRES_USER" "$POSTGRES_DB" && createdb -U "$POSTGRES_USER" -O "$POSTGRES_USER" "$POSTGRES_DB"'
dc exec -T db sh -c \
  'exec pg_restore --no-owner --exit-on-error -U "$POSTGRES_USER" -d "$POSTGRES_DB"' \
  < /opt/devloom/shared/backups/REPLACE_WITH_CHOSEN_BACKUP.dump
dc up -d --wait web
dc up -d caddy
curl --fail "https://app.your-domain.com/health"
```

Recreating the database removes all its current contents, including objects absent from the chosen backup. Use these commands only for an intentional restore after saving anything you may need. If restoring to a replacement VPS, restore the original `app.env` securely before starting the database and restore the dump before exposing web traffic. These dumps contain the application database, not server-wide PostgreSQL roles; the Compose PostgreSQL initialization creates the `devloom` user/database. Do not change the PostgreSQL major version during recovery without planning an upgrade.

Do not use `docker compose down -v`, delete `devloom-production_pgdata`, or run `mix ecto.reset` to fix a deployment. Removing a Docker volume deletes the stored database. Database recreation belongs only to the intentional recovery procedure above.

## 7. Troubleshooting and maintenance

| Symptom | Check |
| --- | --- |
| SSH authentication failure | `ssh-add -l`, the login username, key installation/permissions, SSH port, and Hostinger firewall |
| Host-key mismatch | Confirm the host identity using the trusted Hostinger console; update the public host key only after verifying a legitimate reinstall/change |
| Permission or sudo failure | Use root or a user already configured for passwordless `sudo -n` |
| Unsupported OS/conflicting Docker packages | Use a clean Ubuntu 24.04 image; the bootstrap deliberately does not remove existing Docker installations/packages |
| HTTPS check/certificate issuance fails | Public A/AAAA records, DNS propagation, port 80/443 reachability, another listener on those ports, and `dc logs --tail=100 caddy` |
| Build killed or disk exhausted | VPS RAM/disk capacity, `free -h`, `df -h`, and build output; resize the VPS or free deliberately chosen old artifacts |
| Web unhealthy | `dc logs --tail=100 web db`, migration output, and preservation of `app.env` |
| Database volume exists but credentials are missing | Restore the original environment file; do not delete the database or generate a different password |
| No changes in Terraform, but app is down | Inspect/restart services directly; Terraform does not continuously monitor or reconcile service health |

Source archives and deployment scripts may remain in `/tmp/devloom-*` after an interrupted or completed apply. After confirming no deployment is active, remove only the specific upload directory you have inspected. Do not remove `/opt/devloom/shared` or persistent volumes. Older release directories and images are retained; prune specific unused releases/images after confirming they are not needed for recovery. Never add `--volumes` to a cleanup command.

The Elixir, PostgreSQL, Caddy, and Debian images are pinned by manifest digest in the production files. Installed operating-system packages can receive updates when their image build layers are rebuilt. Review dependency and image updates periodically, update the selected digests, rebuild/test them, and deploy deliberately. Terraform does not automatically patch or reboot the VPS. Set up your preferred server updates, monitoring, and offsite backup schedule as ongoing operations.

## 8. Validation and remaining live checks

`terraform validate` and `terraform test` check the configuration without a server. To repeat the archive and input-validation checks, run `python3 -m unittest discover -s infra/hostinger/tests -p 'test_*.py'` from the repository root. For the isolated local production test, with Docker Compose 2.24.4 or newer available:

```bash
docker build -f Dockerfile.production -t devloom-production:verification .
python3 infra/hostinger/tests/smoke.py
```

The smoke test uses separate temporary volumes, loopback ports, and Caddy's local certificate authority. It removes only its own test containers and volumes afterward. It checks migrations, repeat migration, database persistence, private ports, health, static assets, a nonroot application process, HTTP redirection and HTTPS with certificate verification. These checks are separate from testing a real Hostinger deployment.

Native builds on Apple Silicon use ARM64. For an optional AMD64 test on that machine, Erlang's JIT can require an [emulation workaround documented by the Erlang team](https://github.com/erlang/otp/issues/10355). The production Dockerfile accepts a build-only flag for this check:

```bash
docker build --platform linux/amd64 --build-arg 'ERL_AFLAGS=+JMsingle true' \
  -f Dockerfile.production -t devloom-production:verification-amd64 .
DEVLOOM_SMOKE_TAG=verification-amd64 DEVLOOM_SMOKE_ERL_AFLAGS='+JMsingle true' \
  python3 infra/hostinger/tests/smoke.py
```

The VPS builds natively and does not set this emulation flag.

Because no VPS/domain/SSH credentials exist yet, actual Hostinger networking, Ubuntu firewall changes, public DNS propagation, and public ACME certificate issuance cannot be exercised now. The first real apply is the final end-to-end check in your own environment; it reports failure if the services or trusted HTTPS health checks do not succeed. See [the validation report](hostinger-validation.md) for the exact checks completed during implementation.

## References

- [Terraform provisioners and SSH connection settings](https://developer.hashicorp.com/terraform/language/provisioners)
- [Terraform `terraform_data` resource](https://developer.hashicorp.com/terraform/language/resources/terraform-data)
- [Docker Engine installation on Ubuntu](https://docs.docker.com/engine/install/ubuntu/)
- [Docker and UFW firewall behavior](https://docs.docker.com/engine/network/packet-filtering-firewalls/)
- [Phoenix production releases](https://hexdocs.pm/phoenix/releases.html)
- [Caddy automatic HTTPS requirements](https://caddyserver.com/docs/automatic-https)
- [Hostinger VPS SSH access](https://www.hostinger.com/tutorials/how-to-use-ssh)
