# Lab runbook: deploy, capture evidence, tear down

Personal working guide for the ITCCA4-34 project. It takes you from an empty AWS account to all 51
screenshots in the report (Appendix A), then back to zero cost. Plan two sessions of about 3 hours.

## 0. Choose your environment

| | AWS Free Plan account (new, after 15 July 2025) | AWS Academy Learner Lab |
|---|---|---|
| Region | us-east-1 recommended | us-east-1 (or us-west-2) only |
| IAM roles | Created by the templates | Not allowed: use `LEARNER_LAB=1` (LabRole) |
| RDS Multi-AZ | Works (not free, uses credits) | Not allowed: deployed single-AZ |
| Multi-Region CloudTrail | Not on the Free Plan (template default is single-Region) | Single-Region |
| CodePipeline / CodeDeploy | Works | May be blocked: deploy with `SKIP_CICD=1` and explain in the report |
| MFA delete (needs root) | Possible | Not possible: show the command only |
| Cost while running | about USD 0.20 per hour (about USD 5 per day) from credits | Lab budget |

Running cost per hour (us-east-1): NAT USD 0.045, RDS Multi-AZ 0.036, ALB about 0.03, WAF about 0.026,
two EC2 0.021, replica 0.018, public IPs 0.02. Delete everything as soon as your screenshots are done.

## 1. Before you deploy (10 minutes)

1. Sign in, switch the console to **us-east-1**, and open **AWS CloudShell** (it has the AWS CLI, Python and git).
2. Billing > Budgets: check there is no other budget alert you want first (the stack creates a USD 150 budget).
3. Upload `satc-platform.zip` in CloudShell (Actions > Upload file), then:
   ```bash
   unzip satc-platform.zip && cd satc-platform && chmod +x scripts/*.sh deploy/scripts/*.sh
   pip install --user boto3 cfn-lint pytest pytest-cov flake8 bandit flask
   cfn-lint cloudformation/*.yaml && pytest -q        # screenshot S25
   ```
4. For CI/CD only: create an empty GitHub repository called `satc-platform` and push this folder to it.

## 2. Deploy (about 40 minutes, mostly waiting for RDS and CloudFront)

```bash
# Free Plan account
GITHUB_OWNER=<your-github-user> ./scripts/deploy.sh lab <your-email>
# Learner Lab
LEARNER_LAB=1 SKIP_CICD=1 ./scripts/deploy.sh lab <your-email>
```

- Confirm the **SNS subscription e-mail** straight away, or alarms and the approval step send nothing.
- If a stack fails: CloudFormation > the stack > Events, read the first `CREATE_FAILED` reason, fix the
  parameter, delete the failed stack and re-run the script (finished stacks are skipped).

## 3. Load the database schema

EC2 > Instances > select a `satc-lab-web` instance > Connect > **Session Manager**, then:

```bash
sudo dnf -y install postgresql16 git unzip
# copy db/schema.sql and db/seed_and_test_queries.sql onto the instance (paste with nano, or pull from GitHub)
SECRET_ARN=$(aws cloudformation describe-stacks --stack-name satc-lab-data --query "Stacks[0].Outputs[?OutputKey=='DbSecretArn'].OutputValue" --output text --region us-east-1)
DB=$(aws cloudformation describe-stacks --stack-name satc-lab-data --query "Stacks[0].Outputs[?OutputKey=='DbEndpoint'].OutputValue" --output text --region us-east-1)
export PGPASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region us-east-1 --query SecretString --output text | python3 -c 'import json,sys;print(json.load(sys.stdin)["password"])')
psql "host=$DB dbname=satc user=satc_admin sslmode=require" -f schema.sql
psql "host=$DB dbname=satc user=satc_admin sslmode=require" -f seed_and_test_queries.sql   # S11, S36, F7-F8
```

In the Learner Lab the instance uses LabRole, which can read the secret. If `aws` commands fail on the
instance, run the two `describe-stacks` commands in CloudShell and paste the values.

## 4. CI/CD (Free Plan account only)

1. Developer Tools > Settings > Connections > `satc-lab-github` > **Update pending connection** > authorise GitHub.
2. Push any small change (e.g. edit `APP_VERSION` in `app/web/app.py`) to `main`.
3. Watch CodePipeline; approve the **Approval** stage from the e-mail or console. Screenshots S26-S28.

## 5. Get a test token and place an order

```bash
POOL=$(aws cloudformation describe-stacks --stack-name satc-lab-security --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text)
CLIENT=$(aws cloudformation describe-stacks --stack-name satc-lab-security --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text)
aws cognito-idp admin-create-user --user-pool-id $POOL --username test@example.com --message-action SUPPRESS
aws cognito-idp admin-set-user-password --user-pool-id $POOL --username test@example.com --password 'Test-Passw0rd!2026' --permanent
TOKEN=$(aws cognito-idp admin-initiate-auth --user-pool-id $POOL --client-id $CLIENT --auth-flow ADMIN_USER_PASSWORD_AUTH \
  --auth-parameters USERNAME=test@example.com,PASSWORD='Test-Passw0rd!2026' --query AuthenticationResult.IdToken --output text)
CF=$(aws cloudformation describe-stacks --stack-name satc-lab-edge --query "Stacks[0].Outputs[?OutputKey=='StorefrontUrl'].OutputValue" --output text)
curl -s -X POST "$CF/api/orders" -H "Authorization: $TOKEN" -H 'Content-Type: application/json' \
  -d '{"items":[{"sku":"POT-001","quantity":2}],"shippingCountry":"DE","paymentMethod":"card"}'     # F13: expect 201
```

## 6. Run the tests (screenshot each output)

```bash
./scripts/functional_tests.sh lab        # S44, F1-F12
./scripts/security_tests.sh "$CF"        # S46, S1-S8
```

- **Inspector** (S48): Inspector > Activate (15-day free trial) > wait about 15 minutes for EC2 and Lambda findings.
- **AWS Config** (S34): Config > 1-click setup, then update the security stack with `EnableConfigRules=true`.
- **Artifact** (S35): AWS Artifact > Reports > search "SOC 2" and "ISO 27001".
- **JMeter** (S49): on your own PC install Java 17+ and Apache JMeter 5.6, then from the `jmeter` folder:
  `jmeter -n -t satc_load_test.jmx -Jhost=<distribution>.cloudfront.net -l results.jtl -e -o report/`.
  Leave the CloudWatch dashboard open during the run for S50-S51 and the ASG Activity tab for S38.
  The load test sends about 100 requests per second for 10 minutes; that is well inside the Lambda, API
  Gateway and DynamoDB free allowances but uses some CloudFront and WAF request charges (cents).
- Fill in the **Actual** and **Result** columns in the report tables from these outputs. Do not invent numbers.

## 7. Screenshots

Work through Appendix A of the report in order (S01-S51). Tips: hide your account ID and e-mail
(or blur them), keep the Region and resource names visible, and capture the whole console panel, not
just a cropped value, so the marker can see it is your live environment.

## 8. Tear down (same day)

```bash
./scripts/teardown.sh lab
```

The script deletes CodeDeploy's extra Auto Scaling groups, empties the buckets, deletes the stacks in reverse
order and lists anything still billable. All five lists at the end must be empty. Next day, check
Billing > Bills. If you enabled MFA delete on the records bucket, disable it with the root user first.
