locals {
  source_root = var.source_directory == null ? abspath("${path.module}/../..") : abspath(pathexpand(var.source_directory))
  # Upload application inputs only, never the whole checkout or Terraform state.
  source_files = sort(distinct(concat(
    ["mix.exs", "mix.lock", "Dockerfile.production", ".dockerignore", "compose.production.yaml", "docker/Caddyfile"],
    flatten([for directory in ["config", "lib", "priv", "assets"] : [
      for filename in fileset(local.source_root, "${directory}/**") : filename
      if !can(regex("(^|/)(node_modules|\\.git|\\.terraform|_build|deps|tmp|uploads)(/|$)|(^|/)(\\.env[^/]*|\\.DS_Store)$|\\.(pem|key|p12|pfx)$|^priv/static/(assets/|cache_manifest\\.json$)", filename))
    ]])
  )))
  source_manifest = { for filename in local.source_files : filename => filesha256("${local.source_root}/${filename}") }
  release_id = substr(sha256(jsonencode({
    source  = local.source_manifest
    scripts = { for filename in ["package.py", "bootstrap.sh", "remote-deploy.sh"] : filename => filesha256("${path.module}/scripts/${filename}") }
    host    = var.vps_host, port = var.ssh_port, user = var.ssh_user
    domain  = var.domain, email = var.acme_email, revision = var.deployment_revision
  })), 0, 24)
  archive_path = abspath("${path.module}/.generated/${local.release_id}.tar.gz")
}

resource "terraform_data" "deployment" {
  count            = var.deploy_enabled ? 1 : 0
  triggers_replace = [local.release_id, var.ssh_host_key]

  lifecycle {
    precondition {
      condition     = var.vps_host != null && var.ssh_host_key != null && var.domain != null && var.acme_email != null
      error_message = "Set vps_host, verified ssh_host_key, domain and acme_email before enabling deployment."
    }
    precondition {
      condition     = var.vps_host == null ? true : !can(regex("^(192\\.0\\.2|198\\.51\\.100|203\\.0\\.113)\\.", var.vps_host))
      error_message = "Replace the documentation/example VPS address with your real server IP."
    }
    precondition {
      condition     = var.domain == null ? true : !can(regex("(^|\\.)example\\.(com|net|org)$|\\.(invalid|test|localhost)$", var.domain))
      error_message = "Replace the example domain with the real domain you control."
    }
  }

  connection {
    type        = "ssh"
    host        = var.vps_host
    user        = var.ssh_user
    port        = var.ssh_port
    private_key = var.ssh_private_key_path == null ? null : file(pathexpand(var.ssh_private_key_path))
    agent       = var.ssh_private_key_path == null
    host_key    = var.ssh_host_key
    timeout     = "5m"
  }

  provisioner "local-exec" {
    command = "python3 \"$PACKAGER\""
    environment = {
      PACKAGER             = abspath("${path.module}/scripts/package.py")
      SOURCE_ROOT          = local.source_root
      SOURCE_MANIFEST_JSON = jsonencode(local.source_manifest)
      OUTPUT_FILE          = local.archive_path
    }
  }

  provisioner "remote-exec" {
    inline = ["umask 077; mkdir '/tmp/devloom-${self.id}'"]
  }

  provisioner "file" {
    source      = local.archive_path
    destination = "/tmp/devloom-${self.id}/source.tar.gz"
  }

  provisioner "file" {
    content = jsonencode({
      domain   = var.domain, acme_email = var.acme_email,
      ssh_port = var.ssh_port, release_id = local.release_id
    })
    destination = "/tmp/devloom-${self.id}/deploy-config.json"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/bootstrap.sh"
    destination = "/tmp/devloom-${self.id}/bootstrap.sh"
  }

  provisioner "file" {
    source      = "${path.module}/scripts/remote-deploy.sh"
    destination = "/tmp/devloom-${self.id}/remote-deploy.sh"
  }

  provisioner "remote-exec" {
    inline = ["if [ \"$(id -u)\" -eq 0 ]; then bash '/tmp/devloom-${self.id}/remote-deploy.sh' '/tmp/devloom-${self.id}'; else sudo -n bash '/tmp/devloom-${self.id}/remote-deploy.sh' '/tmp/devloom-${self.id}'; fi"]
  }
  # No destroy provisioner: destroy forgets deployment tracking and preserves VPS/data.
}
