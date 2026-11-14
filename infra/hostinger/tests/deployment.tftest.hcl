# All runs are plan-only: no SSH connection, purchase, or remote command occurs.
variables {
  deploy_enabled = true
  vps_host       = "10.0.0.10"
  domain         = "app.devloom-ci.org"
  acme_email     = "deploy@devloom-ci.org"
  ssh_host_key   = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITestFixtureOnlyNeverConnect"
}

run "offline_defaults_create_nothing" {
  command = plan
  variables {
    deploy_enabled = false
    vps_host       = null
    domain         = null
    acme_email     = null
    ssh_host_key   = null
  }
  assert {
    condition     = length(terraform_data.deployment) == 0 && output.deployment_enabled == false && output.application_url == null
    error_message = "Offline mode must create zero resources and expose no application URL."
  }
}

run "ready_configuration_plans_one_deployment" {
  command = plan
  assert {
    condition     = length(terraform_data.deployment) == 1 && output.application_url == "https://app.devloom-ci.org"
    error_message = "A complete configuration must plan exactly one deployment."
  }
}

run "missing_server_is_rejected" {
  command = plan
  variables {
    vps_host = null
  }
  expect_failures = [terraform_data.deployment]
}

run "missing_host_key_is_rejected" {
  command = plan
  variables {
    ssh_host_key = null
  }
  expect_failures = [terraform_data.deployment]
}

run "missing_domain_is_rejected" {
  command = plan
  variables {
    domain = null
  }
  expect_failures = [terraform_data.deployment]
}

run "missing_certificate_email_is_rejected" {
  command = plan
  variables {
    acme_email = null
  }
  expect_failures = [terraform_data.deployment]
}

run "documentation_ip_is_rejected" {
  command = plan
  variables {
    vps_host = "203.0.113.10"
  }
  expect_failures = [terraform_data.deployment]
}

run "placeholder_domain_is_rejected" {
  command = plan
  variables {
    domain = "app.example.com"
  }
  expect_failures = [terraform_data.deployment]
}

run "invalid_ipv4_is_rejected" {
  command = plan
  variables {
    vps_host = "999.1.2.3"
  }
  expect_failures = [var.vps_host]
}

run "url_as_domain_is_rejected" {
  command = plan
  variables {
    domain = "https://app.devloom-ci.org/path"
  }
  expect_failures = [var.domain]
}

run "proxy_port_as_ssh_port_is_rejected" {
  command = plan
  variables {
    ssh_port = 443
  }
  expect_failures = [var.ssh_port]
}

run "out_of_range_port_is_rejected" {
  command = plan
  variables {
    ssh_port = 65536
  }
  expect_failures = [var.ssh_port]
}

run "fractional_port_is_rejected" {
  command = plan
  variables {
    ssh_port = 22.5
  }
  expect_failures = [var.ssh_port]
}

run "host_fingerprint_is_rejected" {
  command = plan
  variables {
    ssh_host_key = "SHA256:ThisIsAFingerprintNotAPublicKey"
  }
  expect_failures = [var.ssh_host_key]
}
