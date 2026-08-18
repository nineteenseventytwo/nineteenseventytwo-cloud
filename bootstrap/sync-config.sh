#!/usr/bin/env bash
# Copies the bootstrap stacks' outputs into config/aws.json.
#
# Account IDs, the organisation ID and the state bucket name are all decided by
# AWS at create time, and all three are needed by code that runs before any
# credential exists — the GitHub workflows build role ARNs from them with jq,
# with nothing assumed yet. So they are committed, and this script is what puts
# them there, rather than five copy-paste operations that get one digit wrong.
#
# Run it twice during bootstrap:
#   after `make bootstrap-accounts-apply`     -> account IDs, organisation ID
#   after `make bootstrap-foundation-apply`   -> state bucket name
#
# Idempotent. Only fills in what the corresponding stack has actually created;
# a stack that has not run yet is skipped with a note, not an error.
set -euo pipefail

CONFIG="${CONFIG:-config/aws.json}"
ACCOUNTS_DIR="${ACCOUNTS_DIR:-bootstrap/aws/accounts}"
FOUNDATION_DIR="${FOUNDATION_DIR:-bootstrap/aws/foundation}"

command -v jq >/dev/null || { echo "jq is required"; exit 1; }
command -v terraform >/dev/null || { echo "terraform is required"; exit 1; }
[[ -f "$CONFIG" ]] || { echo "$CONFIG not found — run from the repo root"; exit 1; }

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

cp "$CONFIG" "$tmp"

# terraform output on a stack that has never been applied exits non-zero; that
# is a "not yet", not a failure.
stack_output() {
  terraform -chdir="$1" output -json 2>/dev/null || echo '{}'
}

accounts_out=$(stack_output "$ACCOUNTS_DIR")

if [[ "$(jq -r 'has("account_ids")' <<<"$accounts_out")" == "true" ]]; then
  org_id=$(jq -r '.organization_id.value' <<<"$accounts_out")
  jq --arg org "$org_id" '.org.id = $org' "$tmp" > "$tmp.next" && mv "$tmp.next" "$tmp"
  echo "org.id            = $org_id"

  while read -r key id; do
    jq --arg k "$key" --arg v "$id" '.accounts[$k].id = $v' "$tmp" > "$tmp.next" && mv "$tmp.next" "$tmp"
    echo "accounts.$key.id = $id"
  done < <(jq -r '.account_ids.value | to_entries[] | "\(.key) \(.value)"' <<<"$accounts_out")
else
  echo "note: $ACCOUNTS_DIR has no outputs yet — run: make bootstrap-accounts-apply"
fi

foundation_out=$(stack_output "$FOUNDATION_DIR")

if [[ "$(jq -r 'has("state_bucket")' <<<"$foundation_out")" == "true" ]]; then
  bucket=$(jq -r '.state_bucket.value' <<<"$foundation_out")
  alias=$(jq -r '.state_kms_alias.value' <<<"$foundation_out")
  jq --arg b "$bucket" --arg a "$alias" \
    '.state.bucket = $b | .state.kms_alias = $a' "$tmp" > "$tmp.next" && mv "$tmp.next" "$tmp"
  echo "state.bucket      = $bucket"
  echo "state.kms_alias   = $alias"
else
  echo "note: $FOUNDATION_DIR has no outputs yet — run: make bootstrap-foundation-apply"
fi

if cmp -s "$tmp" "$CONFIG"; then
  echo
  echo "$CONFIG already up to date"
else
  mv "$tmp" "$CONFIG"
  trap - EXIT
  echo
  echo "$CONFIG updated — review the diff and commit it"
fi
