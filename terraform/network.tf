# Single-AZ VPC. The Lambda's private subnet can reach only:
#   - allowed_destination_cidrs on TCP/443 (via NAT; route + security group)
#   - CodeCommit and Secrets Manager private endpoints (this account's repo/secret only)
#   - DNS names on the DNS Firewall allowlist (blocks DNS tunnelling, which
#     security groups do not filter)

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "public" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, 0)
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 2, 1)
  availability_zone = data.aws_availability_zones.available.names[0]
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# No default route: only allowlisted CIDRs are routable from the Lambda subnet.
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  dynamic "route" {
    for_each = var.allowed_destination_cidrs
    content {
      cidr_block     = route.value
      nat_gateway_id = aws_nat_gateway.main.id
    }
  }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# --- Security groups ---

resource "aws_security_group" "lambda" {
  name_prefix = "${var.project_name}-lambda-"
  description = "Sync Lambda: no ingress; HTTPS egress to the allowlist and private endpoints only."
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Allowlisted destinations"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = sort(tolist(var.allowed_destination_cidrs))
  }

  egress {
    description = "Private AWS endpoints"
    protocol    = "tcp"
    from_port   = 443
    to_port     = 443
    cidr_blocks = [aws_subnet.private.cidr_block]
  }
}

resource "aws_security_group" "endpoints" {
  name_prefix = "${var.project_name}-endpoints-"
  description = "Private AWS endpoints, reachable only from the sync Lambda."
  vpc_id      = aws_vpc.main.id

  ingress {
    protocol        = "tcp"
    from_port       = 443
    to_port         = 443
    security_groups = [aws_security_group.lambda.id]
  }
}

# --- Private endpoints. Their policies stop the Lambda from using them to
# reach any other repository/secret (e.g. one in an attacker's account). ---

resource "aws_vpc_endpoint" "private" {
  for_each = {
    "git-codecommit" = { action = "codecommit:GitPull", resource = data.aws_codecommit_repository.source.arn }
    "secretsmanager" = { action = "secretsmanager:GetSecretValue", resource = aws_secretsmanager_secret.destination.arn }
  }

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = [aws_subnet.private.id]
  security_group_ids  = [aws_security_group.endpoints.id]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.lambda.arn }
      Action    = each.value.action
      Resource  = each.value.resource
    }]
  })
}

# --- DNS Firewall: resolve only the destination and endpoint names; fail closed ---

resource "aws_route53_resolver_firewall_domain_list" "allowed" {
  name = "${var.project_name}-allowed"
  domains = [
    lower(split("/", var.destination_repository_url)[2]),
    "git-codecommit.${var.aws_region}.amazonaws.com",
    "secretsmanager.${var.aws_region}.amazonaws.com",
  ]
}

resource "aws_route53_resolver_firewall_domain_list" "all" {
  name    = "${var.project_name}-all"
  domains = ["*"]
}

resource "aws_route53_resolver_firewall_rule_group" "lambda" {
  name = var.project_name
}

resource "aws_route53_resolver_firewall_rule" "allow" {
  name                               = "${var.project_name}-allow"
  firewall_rule_group_id             = aws_route53_resolver_firewall_rule_group.lambda.id
  firewall_domain_list_id            = aws_route53_resolver_firewall_domain_list.allowed.id
  firewall_domain_redirection_action = "TRUST_REDIRECTION_DOMAIN"
  action                             = "ALLOW"
  priority                           = 100
}

resource "aws_route53_resolver_firewall_rule" "block" {
  name                    = "${var.project_name}-block"
  firewall_rule_group_id  = aws_route53_resolver_firewall_rule_group.lambda.id
  firewall_domain_list_id = aws_route53_resolver_firewall_domain_list.all.id
  action                  = "BLOCK"
  block_response          = "NXDOMAIN"
  priority                = 200
}

resource "aws_route53_resolver_firewall_rule_group_association" "lambda" {
  name                   = var.project_name
  firewall_rule_group_id = aws_route53_resolver_firewall_rule_group.lambda.id
  vpc_id                 = aws_vpc.main.id
  priority               = 101

  depends_on = [
    aws_route53_resolver_firewall_rule.allow,
    aws_route53_resolver_firewall_rule.block,
  ]
}

resource "aws_route53_resolver_firewall_config" "lambda" {
  resource_id        = aws_vpc.main.id
  firewall_fail_open = "DISABLED"
}
