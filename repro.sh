#!/usr/bin/env bash
# Runs the head loop and the fixed loop with the REAL AWS CLI against a local EC2 fixture, one row per run,
# and fails if any row differs from the expected outcome.
# Jenkins executes the step as "sh -xe" on an agent whose /bin/sh is bash, hence "bash -e" here.
set -uo pipefail
cd "$(dirname "$0")"

# Fail closed. Every EC2 call must go to the local fixture through the logging wrapper, never to AWS.
export PATH="$PWD:/usr/local/bin:$PATH"
if ! grep -q "aws wrapper for the PR 4441 reproducer" "$(command -v aws)" 2>/dev/null; then
  echo "refusing to run: 'aws' resolves to $(command -v aws), not the logging wrapper" >&2
  exit 2
fi
unset AWS_PROFILE AWS_SESSION_TOKEN AWS_DEFAULT_PROFILE AWS_IGNORE_CONFIGURED_ENDPOINT_URLS AWS_ENDPOINT_URL AWS_ENDPOINT_URL_EC2
export AWS_ACCESS_KEY_ID=fixture AWS_SECRET_ACCESS_KEY=fixture AWS_DEFAULT_REGION=us-east-2
export AWS_CONFIG_FILE=/dev/null AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true AWS_PAGER=""
export NO_PROXY=127.0.0.1 no_proxy=127.0.0.1
# same retry behaviour the pmm agent showed in production ("reached max retries: 2"): CLI v2 standard mode, 3 attempts
export AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=3
fixture_port=4566
export FIXTURE_URL="http://127.0.0.1:${fixture_port}"

export ARCH=arm64 INSTANCE_TYPE=t4g.xlarge CANDIDATE_TYPES="t4g.xlarge m6g.xlarge m7g.xlarge"
export USE_ONDEMAND=false VM_NAME=pmm-repro OWNER=repro DAYS=1

fixture_pid=""
cleanup() {
  if [[ -n "$fixture_pid" ]]; then
    kill "$fixture_pid" 2>/dev/null
    wait "$fixture_pid" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

wait_for_fixture() {
  local expected="$1" answer
  for _ in $(seq 1 50); do
    answer=$(python3 -c "import urllib.request; print(urllib.request.urlopen('${FIXTURE_URL}/healthz', timeout=0.5).read().decode())" 2>/dev/null || true)
    if [[ "$answer" == "$expected" ]]; then
      return 0
    fi
    if ! kill -0 "$fixture_pid" 2>/dev/null; then
      echo "fixture for ${expected} exited early" >&2
      return 1
    fi
    sleep 0.1
  done
  echo "fixture for ${expected} did not answer /healthz" >&2
  return 1
}

# expected outcome per "scenario version": calls http exit message-regex
declare -A EXPECT=(
  ["success head"]="1 1 0 ^launched"
  ["success fixed"]="1 1 0 ^launched"
  ["capacity-then-success head"]="3 7 0 ^launched"
  ["capacity-then-success fixed"]="3 7 0 ^launched"
  ["all-capacity head"]="9 27 1 ^Could not launch"
  ["all-capacity fixed"]="9 27 1 ^Could not launch"
  ["bad-keypair head"]="9 9 1 ^Could not launch"
  ["bad-keypair fixed"]="1 1 1 InvalidKeyPair.NotFound"
  ["quota head"]="9 9 1 ^Could not launch"
  ["quota fixed"]="1 1 1 MaxSpotInstanceCountExceeded"
  ["subnet-full head"]="2 2 0 ^launched"
  ["subnet-full fixed"]="2 2 0 ^launched"
  ["no-subnets head"]="0 0 1 ^Could not launch"
  ["no-subnets fixed"]="0 0 254 UnauthorizedOperation"
)
failures=0

run_case() {
  local scenario="$1" version="$2"
  local workdir
  workdir=$(mktemp -d)
  export SCENARIO="$scenario" CALLS_LOG="$workdir/calls.log" REQUESTS_LOG="$workdir/requests.log"
  : > "$CALLS_LOG"
  : > "$REQUESTS_LOG"
  python3 ./fixture.py "$fixture_port" &
  fixture_pid=$!
  wait_for_fixture "$scenario" || exit 1
  (
    cd "$workdir" || exit 99
    bash -e "$OLDPWD/launch-${version}.sh" > out.log 2>&1
    echo $? > exit.code
  )
  cleanup
  fixture_pid=""
  local calls requests exit_code message verdict
  calls=$(wc -l < "$CALLS_LOG")
  requests=$(wc -l < "$REQUESTS_LOG")
  exit_code=$(cat "$workdir/exit.code")
  if [[ "$exit_code" == "0" ]]; then
    message="launched $(cat "$workdir/AMI_ID") with IP $(cat "$workdir/IP")"
  else
    # the last line that is not xtrace or blank is what the operator reads at the bottom of the console
    message=$(grep -vE '^\++ |^$' "$workdir/out.log" | tail -1)
  fi
  read -r want_calls want_requests want_exit want_regex <<< "${EXPECT["$scenario $version"]}"
  if [[ "$calls" == "$want_calls" && "$requests" == "$want_requests" && "$exit_code" == "$want_exit" ]] && grep -qE "$want_regex" <<< "$message"; then
    verdict=PASS
  else
    verdict="FAIL (expected calls=$want_calls http=$want_requests exit=$want_exit message~/$want_regex/)"
    failures=$((failures + 1))
  fi
  printf '%-23s %-7s %-6s %-6s %-5s %-5s %s\n' "$scenario" "$version" "$calls" "$requests" "$exit_code" "${verdict%% *}" "$message"
  if [[ "$verdict" != PASS ]]; then
    echo "    $verdict"
  fi
  if [[ "${VERBOSE:-0}" == "1" ]]; then
    sed 's/^/    /' "$workdir/out.log"
  fi
  rm -rf "$workdir"
}

echo "aws: $(/opt/aws-bin/aws --version)"
printf '%-23s %-7s %-6s %-6s %-5s %-5s %s\n' SCENARIO VERSION CALLS HTTP EXIT CHECK LAST_MESSAGE
for scenario in success capacity-then-success all-capacity bad-keypair quota subnet-full no-subnets; do
  for version in head fixed; do
    run_case "$scenario" "$version"
  done
done

cat <<'EOF'

CALLS = run-instances invocations by the loop. HTTP = RunInstances requests the fixture received, so
HTTP > CALLS shows the CLI retrying capacity refusals (HTTP 500) three times. CHECK compares every row
with the expected outcome. Read the bad-keypair, quota and no-subnets rows: at head all three end with
the capacity message after 9, 9 and 0 attempts, the fixed loop stops on the first attempt with the real
error. Capacity rows and the subnet-full fallback behave the same in both versions. VERBOSE=1 prints
every run's console.
EOF

if (( failures > 0 )); then
  echo "RESULT: ${failures} row(s) differ from the expected outcome" >&2
  exit 1
fi
echo "RESULT: all rows match the expected outcome"
