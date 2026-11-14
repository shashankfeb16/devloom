# Run Devloom CI/CD with Jenkins on your Mac

Jenkins runs locally in Docker and checks either a temporary snapshot of your working copy or a version of Devloom committed to GitHub. After successful GitHub checks, it can optionally deploy that commit to an existing VPS over SSH. Devloom continues running on the VPS when your Mac is off; Jenkins can execute new builds only while your Mac and Docker are running.

Start with local CI. Production deployment is disabled by default and requires credentials plus a separate approval in Jenkins.

## 1. Start the local Jenkins service

Install and start Docker Desktop. Use Docker Compose 2.24.4 or newer, which supports the isolated production smoke test. Python 3 on your Mac is also needed for the local verification helpers; check it with `python3 --version`. The initial image builds download Jenkins, plugins, and build tools, so internet access and spare disk space are required.

From the Devloom repository:

```sh
cd /Users/shashanknath/Developer/devloom
bash infra/jenkins/runtime/jenkins.sh init
bash infra/jenkins/runtime/jenkins.sh config
bash infra/jenkins/runtime/jenkins.sh up
bash infra/jenkins/runtime/jenkins.sh doctor
bash infra/jenkins/runtime/jenkins.sh status
```

`init` creates `infra/jenkins/runtime/.env` with a generated administrator password and mode `600`. It preserves an existing file. Open that file locally to read `JENKINS_ADMIN_USER` and `JENKINS_ADMIN_PASSWORD`; do not paste the password into Git, a build log, or a chat. The file is ignored by Git.

Open [http://localhost:8080](http://localhost:8080) and sign in with those credentials. Plugins, the administrator account, and the agent are configured automatically; there is no first-run setup wizard.

The separate `devloom-jenkins` Compose project contains:

| Service | Purpose |
| --- | --- |
| `controller` | Jenkins dashboard and configuration; zero build executors. Its port is bound only to the Mac's loopback interface. |
| `agent` | One build executor labeled `devloom-docker`, with Docker CLI/Compose, Node, Python, Terraform, Git, and SSH tools. |
| `docker` | A dedicated Docker-in-Docker daemon for CI images, containers, and volumes. It uses TLS and a privileged container; the Mac's Docker socket is not mounted into Jenkins. |

The agent shares the CI daemon's network namespace so the production smoke test can reach its loopback ports. Workspace and temporary paths are also shared between the agent and daemon for Compose bind mounts. Jenkins configuration, agent files, Docker data, and Terraform state use persistent named volumes.

This setup is independent of `compose.yaml` and `compose.production.yaml`; starting Jenkins does not start or deploy Devloom.

## 2. Run your first pipeline without committing or pushing

With Jenkins running, execute:

```sh
python3 infra/jenkins/runtime/verify.py
python3 infra/jenkins/runtime/local-test.py
```

`verify.py` checks that the agent is connected and submits the current `Jenkinsfile` to Jenkins' declarative-pipeline validator. It reads local login credentials without printing them.

`local-test.py` creates a temporary source snapshot containing tracked files and untracked files that Git does not ignore. Ignored local credentials and build output are excluded. It makes a synthetic commit only in that temporary snapshot, serves it inside the Jenkins Docker network, and creates a `devloom-local-test` Pipeline-from-SCM job that runs the actual `Jenkinsfile`. It does not commit or push anything in your Devloom repository.

Open [the local test job](http://localhost:8080/job/devloom-local-test/) to watch its stages, or follow progress in the terminal. The script waits for the build result. It runs tests, the production build, and the local production smoke test with `DEPLOY_PRODUCTION=false`; the production deployment guard also rejects this temporary Git remote.

After the run, the script stops the temporary source server and disables the test job intentionally. The build and its logs remain available in Jenkins. To test new working-copy edits, rerun `local-test.py` instead of selecting **Build Now** on the disabled job. If the build fails, open **Console Output**, fix the source, and rerun the script.

This first test needs no GitHub token, VPS, or production credentials. Continue below when you want Jenkins to track GitHub automatically.

## 3. Put the pipeline on the branch Jenkins will check out

For ongoing GitHub builds, Jenkins reads `Jenkinsfile` and the CI scripts from the remote repository. Uncommitted edits on your Mac are not part of those builds; use the local snapshot test above for them.

Review the new files with `git status` and `git diff`, then commit and push them using your normal workflow. Review at least:

```text
Jenkinsfile
infra/jenkins/
docs/jenkins.md
README.md
.gitignore
.dockerignore
```

The private `.env` and `infra/jenkins/deploy/production.tfvars.json` must remain ignored. Merge the reviewed setup into `main` before creating the main-branch job below. To test the setup on an owner-controlled feature branch first, use that branch in the job's branch specification and leave deployment disabled.

## 4. Create the GitHub Devloom job

In Jenkins:

1. Select **New Item**, enter `devloom-main`, choose **Pipeline**, and select **OK**.
2. Under **Pipeline**, choose **Pipeline script from SCM**.
3. Select **Git** and set **Repository URL** to `https://github.com/shashankfeb16/devloom.git`.
4. For a public repository, leave credentials unset. For a private repository, add a **Username with password** credential: your GitHub username and a read-only personal access token as the password. A fine-grained token should access only this repository and have **Contents: Read-only**. Use an ID such as `devloom-github-read`, then select it for checkout.
5. Set **Branch Specifier** to `refs/heads/main`.
6. Set **Script Path** to `Jenkinsfile` and keep **Lightweight checkout** enabled.
7. Save, then select **Build Now**.

The first run registers the parameters declared by the `Jenkinsfile`. Subsequent runs show **Build with Parameters**. Keep:

```text
RUN_PRODUCTION_SMOKE = true
DEPLOY_PRODUCTION = false
```

The pipeline has these stages:

| Stage | What it verifies |
| --- | --- |
| Checkout | Retrieves the selected Git commit into the agent's workspace. |
| Prepare CI | Builds the pinned Elixir/OTP test image and its assets. |
| Formatting and compilation | Rejects formatting errors, unused lockfile entries, and compilation warnings without rewriting the checkout. |
| Phoenix tests | Runs the application and LiveView test suite against an isolated PostgreSQL database. |
| JavaScript tests | Runs the existing browser-side whiteboard helper tests using Node's test runner. |
| Deployment configuration tests | Runs Python tests and Terraform validation/plan-only tests in a temporary module without your production tfvars or state. |
| Production image | Builds the Phoenix release with `Dockerfile.production`. |
| Local production smoke test | Exercises migrations, repeat migration, health, HTTPS, assets, persistence, and database backup/restore using temporary containers and volumes. |
| VPS deployment | Runs only when explicitly requested, from a trusted main-branch job, after checks and production smoke pass. |

CI database resources have a unique `devloom-ci-...` project name. Cleanup removes that build's test volumes and image tags; it does not touch the development or production database.

Open the build's **Console Output** to inspect failures. A green build means the checks completed; it does not prove that a VPS's public DNS, firewall, SSH, or certificate issuance is configured correctly.

## 5. Test automatic builds and failed checks

After the first run, Jenkins polls GitHub approximately every five minutes while it is running. The `H/5 * * * *` schedule spreads checks within that interval. GitHub does not need an inbound connection to your Mac, so a webhook tunnel is unnecessary for this setup.

To exercise a successful automatic build, push an ordinary reviewed change to the configured branch and wait for polling, or select **Build Now** manually.

To prove that a failed test stops later stages:

1. Create an owner-controlled temporary branch, for example `codex/jenkins-failure-check`.
2. Make a small deliberate assertion failure in a JavaScript test, commit it, and push that branch.
3. Create a temporary Pipeline job pointing to that branch, with `DEPLOY_PRODUCTION=false`.
4. Run it and confirm the JavaScript stage fails and the production-image/deployment stages are skipped.
5. Revert the test change on that branch, run again, then remove the temporary job when finished.

Keep this exercise off `main`. Use only branches and job definitions you control on this local Jenkins installation.

## 6. Run the same checks directly, if needed

The pipeline calls `infra/jenkins/ci/run.sh`, so the same commands are available outside Jenkins. On your Mac this path requires Docker Desktop plus Node, Python 3, and Terraform 1.10 or newer below 2.0; the Jenkins agent already contains those tools.

```sh
cd /Users/shashanknath/Developer/devloom
export CI_PROJECT_NAME=devloom-ci-local-check
bash infra/jenkins/ci/run.sh all
```

`all` runs checks, tests, the production build, and the smoke test, then cleans its own resources. When running stages individually, keep the same `CI_PROJECT_NAME` value until cleanup:

```sh
export CI_PROJECT_NAME=devloom-ci-local-check
bash infra/jenkins/ci/run.sh prepare
bash infra/jenkins/ci/run.sh check
bash infra/jenkins/ci/run.sh test
bash infra/jenkins/ci/run.sh javascript
bash infra/jenkins/ci/run.sh infra
bash infra/jenkins/ci/run.sh build
bash infra/jenkins/ci/run.sh smoke
bash infra/jenkins/ci/run.sh cleanup
```

For the repository's developer precommit check, run `prepare` and then `bash infra/jenkins/ci/run.sh precommit`, followed by `cleanup`. That alias may format files inside its disposable container; CI's separate formatting check rejects unformatted committed files.

On Apple Silicon, builds use native ARM64 images. An AMD64 VPS is still supported by the deployment path described below because it builds the application again on the VPS. This setup does not publish an image to a registry or promote the locally tested image unchanged. See the [Hostinger validation instructions](hostinger-vps.md#8-validation-and-remaining-live-checks) for optional cross-architecture verification.

## 7. Enable VPS deployment when ready

Complete the VPS, domain, DNS, SSH host-key verification, and firewall steps in [Deploy to a Hostinger VPS](hostinger-vps.md). The target must match that existing deployment design: a dedicated Ubuntu server, reachable by SSH, with the required root or passwordless-sudo access.

Use one trusted `main` deployment job on this single-user Jenkins installation. The branch check prevents accidental deployment from another branch; it is not a security boundary against an edited Jenkinsfile. Do not run fork pull requests or arbitrary untrusted jobs on this controller/agent after adding production credentials. Future untrusted builds need a separate credential scope and build environment.

Create the production configuration locally:

```sh
cp infra/jenkins/deploy/production.tfvars.json.example infra/jenkins/deploy/production.tfvars.json
chmod 600 infra/jenkins/deploy/production.tfvars.json
```

Edit the JSON file with your real settings. Its allowed keys are `deploy_enabled`, `vps_host`, `ssh_user`, `ssh_port`, `ssh_host_key`, `domain`, `acme_email`, and `deployment_revision`. Set `deploy_enabled` to `true`. Keep the explicit `ssh_user` and `ssh_port` fields from the example. Do not add a private key, `ssh_private_key_path`, `source_directory`, or a state path.

`ssh_host_key` is the server's verified **public host key**, not your login public key or a SHA256 fingerprint. Verify it through the VPS provider's console as described in the Hostinger guide before trusting it.

Under **Manage Jenkins → Credentials**, add:

| Kind | ID | Contents |
| --- | --- | --- |
| Secret file | `devloom-production-config` | Upload the completed `production.tfvars.json`. |
| SSH Username with private key | `devloom-vps-ssh` | The VPS login user and its SSH private key; add the passphrase when the key is encrypted. |

Keep these credentials available only to the trusted deployment job. Application database credentials and `SECRET_KEY_BASE` remain in the VPS's existing `/opt/devloom/shared/app.env`; Jenkins does not need to read that file.

### Existing production deployments: migrate Terraform state first

If Devloom has already been deployed with `infra/hostinger`, preserve the existing deployment state and target configuration before the first Jenkins deployment. An empty Jenkins workspace does not know about a deployment managed from your Mac. Creating a separate state history against the same server can cause unintended redeployments and inconsistent tracking.

The agent stores state at `/var/lib/devloom-terraform/terraform.tfstate` in the persistent `terraform-state` named volume. The runtime sets `DEVLOOM_TF_STATE_DIR=/var/lib/devloom-terraform`. The deploy helper stages a clean Terraform module with a local backend pointing to that file; it does not use the Git workspace as state storage.

After Jenkins is running, define this convenience function in your terminal:

```sh
jenkins_compose() {
  docker compose --env-file infra/jenkins/runtime/.env \
    -f infra/jenkins/runtime/compose.yaml "$@"
}
```

Stop all other Terraform deployment commands while migrating. Back up the original state and configuration privately. If the current state is the default `infra/hostinger/terraform.tfstate`, import it with:

```sh
jenkins_compose exec -T --user jenkins agent sh -ec \
  'test ! -e /var/lib/devloom-terraform/terraform.tfstate'
jenkins_compose cp infra/hostinger/terraform.tfstate agent:/tmp/devloom-ci/import.tfstate
jenkins_compose exec -T --user root agent sh -ec \
  'chown jenkins:jenkins /tmp/devloom-ci/import.tfstate; chmod 600 /tmp/devloom-ci/import.tfstate'
jenkins_compose exec -T --user jenkins agent sh -ec '
  umask 077
  mkdir -p /var/lib/devloom-terraform
  set -C
  cat /tmp/devloom-ci/import.tfstate > /var/lib/devloom-terraform/terraform.tfstate
  chmod 600 /var/lib/devloom-terraform/terraform.tfstate
  rm /tmp/devloom-ci/import.tfstate
'
```

The commands refuse to overwrite existing Jenkins state. If state already exists there, stop and compare the state histories before proceeding. If your existing deployment uses a different backend or state location, migrate that actual state instead of copying an unrelated or empty file. The secret-file configuration must describe the same server, user, port, domain, certificate email, and deployment revision as the existing target.

After migration, use the durable Jenkins state for subsequent deployments; do not also apply from an independent state on your Mac. Preserve the original backup until the migrated plan has been reviewed. Do not commit state, saved plans, or private configuration to Git.

### Run a deployment

Select **Build with Parameters**, set `RUN_PRODUCTION_SMOKE=true` and `DEPLOY_PRODUCTION=true`, then start the build.

After CI succeeds, Jenkins acquires the `devloom-production` lock, binds the two credentials, and creates a saved Terraform plan. Read that plan in the console. Jenkins waits up to 15 minutes for **Deploy Devloom** approval, then applies that exact plan for the tested commit. Cancel the approval if the target or changes are unexpected.

The existing VPS script uploads the application source, builds the release on the VPS, requires a PostgreSQL backup before migrations, replaces the application, and verifies public HTTPS `/health`. A short interruption is possible. There is no automatic rollback after migrations or service replacement; the previous `current` symlink does not roll back running containers or the database schema. See the Hostinger guide's recovery steps before choosing recovery after a failed deployment.

## 8. Manage and troubleshoot Jenkins

```sh
bash infra/jenkins/runtime/jenkins.sh status
bash infra/jenkins/runtime/jenkins.sh logs controller agent docker
bash infra/jenkins/runtime/jenkins.sh doctor
bash infra/jenkins/runtime/jenkins.sh down
bash infra/jenkins/runtime/jenkins.sh up
```

`down` preserves Jenkins accounts, jobs, credentials, caches, and Terraform state. It accepts no extra flags. Avoid volume-removal or global-prune commands: they can erase the persistent state needed by CI/CD. Stop Jenkins independently of the application with this helper rather than using Devloom's production Compose commands.

| Symptom | What to check |
| --- | --- |
| Docker permission/connection error | Start Docker Desktop and confirm `docker version` can show both client and server. |
| Port 8080 already used | Change `JENKINS_PORT` in the ignored runtime `.env`, rerun `up`, and open the new loopback port. |
| Build waits for `devloom-docker` | Check the `agent` logs and **Manage Jenkins → Nodes → devloom-agent**. Run `doctor`; the agent must connect before builds execute. |
| First startup or build is slow | Follow logs; initial image, plugin, dependency, and asset downloads can take longer than cached builds. |
| Disk space runs low | Check Docker Desktop's disk use. CI removes build-specific image tags and test volumes, but reusable Docker build caches and persistent Jenkins data remain. Review targeted cache maintenance separately; preserve Jenkins and Terraform volumes. |
| TLS/certificate error reaching the CI daemon | Check `docker` and `agent` logs and their shared certificate volume. Recreate services with `down` then `up` while preserving volumes; do not disable TLS verification. |
| Git checkout cannot authenticate | Confirm the selected Git credential has read access to this repository and the branch exists remotely. |
| Production credential is missing | Confirm the two exact IDs above and that the job is allowed to use them. Local CI needs neither production credential. |
| Production plan reports a target mismatch | Review `/var/lib/devloom-terraform/target.json`, the secret-file target settings, and the state migration. Do not delete the marker to bypass a mismatch. |
| Pipeline changes are not visible in the GitHub job | Commit and push them to that job's configured branch, or use `local-test.py` to test uncommitted Mac files. |
| `devloom-local-test` is disabled | This is intentional after the snapshot test. Run `python3 infra/jenkins/runtime/local-test.py` again to create a fresh snapshot and execute it. |

The dashboard is configured for one trusted local administrator. If Jenkins is later moved to an always-on server or exposed beyond localhost, review authentication, authorization, TLS, agent isolation, credentials, and persistent-state backups for that environment.

Official references: [Jenkins in Docker](https://www.jenkins.io/doc/book/installing/docker/), [Pipeline syntax](https://www.jenkins.io/doc/book/pipeline/syntax/), and [Jenkins credentials](https://www.jenkins.io/doc/book/using/using-credentials/).
