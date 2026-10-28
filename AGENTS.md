# AGENTS.md

## Scope

This repository contains Terraform setup for the AEM Edge Delivery Services BYO
Git demo. Read `terraform/README.md` before changing infrastructure.

- The existing customer CodeCommit repository is the source of truth; Terraform
  reads it and does not create or delete it.
- EventBridge invokes a private-VPC Lambda on pushes to the configured branch.
- Lambda pushes that branch to an Adobe-hosted HTTPS Git repository, without force.
- EDS consumes the delivery repository, not the protected source directly.
- Code delivery requires successful synchronization. Content publishes separately.
- Do not assume a GitHub remote is the Adobe-hosted destination.

## AWS access and deployment

- Use `aws --profile copilot-readonly <service> <operation>` for every assistant
  AWS operation.
- Perform read-only inspection only. Do not switch profiles or attempt AWS mutations.
- Deployment requires a separately authorized customer process; the inspection
  profile cannot deploy.
- Mocked Terraform tests and Python unit tests do not establish live deployment
  or network readiness.

## Security controls

Preserve trusted-IP conditions on Git client role assumption and Git operations,
endpoint-restricted Lambda source/secret access, allowlisted HTTPS egress, and
fail-closed DNS filtering. Restrictions on the Git client role do not revoke
other existing IAM access; account-wide enforcement is a separate concern.

Never put destination credentials in Terraform variables, state, URLs, or logs.
Populate the Secrets Manager secret out of band. Pin Lambda ECR images by digest
and build for `linux/amd64` to match the configured Lambda architecture.

## Validation

```sh
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s terraform/lambda -p 'test_*.py'
```

Commit `terraform/.terraform.lock.hcl`. Do not commit local variable files,
Terraform state, provider downloads, credentials, or generated inspection output.

## Separate site checkout

`aem-byo-git-public-github/`, when present, is a separate Git repository excluded
from this setup repository. Follow its own `AGENTS.md` for site changes. Do not
stage it as an embedded repository or alter its Git metadata during setup cleanup.
