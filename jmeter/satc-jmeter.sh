#!/bin/bash
# SATC lab - JMeter load test: 100 concurrent users, 60 s ramp-up, 10 minutes in total.
# Run in AWS CloudShell (eu-north-1):   bash satc-jmeter.sh
# Takes about 13 minutes (2 min install + 10 min test + 1 min report). Keep the tab open.
set -e
ALB=satc-lab-alb-393146057.eu-north-1.elb.amazonaws.com
API=q6qc8rftbj.execute-api.eu-north-1.amazonaws.com
USERS=100
DURATION=600
JM=$HOME/apache-jmeter-5.6.3/bin/jmeter
WORK=$HOME/jmeter-run
mkdir -p $WORK && cd $WORK

echo "== 1/4  Installing Java and JMeter 5.6.3 =="
if ! command -v java >/dev/null; then sudo dnf install -y -q java-17-amazon-corretto-headless; fi
if [ ! -x "$JM" ]; then
  curl -s -o /tmp/jm.tgz https://archive.apache.org/dist/jmeter/binaries/apache-jmeter-5.6.3.tgz
  tar xzf /tmp/jm.tgz -C $HOME && rm /tmp/jm.tgz
fi
java -version 2>&1 | head -1

printf "category\npottery\ntextiles\nleather\nwood-carvings\nskincare\njewellery\n" > categories.csv

# Five requests per loop: three to the ALB/EC2 tier, two to API Gateway/Lambda/DynamoDB.
# Think time 0.5-1.5 s after every request (about 90-100 requests/s in total at 100 users),
# which keeps the API under its 50 req/s stage throttle and pushes the ALB above
# 1,000 requests per target per minute, so the target-tracking policy should scale out.
sampler() { # name protocol host path
cat <<EOF
        <HTTPSamplerProxy guiclass="HttpTestSampleGui" testclass="HTTPSamplerProxy" testname="$1">
          <elementProp name="HTTPsampler.Arguments" elementType="Arguments"><collectionProp name="Arguments.arguments"/></elementProp>
          <stringProp name="HTTPSampler.protocol">$2</stringProp>
          <stringProp name="HTTPSampler.domain">$3</stringProp>
          <stringProp name="HTTPSampler.path">$4</stringProp>
          <stringProp name="HTTPSampler.method">GET</stringProp>
          <boolProp name="HTTPSampler.use_keepalive">true</boolProp>
        </HTTPSamplerProxy>
        <hashTree/>
EOF
}

cat > satc_lab_load_test.jmx <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<jmeterTestPlan version="1.2" properties="5.0" jmeter="5.6.3">
  <hashTree>
    <TestPlan guiclass="TestPlanGui" testclass="TestPlan" testname="SATC lab - ${USERS} concurrent users"/>
    <hashTree>
      <ConfigTestElement guiclass="HttpDefaultsGui" testclass="ConfigTestElement" testname="HTTP Request Defaults">
        <elementProp name="HTTPsampler.Arguments" elementType="Arguments"><collectionProp name="Arguments.arguments"/></elementProp>
        <stringProp name="HTTPSampler.connect_timeout">5000</stringProp>
        <stringProp name="HTTPSampler.response_timeout">10000</stringProp>
      </ConfigTestElement>
      <hashTree/>
      <HeaderManager guiclass="HeaderPanel" testclass="HeaderManager" testname="Headers">
        <collectionProp name="HeaderManager.headers">
          <elementProp name="" elementType="Header">
            <stringProp name="Header.name">User-Agent</stringProp>
            <stringProp name="Header.value">Mozilla/5.0 (SATC-JMeter-loadtest)</stringProp>
          </elementProp>
        </collectionProp>
      </HeaderManager>
      <hashTree/>
      <CSVDataSet guiclass="TestBeanGUI" testclass="CSVDataSet" testname="Product categories">
        <stringProp name="filename">categories.csv</stringProp>
        <stringProp name="variableNames">category</stringProp>
        <boolProp name="ignoreFirstLine">true</boolProp>
        <stringProp name="delimiter">,</stringProp>
        <boolProp name="recycle">true</boolProp>
        <boolProp name="stopThread">false</boolProp>
        <stringProp name="shareMode">shareMode.all</stringProp>
      </CSVDataSet>
      <hashTree/>
      <ThreadGroup guiclass="ThreadGroupGui" testclass="ThreadGroup" testname="Shoppers">
        <stringProp name="ThreadGroup.on_sample_error">continue</stringProp>
        <elementProp name="ThreadGroup.main_controller" elementType="LoopController" guiclass="LoopControlPanel" testclass="LoopController">
          <boolProp name="LoopController.continue_forever">false</boolProp>
          <intProp name="LoopController.loops">-1</intProp>
        </elementProp>
        <stringProp name="ThreadGroup.num_threads">${USERS}</stringProp>
        <stringProp name="ThreadGroup.ramp_time">60</stringProp>
        <boolProp name="ThreadGroup.scheduler">true</boolProp>
        <stringProp name="ThreadGroup.duration">${DURATION}</stringProp>
        <stringProp name="ThreadGroup.delay">0</stringProp>
      </ThreadGroup>
      <hashTree>
$(sampler "01 Staff portal home (ALB + EC2)" http $ALB /app/)
$(sampler "02 Browse category (API + Lambda + DynamoDB GSI)" https $API '/prod/api/products?category=${category}')
$(sampler "03 Product list (ALB + EC2 + DynamoDB)" http $ALB /app/products)
$(sampler "04 Product detail (API + Lambda + DynamoDB)" https $API /prod/api/products/POT-001)
$(sampler "05 Staff portal home again (ALB + EC2)" http $ALB /app/)
        <ResponseAssertion guiclass="AssertionGui" testclass="ResponseAssertion" testname="HTTP 200">
          <collectionProp name="Asserion.test_strings"><stringProp name="49586">200</stringProp></collectionProp>
          <stringProp name="Assertion.test_field">Assertion.response_code</stringProp>
          <boolProp name="Assertion.assume_success">false</boolProp>
          <intProp name="Assertion.test_type">8</intProp>
        </ResponseAssertion>
        <hashTree/>
        <DurationAssertion guiclass="DurationAssertionGui" testclass="DurationAssertion" testname="Response under 1 s (SLO)">
          <stringProp name="DurationAssertion.duration">1000</stringProp>
        </DurationAssertion>
        <hashTree/>
        <UniformRandomTimer guiclass="UniformRandomTimerGui" testclass="UniformRandomTimer" testname="Think time 0.5-1.5 s">
          <stringProp name="ConstantTimer.delay">500</stringProp>
          <stringProp name="RandomTimer.range">1000</stringProp>
        </UniformRandomTimer>
        <hashTree/>
      </hashTree>
    </hashTree>
  </hashTree>
</jmeterTestPlan>
EOF

echo "== 2/4  Running: ${USERS} users, 60 s ramp-up, ${DURATION} s in total (started $(date +%H:%M:%S) UTC) =="
echo "   A 'summary' line appears every 30 s. Now open EC2 > Auto Scaling groups > satc-lab-web-asg > Activity."
rm -rf results.jtl report
JVM_ARGS="-Xms512m -Xmx1g" $JM -n -t satc_lab_load_test.jmx -l results.jtl -e -o report -Jsummariser.interval=30

echo
echo "== 3/4  Results per request type (from the JMeter HTML report) =="
python3 - <<'PY'
import json
s = json.load(open("report/statistics.json"))
print(f"{'Request':52} {'Samples':>8} {'Err %':>6} {'Avg':>6} {'p90':>6} {'p95':>6} {'p99':>6} {'Max':>6} {'Req/s':>6}")
for k, v in s.items():
    name = "TOTAL" if k == "Total" else k
    print(f"{name[:52]:52} {v['sampleCount']:>8} {v['errorPct']:>6.2f} {v['meanResTime']:>6.0f} {v['pct1ResTime']:>6.0f} "
          f"{v['pct2ResTime']:>6.0f} {v['pct3ResTime']:>6.0f} {v['maxResTime']:>6.0f} {v['throughput']:>6.1f}")
print("(times in ms; error % counts any response that is not HTTP 200 or takes longer than 1 s)")
PY
echo
echo "   Response codes:"
awk -F, 'NR>1 {c[$4]++} END {for (k in c) printf "     HTTP %s: %d\n", k, c[k]}' results.jtl

echo
echo "== 4/4  Packing the HTML report =="
rm -f satc-jmeter-report.zip
(cd report && zip -qr ../satc-jmeter-report.zip .) 2>/dev/null || { sudo dnf install -y -q zip && (cd report && zip -qr ../satc-jmeter-report.zip .); }
echo "   Download it: Actions > Download file > jmeter-run/satc-jmeter-report.zip, unzip it and open index.html"
echo "Finished $(date +%H:%M:%S) UTC"
