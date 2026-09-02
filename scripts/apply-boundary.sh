#!/usr/bin/env bash
#
# apply-boundary.sh
#
# Applies a change to one or more member accounts' TerraformDeploy
# permissions boundary (module.terraform_deploy_boundary), using your SSO
# AdministratorAccess login for each account — NOT TerraformDeploy, and NOT
# BreakGlassAdmin.
#
# --------------------------------------------------------------------
# WHY THIS EXISTS
# --------------------------------------------------------------------
# TerraformDeploy is deliberately not allowed to modify its own permissions
# boundary (see modules/terraform-deploy-boundary/main.tf's header — "not
# editable by TerraformDeploy itself"). So any change to that boundary
# CANNOT be applied by CI: the push-triggered `terraform-apply` runs as
# TerraformDeploy, which has read-only access to
# TerraformDeployPermissionsBoundary and will fail on iam:CreatePolicyVersion.
#
# breakglass-bootstrap.sh does not help here either — its own header says so
# under "WHAT THIS DOES NOT COVER": it still assumes TerraformDeploy, and the
# boundary applies to that role no matter how it's assumed.
#
# The boundary has to be applied by a genuinely separate admin identity that
# ISN'T bound by it. You already have one: `james.admin` (or whoever) via SSO
# AdministratorAccess, which each ~/.aws/config profile
# (development / production / network / ...) logs straight into the matching
# account. That identity is a full admin in the account, is not
# TerraformDeploy, and is not constrained by TerraformDeployPermissionsBoundary.
#
# --------------------------------------------------------------------
# WHAT IT DOES, PER ACCOUNT
# --------------------------------------------------------------------
#   1. Makes sure the account's SSO session is live (aws sso login if not).
#   2. Confirms the profile really lands in that account (cross-checks the
#      account ID against SSM /organizations/accounts/<account>).
#   3. cd member-accounts/<account>, terraform init.
#   4. terraform plan -target=<the boundary policy resource> -out=<tmp>.
#   5. Inspects the saved plan: if it would change ANYTHING other than the
#      boundary policy itself, it aborts that account and moves on — a
#      -target apply can pull in dependencies, and this script is only ever
#      meant to move the boundary.
#   6. Shows the plan and waits for you to type `yes` (unless --yes).
#   7. terraform apply <tmp>.
#
# It expects the boundary change to be present in your working tree — check
# out the PR branch first, run this for each affected account, then merge.
# The normal member-account CI apply for that PR will then see the boundary
# already matches and just carry on with the rest of the change.
#
# Running it with no pending boundary change is harmless: plan shows "No
# changes" and the account is skipped.
#
# --------------------------------------------------------------------
# Requires: aws CLI (v2, SSO-configured), terraform, jq; one SSO profile per
# account in ~/.aws/config, each with an AdministratorAccess permission set,
# plus a `management` profile for the read-only account-ID cross-check.
#
# Usage:
#   ./scripts/apply-boundary.sh development                 # one account
#   ./scripts/apply-boundary.sh development production       # several
#   ./scripts/apply-boundary.sh                             # all six
#   ./scripts/apply-boundary.sh --yes development            # no prompt
#   TARGET='module.terraform_deploy_boundary' \
#     ./scripts/apply-boundary.sh network                    # different target
#
# After it finishes: re-run (or let CI run) the normal Terraform Apply for
# the merged PR — no separate step needed, the boundary is already live.

set -euo pipefail

ALL_ACCOUNTS=(network development monitoring production security security_analytics)
MGMT_PROFILE="${MGMT_PROFILE:-management}"
TARGET="${TARGET:-module.terraform_deploy_boundary.aws_iam_policy.terraform_deploy_boundary}"
AUTO_APPROVE="${BOUNDARY_APPLY_YES:-0}"

# A plan may only touch resources inside this module. Anything else means
# -target pulled in something unexpected, and that account is skipped.
EXPECTED_PREFIX="module.terraform_deploy_boundary."

ACCOUNTS=()
for a in "$@"; do
  case "$a" in
    --yes|-y) AUTO_APPROVE=1 ;;
    -*) echo "Unknown flag: $a" >&2; exit 2 ;;
    *) ACCOUNTS+=("$a") ;;
  esac
done
if [ "${#ACCOUNTS[@]}" -eq 0 ]; then
  ACCOUNTS=("${ALL_ACCOUNTS[@]}")
fi

for bin in aws terraform jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "❌ '$bin' not found on PATH." >&2; exit 1; }
done

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || { echo "❌ Run this from inside the Terraform-platform repo." >&2; exit 1; }

PLAN_FILE="$(mktemp)"
JSON_FILE="$(mktemp)"
trap 'rm -f "$PLAN_FILE" "$JSON_FILE"' EXIT

# security_analytics (state/dir name, underscore) vs security-analytics
# (the SSO profile name, hyphen). Everything else matches 1:1.
account_to_profile() {
  case "$1" in
    security_analytics) echo "security-analytics" ;;
    *) echo "$1" ;;
  esac
}

ensure_session() {
  local profile="$1"
  if aws sts get-caller-identity --profile "$profile" >/dev/null 2>&1; then
    return 0
  fi
  echo "🔑 No live session for '$profile' — running aws sso login..."
  aws sso login --profile "$profile"
}

FAILED=()

for ACCOUNT in "${ACCOUNTS[@]}"; do
  echo
  echo "════════════════════════════════════════════════════════════"
  echo "=== $ACCOUNT ==="
  echo "════════════════════════════════════════════════════════════"

  ACCOUNT_DIR="${REPO_ROOT}/member-accounts/${ACCOUNT}"
  if [ ! -d "$ACCOUNT_DIR" ]; then
    echo "❌ No such account directory: member-accounts/${ACCOUNT}. Skipping." >&2
    FAILED+=("$ACCOUNT")
    continue
  fi

  PROFILE="$(account_to_profile "$ACCOUNT")"
  if ! aws configure list-profiles 2>/dev/null | grep -qxF "$PROFILE"; then
    echo "❌ No '$PROFILE' profile in ~/.aws/config. Skipping." >&2
    FAILED+=("$ACCOUNT")
    continue
  fi

  ensure_session "$PROFILE"

  # Cross-check: does this profile actually land in the account we think it
  # does? The boundary policy is per-account — applying dev's boundary while
  # accidentally authenticated to prod would be bad.
  WANT_ID="$(aws ssm get-parameter --name "/organizations/accounts/${ACCOUNT}" \
    --profile "$MGMT_PROFILE" --query 'Parameter.Value' --output text 2>/dev/null || true)"
  GOT_ID="$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text 2>/dev/null || true)"
  if [ -z "$WANT_ID" ] || [ "$WANT_ID" = "None" ]; then
    echo "❌ Couldn't resolve ${ACCOUNT}'s account ID from SSM (via '$MGMT_PROFILE'). Skipping." >&2
    FAILED+=("$ACCOUNT")
    continue
  fi
  if [ "$WANT_ID" != "$GOT_ID" ]; then
    echo "❌ Profile '$PROFILE' is in account $GOT_ID, but ${ACCOUNT} is $WANT_ID. Skipping." >&2
    FAILED+=("$ACCOUNT")
    continue
  fi
  echo "✅ '$PROFILE' → account $GOT_ID ($ACCOUNT)"

  pushd "$ACCOUNT_DIR" >/dev/null

  if ! AWS_PROFILE="$PROFILE" terraform init -input=false -lockfile=readonly >/dev/null; then
    echo "❌ terraform init failed for $ACCOUNT. (Try 'terraform init -upgrade' in member-accounts/${ACCOUNT} if the lock file is stale.)" >&2
    FAILED+=("$ACCOUNT")
    popd >/dev/null
    continue
  fi

  if ! AWS_PROFILE="$PROFILE" terraform plan -input=false -lock-timeout=120s \
        -target="$TARGET" -out="$PLAN_FILE" >/dev/null; then
    echo "❌ terraform plan failed for $ACCOUNT." >&2
    FAILED+=("$ACCOUNT")
    popd >/dev/null
    continue
  fi

  if ! AWS_PROFILE="$PROFILE" terraform show -json "$PLAN_FILE" > "$JSON_FILE"; then
    echo "❌ couldn't read the saved plan for $ACCOUNT." >&2
    FAILED+=("$ACCOUNT")
    popd >/dev/null
    continue
  fi

  # Every resource the plan would actually act on (ignoring no-op / read).
  if ! CHANGING="$(jq -r '
    [ .resource_changes[]
      | select(.change.actions != ["no-op"] and .change.actions != ["read"])
      | .address ] | .[]' "$JSON_FILE")"; then
    echo "❌ couldn't parse the plan JSON for $ACCOUNT." >&2
    FAILED+=("$ACCOUNT")
    popd >/dev/null
    continue
  fi

  if [ -z "$CHANGING" ]; then
    echo "ℹ️  No changes — ${ACCOUNT}'s boundary already matches the config. Skipping."
    popd >/dev/null
    continue
  fi

  UNEXPECTED="$(printf '%s\n' "$CHANGING" | grep -v "^${EXPECTED_PREFIX}" || true)"
  if [ -n "$UNEXPECTED" ]; then
    echo "❌ Plan for $ACCOUNT would change resources outside the boundary module:" >&2
    printf '%s\n' "$CHANGING" | sed 's/^/     /' >&2
    echo "   Refusing to apply. Investigate before continuing." >&2
    FAILED+=("$ACCOUNT")
    popd >/dev/null
    continue
  fi

  echo
  AWS_PROFILE="$PROFILE" terraform show -no-color "$PLAN_FILE"
  echo

  if [ "$AUTO_APPROVE" != "1" ]; then
    read -r -p "Apply this boundary change to ${ACCOUNT} (${GOT_ID})? Type 'yes': " REPLY || REPLY=""
    if [ "${REPLY:-}" != "yes" ]; then
      echo "Skipped $ACCOUNT (not confirmed)."
      popd >/dev/null
      continue
    fi
  fi

  if AWS_PROFILE="$PROFILE" terraform apply -input=false -lock-timeout=120s "$PLAN_FILE"; then
    echo "✅ $ACCOUNT boundary applied."
  else
    echo "❌ terraform apply failed for $ACCOUNT." >&2
    FAILED+=("$ACCOUNT")
  fi

  popd >/dev/null
done

echo
echo "════════════════════════════════════════════════════════════"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "✅ Done: ${ACCOUNTS[*]}"
  echo "Next: merge the PR (if not already), then re-run / let CI run the"
  echo "normal Terraform Apply — the boundary is already live, so it won't"
  echo "block the rest of the change."
  exit 0
fi
echo "❌ Failed: ${FAILED[*]}"
echo "   (Other accounts, if any, were applied.)"
exit 1
