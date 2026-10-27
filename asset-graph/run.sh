#!/usr/bin/env bash
# The asset graph (nineteenseventytwo-platform 07 Phase 10.3): Steampipe over
# every account in the org, read-only, run from a workstation. See README.md.
#
#   asset-graph/run.sh                      # every query in queries/
#   asset-graph/run.sh external-trust       # one query, by file name
#
# Requires: an SSO session (`aws sso login --sso-session <name>`), curl,
# unzip or tar, python3. Writes only under build/asset-graph/ (gitignored),
# including the results: this repo is public, and a list of which roles trust
# what is for the person running the query, not for the commit log.
set -euo pipefail

STEAMPIPE_VERSION="v2.4.7"
AWS_PLUGIN_VERSION="1.34.0"
SSO_SESSION="${SSO_SESSION:-nineteenseventytwo-mgmt}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$ROOT/build/asset-graph"
mkdir -p "$WORK/bin" "$WORK/out"

# --- steampipe, pinned and checksum-verified ------------------------------
# Hashes from the release's own asset digests (GitHub), not fetched at run
# time: a download that does not match is refused.
case "$(uname -s)_$(uname -m)" in
  Darwin_arm64)  asset=steampipe_darwin_arm64.zip;    sum=baa9b3030a4b2cef094ba27fb5cec01a04b87dadf1c88955a7629fe28ce87e14 ;;
  Darwin_x86_64) asset=steampipe_darwin_amd64.zip;    sum=16e710605ffb92687241f5a8b45abea27ee5ef9462c8cb084e716a08a5336ab1 ;;
  Linux_aarch64) asset=steampipe_linux_arm64.tar.gz;  sum=641b1d7a112ce75cdae130c71886ce29992506e2b00180ac6c2e5c985fc56f31 ;;
  Linux_x86_64)  asset=steampipe_linux_amd64.tar.gz;  sum=d61ddd2acbfcaf420c712c76f4a5d3741223660c193f7baf3dc3c7f0f388c16e ;;
  *) echo "unsupported platform $(uname -s)_$(uname -m)" >&2; exit 1 ;;
esac
SP="$WORK/bin/steampipe"
if [ ! -x "$SP" ] || ! "$SP" --version 2>/dev/null | grep -q "${STEAMPIPE_VERSION#v}"; then
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/$asset" "https://github.com/turbot/steampipe/releases/download/$STEAMPIPE_VERSION/$asset"
  got="$(shasum -a 256 "$tmp/$asset" | awk '{print $1}')"
  [ "$got" = "$sum" ] || { echo "checksum mismatch for $asset: $got" >&2; exit 1; }
  case "$asset" in
    *.zip) unzip -oq "$tmp/$asset" -d "$WORK/bin" ;;
    *)     tar -xzf "$tmp/$asset" -C "$WORK/bin" ;;
  esac
  rm -rf "$tmp"
fi

# --- audit-only profiles --------------------------------------------------
# One profile per account on the SecurityAudit permission set (identity-
# center.tf: SecurityAudit + ViewOnlyAccess, every account), reusing the
# workstation's existing SSO session and token cache. Generated, not added to
# ~/.aws/config, whose same-named profiles are admin sets: a read-only
# inventory must not be able to change what it reads.
export AWS_CONFIG_FILE="$WORK/aws-config"
python3 - "$ROOT/config/aws.json" "$HOME/.aws/config" "$SSO_SESSION" > "$AWS_CONFIG_FILE" <<'PY'
import json, sys, configparser
cfg = json.load(open(sys.argv[1]))
home = configparser.RawConfigParser()
home.read(sys.argv[2])
section = f"sso-session {sys.argv[3]}"
if not home.has_section(section):
    sys.exit(f"no [{section}] in ~/.aws/config - set SSO_SESSION")
print(f"[{section}]")
for k, v in home.items(section):
    print(f"{k} = {v}")
for key, acct in cfg["accounts"].items():
    print(f"\n[profile audit-{key}]\nsso_session = {sys.argv[3]}\nsso_account_id = {acct['id']}")
    print(f"sso_role_name = SecurityAudit\nregion = {cfg['regions']['primary']}")
PY

# --- steampipe config -------------------------------------------------------
# One connection per account, both allowed regions, and aws_org aggregating
# them: queries name aws_org.<table> and get every account at once.
export STEAMPIPE_INSTALL_DIR="$WORK/steampipe"
mkdir -p "$STEAMPIPE_INSTALL_DIR/config"
python3 - "$ROOT/config/aws.json" "$AWS_PLUGIN_VERSION" > "$STEAMPIPE_INSTALL_DIR/config/aws.spc" <<'PY'
import json, sys
cfg, version = json.load(open(sys.argv[1])), sys.argv[2]
regions = json.dumps(cfg["regions"]["allowed"])
names = []
for key in cfg["accounts"]:
    name = "aws_" + key.replace("-", "_")
    names.append(name)
    print(f'connection "{name}" {{\n  plugin  = "aws@{version}"\n  profile = "audit-{key}"\n  regions = {regions}\n}}\n')
print(f'connection "aws_org" {{\n  plugin      = "aws@{version}"\n  type        = "aggregator"\n  connections = {json.dumps(names)}\n}}')
PY

# Always, not "if missing": install is a no-op when the version is present,
# and `plugin list` cannot be grepped for it - with the plugin absent, its
# error message names the configured aws@<version> too, and a grep matches
# that and skips the install.
"$SP" plugin install "aws@$AWS_PLUGIN_VERSION"

# --- queries ------------------------------------------------------------------
trap '"$SP" service stop >/dev/null 2>&1 || true' EXIT
queries=("$ROOT"/asset-graph/queries/*.sql)
if [ $# -gt 0 ]; then queries=("$ROOT/asset-graph/queries/$1.sql"); fi
for q in "${queries[@]}"; do
  name="$(basename "$q" .sql)"
  "$SP" query "$q" --output csv > "$WORK/out/$name.csv"
  echo "$name: $(($(wc -l < "$WORK/out/$name.csv") - 1)) rows -> build/asset-graph/out/$name.csv"
done
