mock_provider "aws" {
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }

  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }

  mock_data "aws_availability_zones" {
    defaults = { names = ["us-east-1a"] }
  }

  mock_data "aws_codecommit_repository" {
    defaults = {
      arn             = "arn:aws:codecommit:us-east-1:123456789012:aem-byo-git"
      repository_name = "aem-byo-git"
    }
  }

  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/demo-test-role" }
  }

  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:123456789012:secret:demo-test-secret" }
  }

  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:123456789012:log-group:/aws/lambda/demo-test" }
  }

  mock_resource "aws_cloudwatch_event_rule" {
    defaults = { arn = "arn:aws:events:us-east-1:123456789012:rule/demo-test" }
  }

  mock_resource "aws_lambda_function" {
    defaults = { arn = "arn:aws:lambda:us-east-1:123456789012:function:demo-test" }
  }

  mock_resource "aws_vpc_endpoint" {
    defaults = { id = "vpce-0123456789abcdef0" }
  }
}

variables {
  allowed_destination_cidrs  = ["192.0.2.128/28"]
  trusted_client_cidrs       = ["203.0.113.10/32"]
  git_client_principal_arns  = ["arn:aws:iam::123456789012:role/Developer"]
  destination_repository_url = "https://git.example.com/customer/site.git"
  lambda_image_uri           = "123456789012.dkr.ecr.us-east-1.amazonaws.com/demo@sha256:0000000000000000000000000000000000000000000000000000000000000000"
}

run "restrict_network_and_git" {
  command = apply

  assert {
    condition = (
      toset([for r in aws_route_table.private.route : r.cidr_block]) == var.allowed_destination_cidrs &&
      alltrue([for r in aws_route_table.private.route : r.cidr_block != "0.0.0.0/0"])
    )
    error_message = "Private routes must be exactly the allowlist, never a default route."
  }

  assert {
    condition = (
      length(aws_security_group.lambda.ingress) == 0 &&
      length(aws_security_group.lambda.egress) == 2 &&
      alltrue([for r in aws_security_group.lambda.egress : r.protocol == "tcp" && r.from_port == 443 && r.to_port == 443]) &&
      toset(flatten([for r in aws_security_group.lambda.egress : r.cidr_blocks])) == setunion(var.allowed_destination_cidrs, [aws_subnet.private.cidr_block])
    )
    error_message = "Lambda egress must be HTTPS only, to the allowlist and the private endpoint subnet."
  }

  assert {
    condition = (
      aws_lambda_function.sync.vpc_config[0].subnet_ids == toset([aws_subnet.private.id]) &&
      !aws_lambda_function.sync.vpc_config[0].ipv6_allowed_for_dual_stack
    )
    error_message = "Lambda must run only in the restricted private subnet, without IPv6."
  }

  assert {
    condition = (
      aws_route53_resolver_firewall_rule.allow.priority < aws_route53_resolver_firewall_rule.block.priority &&
      aws_route53_resolver_firewall_rule.block.action == "BLOCK" &&
      aws_route53_resolver_firewall_config.lambda.firewall_fail_open == "DISABLED" &&
      toset(aws_route53_resolver_firewall_domain_list.allowed.domains) == toset([
        "git.example.com", "git-codecommit.us-east-1.amazonaws.com", "secretsmanager.us-east-1.amazonaws.com",
      ])
    )
    error_message = "DNS must resolve only the required hostnames and fail closed."
  }

  assert {
    condition = alltrue([
      for e in aws_vpc_endpoint.private :
      jsondecode(e.policy).Statement[0].Principal.AWS == aws_iam_role.lambda.arn
    ])
    error_message = "Private endpoints must only serve the sync Lambda role."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role.git_client.assume_role_policy).Statement[0].Condition.IpAddress["aws:SourceIp"] == ["203.0.113.10/32"] &&
      jsondecode(aws_iam_role_policy.git_client.policy).Statement[0].Condition.IpAddress["aws:SourceIp"] == ["203.0.113.10/32"] &&
      jsondecode(aws_iam_role_policy.git_client.policy).Statement[0].Resource == "arn:aws:codecommit:us-east-1:123456789012:aem-byo-git"
    )
    error_message = "Role assumption and Git access to the existing repo must require a trusted source IP."
  }

  assert {
    condition = (
      jsondecode(aws_iam_role_policy.lambda.policy).Statement[0].Action == "codecommit:GitPull" &&
      jsondecode(aws_iam_role_policy.lambda.policy).Statement[0].Condition.StringEquals["aws:SourceVpce"] == "vpce-0123456789abcdef0"
    )
    error_message = "Lambda may only pull the source, and only through its private endpoint."
  }


  assert {
    condition = (
      jsondecode(aws_cloudwatch_event_rule.push.event_pattern).detail.referenceName == ["main"] &&
      jsondecode(aws_cloudwatch_event_rule.push.event_pattern).resources == ["arn:aws:codecommit:us-east-1:123456789012:aem-byo-git"] &&
      jsondecode(aws_cloudwatch_event_target.sync.input) == { action = "sync" }
    )
    error_message = "Pushes to main on the source repo must trigger a sync."
  }
}

run "reject_unrestricted_outbound" {
  command = plan
  variables {
    allowed_destination_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.allowed_destination_cidrs]
}

run "reject_unrestricted_clients" {
  command = plan
  variables {
    trusted_client_cidrs = ["0.0.0.0/0"]
  }
  expect_failures = [var.trusted_client_cidrs]
}

run "reject_cross_account_git_client" {
  command = plan
  variables {
    git_client_principal_arns = ["arn:aws:iam::999999999999:role/Other"]
  }
  expect_failures = [aws_iam_role.git_client]
}

run "reject_embedded_credentials" {
  command = plan
  variables {
    destination_repository_url = "https://username:pat@git.example.com/site.git"
  }
  expect_failures = [var.destination_repository_url]
}

run "reject_unpinned_image" {
  command = plan
  variables {
    lambda_image_uri = "123456789012.dkr.ecr.us-east-1.amazonaws.com/demo:latest"
  }
  expect_failures = [var.lambda_image_uri]
}
