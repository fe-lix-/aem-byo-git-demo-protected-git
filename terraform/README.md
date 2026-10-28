# BYO Git sync: protected CodeCommit → external HTTPS Git

```
developer (trusted IP) ──git──▶ CodeCommit (existing, IP-protected)
                                   │ push to main → EventBridge
                                   ▼
                     Lambda in private subnet ──HTTPS, allowlisted IPs only──▶ external Git repo → EDS
```

| File | Contents |
|---|---|
| `main.tf` | Existing repo (data source), IP-restricted Git client role, sync Lambda + IAM, push-to-`main` trigger |
| `network.tf` | VPC, NAT, allowlist routes + security group, private endpoints, DNS Firewall |
| `lambda/` | Container image: `git` + `git-remote-codecommit`; `handler.py` |

## Controls

**Protected source repo.** The CodeCommit repo already exists (`source_repository_name`). Terraform only reads it and never creates or deletes it. Developers can't use their own identity directly; they assume `<project>-git-client`. That role works only from `trusted_client_cidrs`, both for role assumption and for every `GitPull`/`GitPush`.

**Lambda egress = allowlist.** The Lambda runs in a private subnet where:
- The route table has a route **only** for each `allowed_destination_cidrs` entry (via NAT). There is no default route.
- The security group allows egress only on TCP/443 to those CIDRs and to the private endpoint subnet.
- CodeCommit and Secrets Manager are reached through VPC endpoints. Their endpoint policies allow only this role, this repo and this secret, so the endpoints can't be used to exfiltrate data to another account.
- DNS Firewall resolves only the destination host and the two endpoint names, and it fails closed. Security groups don't filter the VPC resolver, so this blocks DNS tunnelling.

**Lambda permissions.** It can `GitPull` the source and read the destination secret, and only through its own VPC endpoints. It cannot push to the source. It pushes only `refs/heads/<sync_branch>`, without force. Invokers can't override the URL or the branch.

**Repo encryption.** This configuration assumes the source uses the AWS-managed `aws/codecommit` key. Verify that assumption in your environment; a customer-managed key may require additional KMS permissions and key-policy changes.

Not covered here: other admins in the account can still reach the repo directly. Use SCPs or permission boundaries for that.

## Deploy (separately authorized process; `copilot-readonly` cannot apply)

The examples contain no real account identifiers or destination allowlists.
Run write operations only through your separately authorized deployment process,
with its own credentials and explicit region. The assistant uses only
`copilot-readonly` for read-only inspection.

1. Build the image, push it to ECR (create the repository only if absent) and pin its digest:
   ```sh
   ACCT=YOUR_ACCOUNT_ID; REG=us-east-1; ECR=$ACCT.dkr.ecr.$REG.amazonaws.com
   aws ecr create-repository --repository-name eds-git-sync --image-tag-mutability IMMUTABLE \
     --image-scanning-configuration scanOnPush=true
   aws ecr get-login-password | docker login --username AWS --password-stdin $ECR
   docker build --platform linux/amd64 --provenance=false -t $ECR/eds-git-sync:v1 terraform/lambda
   docker push $ECR/eds-git-sync:v1
   aws ecr describe-images --repository-name eds-git-sync --image-ids imageTag=v1 \
     --query 'imageDetails[0].imageDigest' --output text
   # lambda_image_uri = "$ECR/eds-git-sync@sha256:<digest>"
   ```
2. From `terraform/`, copy `terraform.tfvars.example` to `terraform.tfvars` and replace all placeholders. `allowed_destination_cidrs` is required: obtain approved destination ranges for your Git host. The example uses reserved documentation addresses, not working destinations. Keep real account IDs, principals, repository URLs, image digests, and IP allowlists in ignored local configuration or your private deployment system. Do not put passwords/tokens in Terraform.
3. Choose secure state storage (local is the current default; shared deployments should use a protected remote backend with locking). Run `terraform init`, review `terraform plan`, and apply only after authorization. The provider explicitly uses `aws_profile`; the deployment process must supply its authorized profile rather than `copilot-readonly`.
4. Store destination credentials out of band through the Secrets Manager console in the secret identified by `terraform output -raw destination_secret_arn`. Use JSON keys `username` and `pat` (the latter holds the Git token/password). Do not paste real credentials into shell command arguments or commit a credentials file. The values never go into Terraform state.
5. If the destination filters clients, allow `terraform output lambda_outbound_ip`.

If the source repo is empty, the first `git push origin main` creates the branch and triggers the first sync. Until that branch exists, a manual `sync` fails at the clone step. Populate the destination secret before pushing; the trigger is active after deployment.

## Use

```sh
# Developer (from a trusted IP), with git-remote-codecommit installed
aws sts assume-role --role-arn "$(terraform output -raw git_client_role_arn)" --role-session-name dev
git clone codecommit::us-east-1://aem-byo-git
git push origin main            # → EventBridge → Lambda pushes main to the destination

# Manual runs
aws lambda invoke --function-name eds-byo-git-demo-sync --payload '{"action":"sync"}' out.json
aws lambda invoke --function-name eds-byo-git-demo-sync --payload '{"action":"test-network"}' out.json
```

`test-network` runs these checks:
- The destination must resolve only to allowlisted IPs, and TLS to it must succeed.
- `1.1.1.1:443`, `8.8.8.8:443` and `1.0.0.1:80` must time out.
- `example.org` must return NXDOMAIN.

Logs are in `/aws/lambda/<project>-sync`. Git output is deliberately never logged because it can contain credentials.

## Test (no AWS access needed)

```sh
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform test                       # mocked provider
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s terraform/lambda -p 'test_*.py'
```

## Cost (single AZ)

The main recurring costs are the NAT gateway (about $32/month plus data) and two interface endpoints (about $7/month each). DNS Firewall, Lambda and logs cost very little at demo volumes.
