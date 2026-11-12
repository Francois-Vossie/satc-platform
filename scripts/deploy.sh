#!/usr/bin/env bash
# Deploy all SATC stacks in dependency order.
#
#   ./scripts/deploy.sh lab you@example.com            # AWS Free Tier account (creates IAM roles)
#   LEARNER_LAB=1 ./scripts/deploy.sh lab you@x.com    # AWS Academy Learner Lab (uses LabRole, no Multi-AZ)
#
# Optional env vars: REGION (default: your CLI default), SKIP_CICD=1, GITHUB_OWNER=<user>, REDIS=1 (adds ElastiCache, ~USD 0.017/h)
set -euo pipefail
ENV_NAME="${1:-lab}"
ALERT_EMAIL="${2:?usage: deploy.sh <env> <alert-email>}"
PROJECT=satc
REGION="${REGION:-$(aws configure get region)}"
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)
CF="aws cloudformation deploy --region $REGION --no-fail-on-empty-changeset"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ "${LEARNER_LAB:-0}" == "1" ]]; then
  ROLES=false; MULTI_AZ=false
else
  ROLES=true; MULTI_AZ=true
fi
echo ">> Deploying $PROJECT-$ENV_NAME to $REGION (account $ACCOUNT, create IAM roles: $ROLES, Multi-AZ: $MULTI_AZ)"

$CF --stack-name $PROJECT-$ENV_NAME-network  --template-file cloudformation/01-network.yaml \
    --parameter-overrides EnvName=$ENV_NAME NatGatewayMode=single

$CF --stack-name $PROJECT-$ENV_NAME-security --template-file cloudformation/02-security.yaml \
    --capabilities CAPABILITY_NAMED_IAM --parameter-overrides EnvName=$ENV_NAME CreateIamRoles=$ROLES

$CF --stack-name $PROJECT-$ENV_NAME-data     --template-file cloudformation/03-data.yaml \
    --parameter-overrides EnvName=$ENV_NAME MultiAZ=$MULTI_AZ CreateReadReplica=true BackupRetentionDays=35 \
    CreateRedis=$([[ "${REDIS:-0}" == "1" ]] && echo true || echo false)

# Lambda code and layer must be uploaded to S3 first ("package")
./scripts/build_layer.sh
PKG_BUCKET="$PROJECT-$ENV_NAME-packages-$ACCOUNT"
aws s3 mb "s3://$PKG_BUCKET" --region "$REGION" 2>/dev/null || true
aws s3 sync app/web "s3://$PKG_BUCKET/web/" --exclude "__pycache__/*"     # instances install the app from here at boot
REDIS_HOST=""
if [[ "${REDIS:-0}" == "1" ]]; then
  REDIS_HOST=$(aws cloudformation describe-stacks --region "$REGION" --stack-name $PROJECT-$ENV_NAME-data \
    --query "Stacks[0].Outputs[?OutputKey=='RedisEndpoint'].OutputValue" --output text)
fi
aws cloudformation package --region "$REGION" --template-file cloudformation/04-compute.yaml \
    --s3-bucket "$PKG_BUCKET" --output-template-file build/04-compute.packaged.yaml
$CF --stack-name $PROJECT-$ENV_NAME-compute  --template-file build/04-compute.packaged.yaml \
    --capabilities CAPABILITY_IAM CAPABILITY_AUTO_EXPAND --parameter-overrides EnvName=$ENV_NAME CreateIamRoles=$ROLES \
    RedisHost="$REDIS_HOST"

$CF --stack-name $PROJECT-$ENV_NAME-edge     --template-file cloudformation/05-edge.yaml \
    --parameter-overrides EnvName=$ENV_NAME
SITE_BUCKET=$(aws cloudformation describe-stacks --region "$REGION" --stack-name $PROJECT-$ENV_NAME-edge \
    --query "Stacks[0].Outputs[?OutputKey=='SiteBucketName'].OutputValue" --output text)
aws s3 sync frontend/ "s3://$SITE_BUCKET/" --delete

$CF --stack-name $PROJECT-$ENV_NAME-monitoring --template-file cloudformation/06-monitoring.yaml \
    --parameter-overrides EnvName=$ENV_NAME AlertEmail="$ALERT_EMAIL"

if [[ "${SKIP_CICD:-0}" != "1" ]]; then
  $CF --stack-name $PROJECT-$ENV_NAME-cicd   --template-file cloudformation/07-cicd.yaml \
      --capabilities CAPABILITY_IAM --parameter-overrides EnvName=$ENV_NAME CreateIamRoles=$ROLES \
      GitHubOwner="${GITHUB_OWNER:?set GITHUB_OWNER or SKIP_CICD=1}"
fi

python3 scripts/seed_dynamodb.py --env "$ENV_NAME" --region "$REGION"
echo ">> Done. Outputs:"
for s in network security data compute edge monitoring; do
  aws cloudformation describe-stacks --region "$REGION" --stack-name $PROJECT-$ENV_NAME-$s \
    --query "Stacks[0].Outputs[].[OutputKey,OutputValue]" --output table
done
