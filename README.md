# AEM Edge Delivery Services: BYO Git Setup

Infrastructure and deployment guidance for synchronizing a protected customer
CodeCommit repository to an Adobe-hosted Git delivery repository.

```text
Customer CodeCommit repository (source of truth)
  -> EventBridge on pushes to the configured branch
  -> Lambda in a private VPC
  -> Adobe-hosted Git repository
  -> AEM Edge Delivery Services
```

EDS does not need direct access to the protected source. Code is delivered only
after synchronization succeeds; content authoring and publishing are separate.
Do not assume a GitHub remote is the Adobe-hosted delivery repository.

## Project layout

- [`terraform/`](terraform/README.md): infrastructure, configuration template,
  Lambda implementation, tests, and deployment instructions.
- `terraform/inspect.sh`: read-only AWS pre-deployment inspection.
- `scripts/configure-byogit.py`: configure the EDS Cloud Manager source and secret.
- [`SECURITY.md`](SECURITY.md): public-sharing checklist and sensitive-data handling.
- `AGENTS.md`: guidance for coding agents working on this setup.

`aem-byo-git-public-github/`, when present locally, is a separate site Git
checkout and is excluded from this repository. Run site-specific Node.js,
linting, and AEM development commands from that checkout, following its README.

## Validate locally

Requires Terraform >= 1.7 and < 2.0, plus Python 3. These tests do not provision
AWS resources.

```sh
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform fmt -check -recursive
terraform -chdir=terraform validate
terraform -chdir=terraform test
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s terraform/lambda -p 'test_*.py'
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover \
  -s scripts -p 'test_*.py'
```

## Before deployment

See [`terraform/README.md`](terraform/README.md) and
[`terraform/terraform.tfvars.example`](terraform/terraform.tfvars.example).

- Confirm the AWS account, region, and existing CodeCommit repository.
- Configure trusted client public CIDRs and same-account IAM principals.
- Obtain the actual Adobe-hosted HTTPS Git URL and supply its approved IP ranges
  in `allowed_destination_cidrs`; no environment-specific allowlist is shipped.
- Build the Lambda image for `linux/amd64`, publish it to ECR, and pin its digest.
- Agree on secure Terraform state storage and an authorized deployment process.
- Prepare destination credentials for out-of-band Secrets Manager provisioning;
  never put the PAT in Terraform variables or state.
- Confirm source branch availability and destination push permissions/history.

The supplied `copilot-readonly` profile is for inspection only and cannot deploy.
The provider explicitly selects `aws_profile`; an authorized customer deployment
process must supply the appropriate credentials/profile separately.

## Configure the EDS BYO Git source

Run this from an interactive terminal with Python 3 (no extra dependencies):

```sh
python3 scripts/configure-byogit.py \
  --org YOUR_ORG \
  --site YOUR_SITE \
  --program-id YOUR_PROGRAM_ID \
  --repo-id YOUR_REPOSITORY_ID
```

The script reads the token from the `HLX_TOKEN` environment variable. If it is
unset, it prompts with input hidden (macOS/Linux terminal). An explicitly empty
or invalid value is rejected. Supply the variable through your secret manager
or a hidden shell prompt; avoid putting the token literally in shell history.
Unset `HLX_TOKEN` when finished.

Also export `CM_SECRET` with the secret from Cloud Manager, using your secret
manager or a hidden shell prompt (never a literal secret in shell history).
It is required; the script validates both credentials before sending requests.

The script first **creates or updates the site's `cm-byog` secret** via
`POST https://admin.hlx.page/config/<org>/sites/<site>/secrets/cm-byog.json`,
with JSON `{"value": "<CM_SECRET>"}`. It then **updates the code configuration**
via `POST https://admin.hlx.page/config/<org>/sites/<site>/code.json`, using the
Cloud Manager BYO Git endpoints and `secretId: cm-byog`.

The token must have permission to configure that site. Neither credential is
saved or passed through command-line arguments; response bodies are not printed.
Do not enable HTTP debug logging. HTTP errors return a nonzero exit status,
redirects are not followed, and a failed secret upload stops the script before
the code update. These requests are not atomic: if the code update fails, the
secret may already have been updated. Unset both `HLX_TOKEN` and `CM_SECRET`
when finished.

This selects the Adobe-hosted delivery repository for EDS; it does not provision
the repository, synchronize source code, or publish content.

## Read-only AWS inspection

All assistant AWS operations must explicitly use the inspection profile:

```sh
aws --profile copilot-readonly sts get-caller-identity
```

Generated inspection output (`inspect.txt`), local Terraform variables, state,
and provider downloads are excluded from Git. Commit `.terraform.lock.hcl`.
