# Testmode GitHub Action

Run your [Testmode](https://testmode.ai) browser tests from a workflow. The job
waits for the run and fails when a test fails.

## Setup

1. In Testmode, open **Project settings → API & CI** and create an API key.
2. In your GitHub repository, add it as the secret `TESTMODE_API_KEY`
   (Settings → Secrets and variables → Actions).
3. Add a workflow:

```yaml
name: Testmode
on:
  push:
    branches: [main]
jobs:
  e2e:
    runs-on: ubuntu-latest
    steps:
      - uses: amber-digital-bv/testmode-ai-action@v1
        with:
          api-key: ${{ secrets.TESTMODE_API_KEY }}
          environment: Staging     # id or name; default: the project's default environment
          test-plan: Smoke         # or test-case-ids, or tags
```

To test a deployment first, run this job after your deploy job (`needs: deploy`).

## Inputs

| Input | Default | |
|---|---|---|
| `api-key` | required | A project API key, from a secret |
| `environment` | project default | Environment id or name |
| `test-plan` | | Test plan id or name |
| `test-case-ids` | | Test case ids, comma or space separated |
| `tags` | | Every enabled test case with any of these tags |
| `name` | `<workflow> #<run> · <branch> · <sha>` | Run name in Testmode |
| `wait` | `true` | `false` returns once the run is queued |
| `timeout-minutes` | `30` | Stop waiting after this long (the run goes on) |

Give exactly one of `test-plan`, `test-case-ids` or `tags`.

## Outputs

`run-id`, `run-url`, and `status` (PASSED, FAILED, CANCELED, SKIPPED, or QUEUED
when not waiting).

## Other CI

`run.sh` needs only bash, curl and jq. Set `TESTMODE_API_KEY` and
`TESTMODE_TEST_PLAN` (or `TESTMODE_TAGS`, `TESTMODE_TEST_CASE_IDS`) and run
it. Its header lists every setting.
