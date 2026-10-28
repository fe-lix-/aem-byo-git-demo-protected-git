#!/usr/bin/env bash
# Read-only pre-deployment inspection. Makes only Get/Describe/List calls.
# Usage: ./terraform/inspect.sh [repo-name] [project-name]  > inspect.txt 2>&1
set -u

export AWS_PROFILE="copilot-readonly"
export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_PAGER=""
REPO="${1:-aem-byo-git}"
PROJECT="${2:-eds-byo-git-demo}"

section() { printf '\n=== %s\n' "$*"; }
run() { printf '$ aws --profile copilot-readonly %s\n' "$*"; aws --profile copilot-readonly "$@" 2>&1 || true; }

section "Identity (verify the intended target account)"
run sts get-caller-identity

section "Source repository"
run codecommit get-repository --repository-name "$REPO" \
  --query 'repositoryMetadata.[repositoryName,Arn,defaultBranch,kmsKeyId]'
run codecommit list-branches --repository-name "$REPO"
run codecommit get-repository-triggers --repository-name "$REPO" --query triggers

section "Repository KMS key (AWS-managed or CUSTOMER?)"
KEY=$(aws --profile copilot-readonly codecommit get-repository --repository-name "$REPO" \
  --query repositoryMetadata.kmsKeyId --output text 2>/dev/null)
if [ -n "$KEY" ] && [ "$KEY" != "None" ]; then
  run kms describe-key --key-id "$KEY" \
    --query 'KeyMetadata.[KeyManager,KeyState,Description]'
  run kms list-aliases --key-id "$KEY" --query 'Aliases[].AliasName'
  run kms get-key-policy --key-id "$KEY" --policy-name default --query Policy --output text
else
  echo "Could not read kmsKeyId."
fi

section "ECR repositories and recent images (for lambda_image_uri)"
run ecr describe-repositories --query 'repositories[].[repositoryName,repositoryUri]' --output text
for r in $(aws --profile copilot-readonly ecr describe-repositories --query 'repositories[].repositoryName' --output text 2>/dev/null); do
  run ecr describe-images --repository-name "$r" \
    --query "reverse(sort_by(imageDetails,&imagePushedAt))[:3].[imagePushedAt,imageDigest,join(',',imageTags || ['-'])]" \
    --output text
done

section "Name collisions with resources Terraform would create (empty = OK)"
run iam get-role --role-name "$PROJECT-git-client" --query Role.Arn
run iam get-role --role-name "$PROJECT-sync" --query Role.Arn
run lambda get-function --function-name "$PROJECT-sync" --query Configuration.FunctionArn
run logs describe-log-groups --log-group-name-prefix "/aws/lambda/$PROJECT-sync" --query 'logGroups[].logGroupName'
run events describe-rule --name "$PROJECT-push" --query Arn
run secretsmanager list-secrets --filters "Key=name,Values=$PROJECT/" --query 'SecretList[].Name'
run route53resolver list-firewall-rule-groups --query "FirewallRuleGroups[?Name=='$PROJECT'].Id"

section "Existing CodeCommit-triggered EventBridge rules"
run events list-rules --query "Rules[?contains(to_string(EventPattern), 'aws.codecommit')].[Name,State]" --output text

section "Capacity (EIP / VPC / NAT usage in region)"
run ec2 describe-addresses --query 'length(Addresses)'
run ec2 describe-vpcs --query 'length(Vpcs)'
run ec2 describe-nat-gateways --filter Name=state,Values=available --query 'length(NatGateways)'

section "Done"
