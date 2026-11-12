#!/usr/bin/env bash
# Functional tests for Deliverable 5 (compute, storage, database, network). Run from AWS CloudShell
# in the same Region. Screenshot each section's output.
#   ./scripts/functional_tests.sh lab
set -uo pipefail
ENV_NAME="${1:-lab}"; P=satc-$ENV_NAME
out() { aws cloudformation describe-stacks --stack-name "$P-$1" --query "Stacks[0].Outputs[?OutputKey=='$2'].OutputValue" --output text; }
CF_URL=$(out edge StorefrontUrl); ALB=$(out compute AlbDnsName); ASG=$(out compute AutoScalingGroupName)

echo "== COMPUTE: stacks deployed by CloudFormation"
aws cloudformation list-stacks --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE \
  --query "StackSummaries[?starts_with(StackName,'$P')].[StackName,StackStatus]" --output table
echo "== COMPUTE: ASG instances healthy in two AZs"
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --query "AutoScalingGroups[0].Instances[].[InstanceId,AvailabilityZone,LifecycleState,HealthStatus]" --output table
echo "== COMPUTE: ALB health check and load distribution (host name should alternate)"
for i in 1 2 3 4 5 6; do curl -s "http://$ALB/health"; echo; done
echo "== COMPUTE: security group rules"
aws ec2 describe-security-groups --filters Name=group-name,Values="$P-*" \
  --query "SecurityGroups[].{Group:GroupName,In:IpPermissions[].{Port:FromPort,From:join(',',[IpRanges[].CidrIp,UserIdGroupPairs[].GroupId][])}}" --output yaml 2>/dev/null \
  || aws ec2 describe-security-groups --filters Name=tag:Name,Values="$P-sg-*" --output table

echo "== STORAGE: upload to S3 and fetch through CloudFront (second request should be a cache Hit)"
SITE=$(out edge SiteBucketName)
echo "<p>cache test $(date)</p>" > /tmp/cache-test.html
aws s3 cp /tmp/cache-test.html "s3://$SITE/cache-test.html"
for i in 1 2; do curl -sI "$CF_URL/cache-test.html" | grep -iE "^HTTP|x-cache|age:"; done
echo "== STORAGE: bucket policy denies direct access (expect 403)"
curl -s -o /dev/null -w "%{http_code}\n" "https://$SITE.s3.amazonaws.com/cache-test.html"
echo "== STORAGE: versioning and lifecycle"
aws s3api get-bucket-versioning --bucket "$SITE"
aws s3api get-bucket-lifecycle-configuration --bucket "$(out data MediaBucketName)" --query "Rules[].ID"

echo "== DATABASE: instance, Multi-AZ, backups, latest restorable time (proves RPO)"
aws rds describe-db-instances --db-instance-identifier "$P-pg" \
  --query "DBInstances[0].[DBInstanceStatus,MultiAZ,BackupRetentionPeriod,LatestRestorableTime,AvailabilityZone,SecondaryAvailabilityZone]" --output table
aws rds describe-db-snapshots --db-instance-identifier "$P-pg" --snapshot-type automated \
  --query "DBSnapshots[].[DBSnapshotIdentifier,SnapshotCreateTime,Status]" --output table
echo "   Connect with psql from an EC2 instance (SSM Session Manager) - see runbook step D3."

echo "== API: product listing and validation"
curl -s "$CF_URL/api/products?category=pottery" | head -c 400; echo
curl -s -o /dev/null -w "invalid category -> %{http_code} (expect 400)\n" "$CF_URL/api/products?category=weapons"

echo "== NETWORK: route tables"
VPC=$(out network VpcId)
aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" \
  --query "RouteTables[].{Name:Tags[?Key=='Name']|[0].Value,Routes:Routes[].[DestinationCidrBlock||DestinationPrefixListId,GatewayId||NatGatewayId]}" --output yaml
echo "== NETWORK: NAT egress from a private instance (run inside the instance via SSM):"
echo "   curl -s https://checkip.amazonaws.com   # should print the NAT Gateway Elastic IP: $(out network NatGatewayIp)"
echo "   ping -c 3 <private IP of the instance in the other AZ>   # ICMP echo is allowed inside the VPC"
