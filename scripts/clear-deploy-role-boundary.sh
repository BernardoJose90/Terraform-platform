#!/usr/bin/env bash
#
# clear-deploy-role-boundary.sh
#
# Temporarily removes the TerraformDeployPermissionsBoundary from the
# TerraformDeploy role in one or more member accounts, using your SSO
# AdministratorAccess login for each account — NOT TerraformDeploy, and NOT
# BreakGlassAdmin. Same identity model as apply-boundary.sh.
#
# --------------------------------------------------------------------
# WHY THIS EXISTS
# --------------------------------------------------------------------
# AWS refuses to delete an IAM policy while it's still set as a role's
# permissions boundary — DeleteConflict: "Cannot delete a policy attached to
# entities." This is a hard AWS rule, not a permissions gap: it applies no
# matter how privileged the caller is.
#
# That matters here because TerraformDeployPermissionsBoundary's name is
# fixed (no account-specific suffix), so a replacement (forced by a change
# like editing its description, which is ForceNew on aws_iam_policy) creates
# a new policy object with the *same* ARN string as the old one. Terraform
# sees that string as unchanged and doesn't think TerraformDeploy's own
# `permissions_boundary` attribute needs updating — so apply-boundary.sh's
# targeted plan shows "0 to change" for the role, even though the role is
# exactly what's blocking the delete at the AWS API level.
#
# This script does the one manual step that unblocks it: clear the
# boundary from the role first, so the old policy is no longer attached to
# anything and can actually be deleted.
#
# --------------------------------------------------------------------
# WHAT IT DOES, PER ACCOUNT
# --------------------------------------------------------------------
#   1. Makes sure the account's SSO session is live (aws sso login if not).
#   2. Confirms the profile really lands in that account (cross-checks the
#      account ID against SSM /organizations/accounts/<account>), same as
#      apply-boundary.sh.
#   3. Checks whether TerraformDeploy currently has a permissions boundary
#      set at all — if not, there's nothing to do, and the account is
#      skipped.
#   4. Shows exactly what it's about to do and waits for you to type `yes`
#      — always, no auto-approve flag. This removes a security control,
#      even if briefly; it should never run unattended.
#   5. aws iam delete-role-permissions-boundary.
#
# --------------------------------------------------------------------
# WHAT THIS DOES NOT DO
# --------------------------------------------------------------------
# It does not restore the boundary afterward. That happens automatically
# the next time Terraform applies module.github-oidc-roles for that
# account (TerraformDeploy's own resource already sets
# permissions_boundary = var.permissions_boundary_arn) — normally via
# apply-boundary.sh recreating the policy, followed by the account's
# normal CI apply (or another manual apply) picking the role back up.
#
# Do not leave a role with its boundary cleared any longer than it takes
# to get through that sequence for one account before moving to the next.
#
# --------------------------------------------------------------------
# Requires: aws CLI (v2, SSO-configured), jq; one SSO profile per account in
# ~/.aws/config, each with an AdministratorAccess permission set, plus a
# `management` profile for the read-only account-ID cross-check.
#
# Usage:
#   ./scripts/clear-deploy-role-boundary.sh development
#   ./scripts/clear-deploy-role-boundary.sh development infra_shared_services monitoring
#
# No "every account" default on purpose — you must name the accounts you
# mean to touch.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || { echo "❌ Run this from inside the Terraform-platform repo." >&2; exit 1; }

MGMT_PROFILE="${MGMT_PROFILE:-management}"
ROLE_NAME="${ROLE_NAME:-TerraformDeploy}"

ACCOUNTS=("$@")
if [ "${#ACCOUNTS[@]}" -eq 0 ]; then
  echo "❌ Name at least one account, e.g.:" >&2
  echo "     ./scripts/clear-deploy-role-boundary.sh development" >&2
  exit 2
fi

for bin in aws jq; do
  command -v "$bin" >/dev/null 2>&1 || { echo "❌ '$bin' not found on PATH." >&2; exit 1; }
done

# infra_shared_services (state/dir name, underscore) vs infra-shared-services
# (the SSO profile name, hyphen). Everything else matches 1:1. Same mapping
# as apply-boundary.sh — keep these two in sync if the account list changes.
account_to_profile() {
  case "$1" in
    infra_shared_services) echo "infra-shared-services" ;;
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

  # Same cross-check as apply-boundary.sh: don't act on the wrong account
  # because a profile was pointed somewhere unexpected.
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

  ROLE_JSON="$(aws iam get-role --role-name "$ROLE_NAME" --profile "$PROFILE" 2>&1)" || {
    echo "❌ Couldn't read role '$ROLE_NAME' in $ACCOUNT: $ROLE_JSON" >&2
    FAILED+=("$ACCOUNT")
    continue
  }

  CURRENT_BOUNDARY_ARN="$(echo "$ROLE_JSON" | jq -r '.Role.PermissionsBoundary.PermissionsBoundaryArn // empty')"
  if [ -z "$CURRENT_BOUNDARY_ARN" ]; then
    echo "ℹ️  '$ROLE_NAME' in $ACCOUNT has no permissions boundary set — nothing to clear. Skipping."
    continue
  fi

  echo
  echo "⚠️  About to remove this permissions boundary from '$ROLE_NAME' in $ACCOUNT ($GOT_ID):"
  echo "     $CURRENT_BOUNDARY_ARN"
  echo
  echo "⚠️  Until this is restored (normally by the next Terraform apply of"
  echo "    module.github-oidc-roles for this account), '$ROLE_NAME' runs"
  echo "    COMPLETELY UNCONSTRAINED in this account."
  echo

  read -r -p "Type 'yes' to clear it now: " REPLY || REPLY=""
  if [ "${REPLY:-}" != "yes" ]; then
    echo "Skipped $ACCOUNT (not confirmed)."
    continue
  fi

  if aws iam delete-role-permissions-boundary --role-name "$ROLE_NAME" --profile "$PROFILE"; then
    echo "✅ Boundary cleared for '$ROLE_NAME' in $ACCOUNT."
    echo "   Next: re-run apply-boundary.sh for ${ACCOUNT} to delete/recreate the"
    echo "   policy, then apply (CI or manual) module.github-oidc-roles for"
    echo "   ${ACCOUNT} to put the boundary back on the role."
  else
    echo "❌ Failed to clear the boundary for $ACCOUNT." >&2
    FAILED+=("$ACCOUNT")
  fi
done

echo
echo "════════════════════════════════════════════════════════════"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "✅ Done: ${ACCOUNTS[*]}"
  exit 0
fi
echo "❌ Failed/skipped: ${FAILED[*]}"
exit 1
