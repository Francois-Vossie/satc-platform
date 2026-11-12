# SATC e-commerce platform on AWS (ITCCA4-34 project)

Infrastructure as Code, application code and test assets for the Savanna Artisan Trading
Cooperative (SATC) multi-tier e-commerce platform.

## Repository layout

| Path | Contents |
|---|---|
| `cloudformation/01-network.yaml` | VPC 10.0.0.0/16, 6 subnets in 2 AZs, IGW, NAT, route tables, NACLs, gateway endpoints, flow logs, optional site-to-site VPN |
| `cloudformation/02-security.yaml` | KMS CMK, security groups, IAM roles (EC2Role, LambdaRole, RDSRole), MFA admin group, Cognito, regional WAF, CloudTrail, AWS Config rules |
| `cloudformation/03-data.yaml` | S3 media bucket, RDS PostgreSQL Multi-AZ (35-day backups) + read replica, DynamoDB tables, optional Redis |
| `cloudformation/04-compute.yaml` | ALB, launch template, Auto Scaling group, Lambda functions + layer, API Gateway, SQS DLQ (SAM transform) |
| `cloudformation/05-edge.yaml` | S3 static site, CloudFront (OAC, Origin Shield, HTTPS only), CloudFront WAF |
| `cloudformation/06-monitoring.yaml` | SNS, CloudWatch alarms, KPI dashboard, Logs Insights queries, AWS Budget |
| `cloudformation/07-cicd.yaml` | CodePipeline, CodeBuild, CodeDeploy (staging in-place, production blue/green) |
| `app/lambda/` | Orders and products Lambda functions (Python 3.12) |
| `app/web/` | Flask staff portal on EC2 (deployed by CodeDeploy) |
| `frontend/` | Progressive web app storefront (S3 + CloudFront) |
| `db/` | PostgreSQL schema, indexes, GDPR functions, seed data and test queries |
| `jmeter/` | Load test: 100 concurrent users |
| `scripts/` | deploy, teardown, layer build, seeding, functional and security tests |
| `docs/RUNBOOK.md` | Step-by-step lab guide: deploy, capture screenshots, run tests, tear down |
| `buildspec.yml`, `appspec.yml`, `deploy/` | CodeBuild and CodeDeploy specifications |

## Deploy

```bash
# AWS Free Tier / paid account
GITHUB_OWNER=<your-github-user> ./scripts/deploy.sh lab you@example.com
# AWS Academy Learner Lab (no IAM role creation, no Multi-AZ, no CI/CD stack)
LEARNER_LAB=1 SKIP_CICD=1 ./scripts/deploy.sh lab you@example.com
```

Then load the database schema from an app instance (SSM Session Manager):

```bash
sudo dnf -y install postgresql16
SECRET=$(aws secretsmanager get-secret-value --secret-id <DbSecretArn> --query SecretString --output text)
export PGPASSWORD=$(echo "$SECRET" | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])')
psql "host=<DbEndpoint> dbname=satc user=satc_admin sslmode=require" -f db/schema.sql
```

## Tear down (do this straight after the demonstration)

```bash
./scripts/teardown.sh lab
```

NAT Gateway, RDS, the ALB and public IPv4 addresses are billed per hour even when idle.

## Local checks (same as the CodeBuild stage)

```bash
pip install -r requirements-dev.txt
flake8 --max-line-length 130 app tests && bandit -r app -ll && cfn-lint cloudformation/*.yaml && pytest --cov=app
```
