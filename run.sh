#!/usr/bin/env bash
# Start a Testmode run and wait for its result. Needs bash, curl and jq.
#
# Used by the GitHub Action (action.yml), and runnable as it is in any other
# CI. Configuration comes from the environment:
#
#   TESTMODE_API_KEY          required, a project API key (tmk_…)
#   TESTMODE_API_URL          default https://api.testmode.ai
#   TESTMODE_ENVIRONMENT      environment id or name; default: the project's default
#   TESTMODE_TEST_PLAN        test plan id or name        } exactly
#   TESTMODE_TEST_CASE_IDS    test case ids, comma/space   } one of
#   TESTMODE_TAGS             tags, comma/space separated  } these
#   TESTMODE_RUN_NAME         run name; in GitHub Actions default "<workflow> #<n> · <ref> · <sha>"
#   TESTMODE_WAIT             "false" to return once the run is queued (default true)
#   TESTMODE_TIMEOUT_MINUTES  give up waiting after this long (default 30)
#   TESTMODE_POLL_SECONDS     seconds between status checks (default 15)
#
# Exit status: 0 the run passed (or was queued, without waiting), 1 it did
# not pass or timed out, 2 the run could not be started or read.

set -euo pipefail

api_url="${TESTMODE_API_URL:-https://api.testmode.ai}"
api_url="${api_url%/}"
timeout_minutes="${TESTMODE_TIMEOUT_MINUTES:-30}"
poll_seconds="${TESTMODE_POLL_SECONDS:-15}"

fail() { echo "::error::$*" >&2; exit 2; }

[ -n "${TESTMODE_API_KEY:-}" ] || fail "No API key. Create one in Testmode under Project settings > API & CI and pass it as a secret."
command -v jq >/dev/null || fail "jq is required"
command -v curl >/dev/null || fail "curl is required"
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::${TESTMODE_API_KEY}"; fi

# "a, b c" -> ["a","b","c"]
to_json_list() { jq -cn --arg s "$1" '$s | split("[,\\s]+"; null) | map(select(length > 0))'; }

name="${TESTMODE_RUN_NAME:-}"
if [ -z "$name" ] && [ -n "${GITHUB_ACTIONS:-}" ]; then
  name="${GITHUB_WORKFLOW} #${GITHUB_RUN_NUMBER} · ${GITHUB_HEAD_REF:-${GITHUB_REF_NAME}} · ${GITHUB_SHA:0:7}"
fi

body=$(jq -cn \
  --arg environment "${TESTMODE_ENVIRONMENT:-}" \
  --arg testPlan "${TESTMODE_TEST_PLAN:-}" \
  --argjson testCaseIds "$(to_json_list "${TESTMODE_TEST_CASE_IDS:-}")" \
  --argjson tags "$(to_json_list "${TESTMODE_TAGS:-}")" \
  --arg name "${name:0:200}" \
  '{}
   + (if $environment != "" then {environment: $environment} else {} end)
   + (if $testPlan != "" then {testPlan: $testPlan} else {} end)
   + (if ($testCaseIds | length) > 0 then {testCaseIds: $testCaseIds} else {} end)
   + (if ($tags | length) > 0 then {tags: $tags} else {} end)
   + (if $name != "" then {name: $name} else {} end)')

# api METHOD PATH [BODY]: sets $status and $response (not in a subshell, so
# call it on its own line). Retries network errors, 429 and 5xx a few times.
api() {
  local method=$1 path=$2 data=${3:-} attempt out
  for attempt in 1 2 3 4 5; do
    out=$(mktemp)
    status=$(curl -sS -o "$out" -w '%{http_code}' -X "$method" "${api_url}${path}" \
      -H "Authorization: Bearer ${TESTMODE_API_KEY}" \
      -H "Content-Type: application/json" \
      -H "User-Agent: testmode-run/1" \
      ${data:+--data "$data"}) || status=000
    response=$(cat "$out"); rm -f "$out"
    case "$status" in
      000|429|5??) if [ "$attempt" -lt 5 ]; then sleep $((attempt * 5)); continue; fi ;;
    esac
    break
  done
}

error_of() { jq -r '.error // empty' <<<"$1" 2>/dev/null || true; }

set_output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi
}

api POST /v1/runs "$body"
run=$response
if [ "$status" != 201 ]; then
  fail "Could not start the run (HTTP $status): $(error_of "$run")"
fi
run_id=$(jq -r .id <<<"$run")
run_url=$(jq -r .url <<<"$run")
set_output run-id "$run_id"
set_output run-url "$run_url"
echo "Started \"$(jq -r .name <<<"$run")\": $(jq -r .totalTests <<<"$run") test(s). $run_url"

if [ "${TESTMODE_WAIT:-true}" = false ]; then
  set_output status QUEUED
  exit 0
fi

deadline=$(( $(date +%s) + timeout_minutes * 60 ))
last=""
while :; do
  api GET "/v1/runs/${run_id}"
  run=$response
  [ "$status" = 200 ] || fail "Could not read the run (HTTP $status): $(error_of "$run")"
  state=$(jq -r .status <<<"$run")
  progress="$state: $(jq -r '.passedTests' <<<"$run") passed, $(jq -r '.failedTests' <<<"$run") failed of $(jq -r '.totalTests' <<<"$run")"
  [ "$progress" != "$last" ] && echo "$progress"
  last=$progress
  [ "$(jq -r .finished <<<"$run")" = true ] && break
  if [ "$(date +%s)" -ge "$deadline" ]; then
    set_output status "$state"
    echo "::error::Gave up after ${timeout_minutes} minutes; the run goes on in Testmode: $run_url" >&2
    exit 1
  fi
  sleep "$poll_seconds"
done

set_output status "$state"

# One line per test; failures carry their summary.
jq -r '.tests[] | "  \(if .status == "PASSED" then "✓" else "✗" end) \(.name // "(deleted test case)") — \(.status)\(if .status != "PASSED" and .summary then ": \(.summary)" else "" end)"' <<<"$run"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Testmode: $(jq -r .name <<<"$run") — ${state}"
    echo
    echo "| Test | Result | Details |"
    echo "|---|---|---|"
    jq -r '.tests[] | "| [\(.name // "(deleted)" | gsub("\\|"; "\\|"))](\(.url)) | \(.status) | \(if .status != "PASSED" then (.summary // "" | gsub("[\\r\\n|]+"; " ")) else "" end) |"' <<<"$run"
    echo
    echo "[Open the run in Testmode]($run_url)"
  } >> "$GITHUB_STEP_SUMMARY"
fi

if [ "$state" != PASSED ]; then
  reason=$(jq -r '.skipReason // empty' <<<"$run")
  echo "::error::Testmode run ${state}${reason:+: $reason}. $run_url" >&2
  exit 1
fi
echo "All tests passed. $run_url"
