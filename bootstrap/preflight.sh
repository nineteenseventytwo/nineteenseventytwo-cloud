#!/usr/bin/env bash
# Checks that the console work in docs/00-manual-bootstrap.md is actually done
# before you spend an evening finding out it isn't.
#
# Everything here is a read. It creates nothing, changes nothing, and is safe
# to run at any point — including after the org is fully built, as a smoke test
# that your SSO session still works.
#
#   bootstrap/preflight.sh
#
# Exit code is the number of failed checks, so CI could gate on it if it ever
# needed to.
set -uo pipefail

CONFIG="${CONFIG:-config/aws.json}"

PASS=0
FAIL=0
SKIP=0

c_pass=$'\033[32m'; c_fail=$'\033[31m'; c_skip=$'\033[33m'; c_off=$'\033[0m'
[[ -t 1 ]] || { c_pass=""; c_fail=""; c_skip=""; c_off=""; }

report() {
  local name="$1" status="$2" detail="${3:-}"
  case "$status" in
    pass) PASS=$((PASS + 1)); printf '%s  ok  %s%s\n' "$c_pass" "$c_off" "$name" ;;
    fail) FAIL=$((FAIL + 1)); printf '%sFAIL  %s%s\n      %s\n' "$c_fail" "$c_off" "$name" "$detail" ;;
    skip) SKIP=$((SKIP + 1)); printf '%sskip  %s%s  (%s)\n' "$c_skip" "$c_off" "$name" "$detail" ;;
  esac
}

need() { command -v "$1" >/dev/null 2>&1; }

echo "Preflight — AWS landing zone"
echo

# 1 ------------------------------------------------------------------------
missing=()
for tool in aws terraform jq; do
  need "$tool" || missing+=("$tool")
done
if [[ ${#missing[@]} -eq 0 ]]; then
  report "tooling present (aws, terraform, jq)" pass
else
  report "tooling present (aws, terraform, jq)" fail "missing: ${missing[*]}"
fi

# 2 ------------------------------------------------------------------------
# The floor is the version CI pins, not the oldest version that would work.
#
# 1.11 is the feature floor — S3 native state locking (use_lockfile) is what
# lets this repo have no DynamoDB lock table. But CI runs TF_VERSION, and
# Terraform writes a state file stamped with the version that wrote it. Once CI
# has applied, an older local binary refuses to read that state, with an error
# that arrives mid-run. Keeping the floor equal to what CI pins removes that
# trap entirely.
TF_VERSION="${TF_VERSION:-1.15.8}"

if need terraform; then
  tf_version=$(terraform version -json 2>/dev/null | jq -r '.terraform_version' 2>/dev/null)
  # Lowest of {TF_VERSION, found} being TF_VERSION means found >= TF_VERSION.
  oldest=$(printf '%s\n%s\n' "$TF_VERSION" "$tf_version" | sort -V | head -1)
  if [[ -z "$tf_version" ]]; then
    report "terraform >= $TF_VERSION" fail "could not read terraform version"
  elif [[ "$oldest" == "$TF_VERSION" ]]; then
    report "terraform >= $TF_VERSION" pass
  else
    report "terraform >= $TF_VERSION" fail \
      "found $tf_version — CI pins $TF_VERSION, and state written by a newer Terraform cannot be read by an older one"
  fi
else
  report "terraform >= $TF_VERSION" skip "terraform not installed"
fi

# 3 ------------------------------------------------------------------------
if [[ -f "$CONFIG" ]] && jq -e . "$CONFIG" >/dev/null 2>&1; then
  report "$CONFIG parses" pass
else
  report "$CONFIG parses" fail "missing or not valid JSON"
fi

# 4 ------------------------------------------------------------------------
# An SSO session, not a stored key. If this fails with "Unable to locate
# credentials" the fix is `aws sso login`, never `aws configure`.
if need aws; then
  identity=$(aws sts get-caller-identity --output json 2>/dev/null)
  if [[ -n "$identity" ]]; then
    arn=$(jq -r '.Arn' <<<"$identity")
    report "AWS session active" pass
    printf '        %s\n' "$arn"
    # 4a — the whole design says this should never be an IAM user.
    if [[ "$arn" == *":user/"* ]]; then
      report "session is federated, not an IAM user" fail \
        "you are signed in as an IAM user ($arn). This estate has none by design — use aws sso login"
    else
      report "session is federated, not an IAM user" pass
    fi
  else
    report "AWS session active" fail "run: aws sso login --profile <org>-mgmt"
    report "session is federated, not an IAM user" skip "no session"
  fi
else
  report "AWS session active" skip "aws cli not installed"
  report "session is federated, not an IAM user" skip "aws cli not installed"
fi

# 5 ------------------------------------------------------------------------
if need aws && aws organizations describe-organization >/dev/null 2>&1; then
  org_id=$(aws organizations describe-organization --query 'Organization.Id' --output text 2>/dev/null)
  feature=$(aws organizations describe-organization --query 'Organization.FeatureSet' --output text 2>/dev/null)
  if [[ "$feature" == "ALL" ]]; then
    report "organization exists with all features ($org_id)" pass
  else
    report "organization exists with all features" fail \
      "FeatureSet is '$feature'. SCPs need ALL — see docs/00-manual-bootstrap.md §3"
  fi
else
  report "organization exists with all features" fail \
    "no organization, or no permission to read it. Create it in the console first"
fi

# 6 ------------------------------------------------------------------------
# SCPs, RCPs and declarative policies each have to be enabled as a policy type
# on the root before Terraform can attach one. Forgetting is a mid-apply
# failure with a message that does not name the missing step.
if need aws && aws organizations list-roots >/dev/null 2>&1; then
  enabled=$(aws organizations list-roots \
    --query 'Roots[0].PolicyTypes[?Status==`ENABLED`].Type' --output text 2>/dev/null)
  for want in SERVICE_CONTROL_POLICY RESOURCE_CONTROL_POLICY DECLARATIVE_POLICY_EC2; do
    if [[ "$enabled" == *"$want"* ]]; then
      report "policy type enabled: $want" pass
    else
      report "policy type enabled: $want" fail "enable it on the root — docs/00-manual-bootstrap.md §3"
    fi
  done
else
  report "policy types enabled" skip "cannot list roots"
fi

# 7 ------------------------------------------------------------------------
# The region is a one-way door: moving Identity Center later means deleting
# every user, permission set and assignment.
if need aws; then
  expected_region=$(jq -r '.regions.primary' "$CONFIG" 2>/dev/null)
  idc=$(aws sso-admin list-instances --region "$expected_region" \
    --query 'Instances[0].InstanceArn' --output text 2>/dev/null)
  if [[ -n "$idc" && "$idc" != "None" ]]; then
    report "IAM Identity Center in $expected_region" pass
  else
    report "IAM Identity Center in $expected_region" fail \
      "not found. It is enabled once per organisation, in one region, for good"
  fi
else
  report "IAM Identity Center region" skip "aws cli not installed"
fi

# 8 ------------------------------------------------------------------------
# Not a blocker, but the single cheapest control in the whole build.
if need aws; then
  budgets=$(aws budgets describe-budgets \
    --account-id "$(aws sts get-caller-identity --query Account --output text 2>/dev/null)" \
    --query 'length(Budgets)' --output text 2>/dev/null)
  if [[ -n "$budgets" && "$budgets" != "0" && "$budgets" != "None" ]]; then
    report "budget alarms exist" pass
  else
    report "budget alarms exist" fail \
      "none found. Set \$5/\$10/\$20 in the console before creating anything billable"
  fi
else
  report "budget alarms exist" skip "aws cli not installed"
fi

echo
printf 'passed %d   failed %d   skipped %d\n' "$PASS" "$FAIL" "$SKIP"
exit "$FAIL"
