# --- Protected source repository (existing; not created or destroyed here) ---

data "aws_codecommit_repository" "source" {
  repository_name = var.source_repository_name
}


# Developers assume this role to pull/push; both the assumption and every Git
# call must come from a trusted public IP.
resource "aws_iam_role" "git_client" {
  name = "${var.project_name}-git-client"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = sort(tolist(var.git_client_principal_arns)) }
      Action    = "sts:AssumeRole"
      Condition = { IpAddress = { "aws:SourceIp" = sort(tolist(var.trusted_client_cidrs)) } }
    }]
  })

  lifecycle {
    precondition {
      condition = alltrue([
        for arn in var.git_client_principal_arns :
        split(":", arn)[4] == data.aws_caller_identity.current.account_id
      ])
      error_message = "Git client principals must belong to this AWS account."
    }
  }
}

resource "aws_iam_role_policy" "git_client" {
  role = aws_iam_role.git_client.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = ["codecommit:GitPull", "codecommit:GitPush"]
        Resource  = data.aws_codecommit_repository.source.arn
        Condition = { IpAddress = { "aws:SourceIp" = sort(tolist(var.trusted_client_cidrs)) } }
      }
    ]
  })
}

# --- Sync Lambda ("CI/CD"): push sync_branch to the external HTTPS repo ---

# Populate out of band so the PAT never enters Terraform state:
# {"username": "...", "pat": "..."}
resource "aws_secretsmanager_secret" "destination" {
  name_prefix             = "${var.project_name}/destination-"
  description             = "Destination Git HTTPS credentials: JSON with username and pat."
  recovery_window_in_days = 7
}

resource "aws_iam_role" "lambda" {
  name = "${var.project_name}-sync"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Read-only source access and the destination secret, usable only through this
# VPC's private endpoints (leaked role credentials are useless elsewhere).
resource "aws_iam_role_policy" "lambda" {
  role = aws_iam_role.lambda.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Action    = "codecommit:GitPull"
        Resource  = data.aws_codecommit_repository.source.arn
        Condition = { StringEquals = { "aws:SourceVpce" = aws_vpc_endpoint.private["git-codecommit"].id } }
      },
      {
        Effect    = "Allow"
        Action    = "secretsmanager:GetSecretValue"
        Resource  = aws_secretsmanager_secret.destination.arn
        Condition = { StringEquals = { "aws:SourceVpce" = aws_vpc_endpoint.private["secretsmanager"].id } }
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "sync" {
  name              = "/aws/lambda/${var.project_name}-sync"
  retention_in_days = 14
}

resource "aws_lambda_function" "sync" {
  function_name                  = "${var.project_name}-sync"
  role                           = aws_iam_role.lambda.arn
  package_type                   = "Image"
  image_uri                      = var.lambda_image_uri
  architectures                  = ["x86_64"]
  timeout                        = 600
  memory_size                    = 512
  reserved_concurrent_executions = 1

  ephemeral_storage {
    size = 1024
  }

  vpc_config {
    subnet_ids                  = [aws_subnet.private.id]
    security_group_ids          = [aws_security_group.lambda.id]
    ipv6_allowed_for_dual_stack = false
  }

  environment {
    variables = {
      SOURCE_REPOSITORY          = data.aws_codecommit_repository.source.repository_name
      DESTINATION_REPOSITORY_URL = var.destination_repository_url
      DESTINATION_SECRET_ARN     = aws_secretsmanager_secret.destination.arn
      SYNC_BRANCH                = var.sync_branch
      ALLOWED_DESTINATION_CIDRS  = jsonencode(sort(tolist(var.allowed_destination_cidrs)))
    }
  }

  # The function must never run before its egress restrictions exist.
  depends_on = [
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_cloudwatch_log_group.sync,
    aws_route_table_association.private,
    aws_route53_resolver_firewall_rule_group_association.lambda,
    aws_route53_resolver_firewall_config.lambda,
  ]
}

# --- CI/CD trigger: every push to sync_branch runs the sync ---

resource "aws_cloudwatch_event_rule" "push" {
  name = "${var.project_name}-push"
  event_pattern = jsonencode({
    source        = ["aws.codecommit"]
    "detail-type" = ["CodeCommit Repository State Change"]
    resources     = [data.aws_codecommit_repository.source.arn]
    detail = {
      event         = ["referenceCreated", "referenceUpdated"]
      referenceType = ["branch"]
      referenceName = [var.sync_branch]
    }
  })
}

resource "aws_cloudwatch_event_target" "sync" {
  rule  = aws_cloudwatch_event_rule.push.name
  arn   = aws_lambda_function.sync.arn
  input = jsonencode({ action = "sync" })
}

resource "aws_lambda_permission" "events" {
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.sync.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.push.arn
}
