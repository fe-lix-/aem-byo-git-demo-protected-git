variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "aws_profile" {
  description = "The assistant must keep this set to the read-only inspection profile."
  type        = string
  default     = "copilot-readonly"
}

variable "project_name" {
  type    = string
  default = "eds-byo-git-demo"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,29}$", var.project_name))
    error_message = "Use 3-30 lowercase letters, digits, and hyphens, starting with a letter."
  }
}

variable "source_repository_name" {
  description = "Existing CodeCommit repository to protect and sync from. Terraform reads it; it never creates or deletes it."
  type        = string
  default     = "aem-byo-git"
}

variable "vpc_cidr" {
  description = "IPv4 /24 VPC CIDR. Keep environment-specific values in private tfvars."
  type        = string
  default     = "10.0.0.0/24"

  validation {
    condition     = try(cidrnetmask(var.vpc_cidr) == "255.255.255.0", false)
    error_message = "Provide an IPv4 /24 CIDR for the VPC."
  }
}

variable "trusted_client_cidrs" {
  description = "Public IPv4 CIDRs allowed to assume the Git client role and pull/push. Not the outbound Adobe IP list."
  type        = set(string)

  validation {
    condition = length(var.trusted_client_cidrs) > 0 && alltrue([
      for cidr in var.trusted_client_cidrs :
      can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) >= 1, false)
    ])
    error_message = "Provide explicit IPv4 CIDRs; /0 is not permitted."
  }
}

variable "git_client_principal_arns" {
  description = "Existing same-account IAM user/role ARNs allowed to assume the IP-restricted Git client role."
  type        = set(string)

  validation {
    condition = length(var.git_client_principal_arns) > 0 && alltrue([
      for arn in var.git_client_principal_arns :
      can(regex("^arn:[a-z-]+:iam::[0-9]{12}:(user|role)/[^*?]+$", arn))
    ])
    error_message = "Provide explicit IAM user/role ARNs, without wildcards."
  }
}

variable "destination_repository_url" {
  description = "External (Adobe-hosted) HTTPS Git URL, without credentials, query string, fragment, or a nonstandard port."
  type        = string

  validation {
    condition     = can(regex("^https://[A-Za-z0-9.-]+/[^@?#[:space:]]+$", var.destination_repository_url))
    error_message = "Provide an HTTPS repository URL with a hostname and path, without embedded credentials."
  }
}

variable "sync_branch" {
  description = "Branch whose pushes trigger the sync, and the only branch pushed to the destination."
  type        = string
  default     = "main"

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9._/-]*$", var.sync_branch))
    error_message = "Provide a branch name, not a refspec or command-line option."
  }
}

variable "lambda_image_uri" {
  description = "Previously built Lambda image in this account/region's ECR, pinned to a SHA-256 digest."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}\\.dkr\\.ecr\\.[a-z0-9-]+\\.amazonaws\\.com(\\.cn)?/[^@:]+@sha256:[0-9a-f]{64}$", var.lambda_image_uri))
    error_message = "Provide an ECR image URI pinned with @sha256:<64 hex characters>."
  }
}

variable "allowed_destination_cidrs" {
  description = "Only these public IPv4 destinations are reachable from Lambda, on TCP/443. Individual supplied IPs use /32."
  type        = set(string)

  validation {
    condition = length(var.allowed_destination_cidrs) > 0 && alltrue([
      for cidr in var.allowed_destination_cidrs :
      can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) >= 1, false)
    ])
    error_message = "Provide explicit IPv4 destination CIDRs; /0 is not permitted."
  }
}
