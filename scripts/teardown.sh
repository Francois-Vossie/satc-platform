#!/usr/bin/env bash
# Delete every SATC stack in reverse dependency order so no billable resource is left running
# (NAT Gateway, RDS, ALB and Elastic IPs charge by the hour).
#   ./scripts/teardown.sh lab
set -euo pipefail
ENV_NAME="${1:-lab}"
PROJECT=satc
REGION="${REGION:-$(aws configure get region)}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

empty_bucket() {   # versioned buckets must be emptied (all versions) before CloudFormation can delete them
  local b="$1"
  aws s3api head-bucket --bucket "$b" 2>/dev/null || return 0
  echo "   emptying s3://$b"
  python3 - "$b" <<'PY'
import sys, boto3
b = boto3.resource("s3").Bucket(sys.argv[1])
b.object_versions.delete()
b.objects.all().delete()
PY
}

# NOTE: if MFA delete was enabled on the records bucket, the root user must first run
#   aws s3api put-bucket-versioning --bucket satc-<env>-records-<account> --versioning-configuration Status=Enabled,MFADelete=Disabled --mfa "<arn> <code>"
for b in site artifacts media records cloudtrail alblogs packages; do
  empty_bucket "$PROJECT-$ENV_NAME-$b-$ACCOUNT"
done
empty_bucket "$PROJECT-$ENV_NAME-flowlogs-$ACCOUNT-$REGION"

# CodeDeploy blue/green creates copies of the Auto Scaling group outside CloudFormation - delete them first
for asg in $(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --query "AutoScalingGroups[?starts_with(AutoScalingGroupName,'CodeDeploy_')].AutoScalingGroupName" --output text); do
  echo "   deleting CodeDeploy-created ASG $asg"
  aws autoscaling delete-auto-scaling-group --region "$REGION" --auto-scaling-group-name "$asg" --force-delete
done

for s in cicd monitoring edge compute data security network; do
  stack="$PROJECT-$ENV_NAME-$s"
  if aws cloudformation describe-stacks --region "$REGION" --stack-name "$stack" >/dev/null 2>&1; then
    echo ">> deleting $stack"
    aws cloudformation delete-stack --region "$REGION" --stack-name "$stack"
    aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$stack"
  fi
done
aws s3 rb "s3://$PROJECT-$ENV_NAME-packages-$ACCOUNT" --region "$REGION" 2>/dev/null || true

echo ">> Checking for anything still billable in $REGION"
aws ec2 describe-nat-gateways --region "$REGION" --filter Name=state,Values=available --query "NatGateways[].NatGatewayId"
aws ec2 describe-addresses --region "$REGION" --query "Addresses[].PublicIp"
aws rds describe-db-instances --region "$REGION" --query "DBInstances[].DBInstanceIdentifier"
aws rds describe-db-snapshots --region "$REGION" --snapshot-type manual --query "DBSnapshots[].DBSnapshotIdentifier"
aws elbv2 describe-load-balancers --region "$REGION" --query "LoadBalancers[].LoadBalancerName"
echo ">> All lists above should be empty. Also check Billing > Bills the next day."
