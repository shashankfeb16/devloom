variable "deploy_enabled" {
  description = "Keep false for offline validation. Set true only when your VPS, SSH and DNS are ready."
  type        = bool
  default     = false
}

variable "vps_host" {
  description = "Your purchased VPS IPv4 address. No VPS is created or purchased by this configuration."
  type        = string
  default     = null
  validation {
    condition     = var.vps_host == null ? true : can(cidrnetmask("${var.vps_host}/32"))
    error_message = "vps_host must be an IPv4 address."
  }
}

variable "ssh_user" {
  description = "SSH login with root access, or passwordless sudo."
  type        = string
  default     = "root"
  validation {
    condition     = can(regex("^[a-z_][a-z0-9_-]*$", var.ssh_user))
    error_message = "Use a Linux SSH username."
  }
}

variable "ssh_port" {
  type        = number
  description = "SSH port already configured on your VPS. The script preserves access on this port."
  default     = 22
  validation {
    condition     = var.ssh_port >= 1 && var.ssh_port <= 65535 && floor(var.ssh_port) == var.ssh_port && !contains([80, 443], var.ssh_port)
    error_message = "Use an integer port from 1 to 65535 other than 80 or 443."
  }
}

variable "ssh_private_key_path" {
  type        = string
  description = "Optional path to an unencrypted private key. Null uses your SSH agent, recommended for passphrase-protected keys."
  default     = null
  validation {
    condition     = var.ssh_private_key_path == null ? true : fileexists(pathexpand(var.ssh_private_key_path))
    error_message = "The private key file must exist locally. Use null for SSH agent authentication."
  }
}

variable "ssh_host_key" {
  type        = string
  description = "Verified VPS host PUBLIC key, e.g. ssh-ed25519 AAAA... (not a fingerprint or your login key)."
  default     = null
  validation {
    condition     = var.ssh_host_key == null ? true : can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)) [A-Za-z0-9+/=]+( [^\r\n]+)?$", var.ssh_host_key))
    error_message = "Use the server's OpenSSH public host key on one line."
  }
}

variable "domain" {
  type        = string
  description = "Lowercase hostname, with its A record already pointing at vps_host. Do not include https:// or a path."
  default     = null
  validation {
    condition = var.domain == null ? true : (
      length(var.domain) <= 253 && can(regex("^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\\.)+[a-z]{2,63}$", var.domain))
    )
    error_message = "Use a lowercase public DNS hostname such as app.your-domain.com."
  }
}

variable "acme_email" {
  type        = string
  description = "Contact email for automatic HTTPS certificates."
  default     = null
  validation {
    condition     = var.acme_email == null ? true : can(regex("^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,63}$", var.acme_email))
    error_message = "Enter an email address without spaces, quotes or line breaks."
  }
}

variable "source_directory" {
  type        = string
  description = "Optional application checkout path. Null uses the repository containing this Terraform folder."
  default     = null
}

variable "deployment_revision" {
  type        = string
  description = "Change this value to force a redeploy when code and configuration have not changed."
  default     = "1"
}
