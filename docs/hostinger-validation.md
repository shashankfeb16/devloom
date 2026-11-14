# Hostinger deployment validation

Validated on 14 November 2026. The implementation configures an existing Ubuntu 24.04 VPS over SSH; it does not purchase infrastructure or manage DNS.

## Completed checks

| Check | Result |
| --- | --- |
| Terraform 1.14.0: initialization, formatting and validation | Passed; only the built-in Terraform provider is required |
| Terraform plan-only tests | 14 passed: disabled mode, complete enabled configuration, required inputs, placeholder addresses/domains, invalid ports and SSH host-key format |
| One-command `deploy.sh` with example variables | Passed in an isolated temporary module: 0 resources added, changed or destroyed; deployment stayed disabled |
| Archive and remote configuration tests | 10 passed: planned-file isolation, deterministic archive, changed-source rejection, symlink/path traversal rejection, valid inputs and malformed input rejection |
| Actual Terraform source manifest packaging | Passed; 92 application inputs packaged, including the production Docker/Compose/Caddy files and release helper; infrastructure files excluded |
| Bash syntax | Passed for the wrapper, Ubuntu bootstrap and remote deployment script |
| Production Docker image: Linux ARM64 | Built successfully, including production dependencies, native bcrypt, assets, digest and Elixir release |
| Production Docker image: Linux AMD64 | Built successfully under Apple Silicon emulation using the documented Erlang JIT flag |
| Production integration tests: ARM64 and AMD64 app images | Both passed with fresh isolated PostgreSQL and Caddy services |
| Application `mix precommit` | Passed: compilation with warnings as errors, dependency check, formatting and 180 ExUnit tests with 0 failures |
| Existing JavaScript tests | 23 passed, 0 failures |

The production integration test ran all **8 database migrations**, then ran migrations a second time and verified that no additional migration was applied. It checked the database-aware `/health` response, HTTPS using a verified Caddy local-CA certificate, HTTP-to-HTTPS redirection, static JavaScript delivery, a nonroot application process, and absence of published PostgreSQL/Phoenix ports. It verified that a database record survived a database restart.

The same test created a custom-format `pg_dump`, introduced a table absent from that dump, recreated the application database, restored the dump with `pg_restore`, and verified both the restored record and removal of the newer table. The application became healthy again afterward.

Test containers, networks and volumes used unique names and were removed after each run. Development and production data volumes were not used. Docker Engine was 28.4.0; Docker Compose was 2.39.4-desktop.1. The application image was tested on both architectures; PostgreSQL and Caddy ran natively on the ARM64 test host.

For AMD64 emulation only, the builder used `--build-arg 'ERL_AFLAGS=+JMsingle true'` and the smoke test supplied the same flag to the runtime. This addresses an [Erlang JIT limitation under QEMU/Rosetta](https://github.com/erlang/otp/issues/10355). Native VPS deployment does not set this flag. A native AMD64 VPS was not available for testing.

## Checks requiring your future VPS

There was no VPS, domain, SSH identity or Hostinger account configuration available. The following have **not** been tested against a real server:

- Terraform SSH authentication, host-key verification, file upload and remote provisioner execution.
- Docker apt installation, systemd enablement and UFW changes on a clean Ubuntu 24.04 VPS.
- Hostinger's external firewall and inbound internet reachability.
- Public DNS propagation and public ACME certificate issuance/renewal.
- Application capacity, sustained load, host failure recovery and external backup storage.

Those remain live-environment checks. The first enabled apply must succeed through its trusted HTTPS health checks before considering the deployment complete. The configuration preserves application credentials and database storage across deployments, makes a database backup before migrations, and reports failures; it does not automatically roll back database migrations or replaced services.

See [the deployment guide](hostinger-vps.md) for setup, updates, operations and recovery commands, and the repeatable test commands.
