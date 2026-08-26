#!/usr/bin/env bash
#
# breakglass-bootstrap.sh
#
# Applies one targeted Terraform resource, in one or more accounts, using
# the trust policy's MFA-gated break-glass path (ManagementAccountBreakGlass
# in modules/github-oidc-roles/main.tf) instead of TerraformDeploy's own
# OIDC identity. Exists for exactly one situation: TerraformDeploy needs a
# permission on ITSELF that it doesn't have yet, so its normal CI identity
# is structurally unable to grant it — no amount of retrying or re-running
# the pipeline fixes that, because a role can never grant itself a
# permission it doesn't already hold (see the "Why this exists" section
# below). A different, already-privileged identity has to make that one
# call first.
#
# --------------------------------------------------------------------
# WHY THIS EXISTS (worked example, 2026-08)
# --------------------------------------------------------------------
# member-accounts/*/main.tf started passing permissions_boundary_arn into
# every account's module.github-oidc-roles call, so TerraformDeploy sets
# its OWN permissions boundary for the first time. Doing that requires
# iam:PutRolePermissionsBoundary, on itself — and nothing before that
# change had ever needed TerraformDeploy to touch its own boundary, so the
# permission was never in its policy. Terraform's apply order makes it
# worse: aws_iam_role.terraform_deploy (which sets the boundary) applies
# BEFORE aws_iam_role_policy.terraform_deploy_policy (which would grant the
# missing action), because the policy resource depends on the role. So even
# after the missing action is added to modules/github-oidc-roles/main.tf's
# policy document and merged, CI's own next apply attempt fails the exact
# same way — the grant hasn't reached AWS yet at the moment the boundary
# call is made.
#
# IMPORTANT CORRECTION (2026-08-26, same day): an earlier version of this
# script assumed `-target=...aws_iam_role_policy.terraform_deploy_policy`
# alone would dodge this — it doesn't. `-target` still pulls in and applies
# any PENDING changes on that resource's dependencies, not just confirms
# they exist, and the policy resource depends on the role resource. So
# `-target` on the policy tried to update the role's boundary too, hit the
# exact same 403, on all six accounts, even via break-glass — because
# break-glass only changes how you assume TerraformDeploy, not what
# TerraformDeploy itself is allowed to do once assumed.
#
# The actual fix, and what this script now automates per account: TEMPORARILY
# comment out that account's `permissions_boundary_arn = ...` line before
# planning, so the role resource has nothing pending and `-target` on the
# policy touches only the policy (using iam:PutRolePolicy, which
# TerraformDeploy could always do — that was never the missing permission).
# The plan is checked to confirm the role resource really shows no change
# before anything is applied; the file is restored via `git checkout`
# immediately after, success or failure, via a trap — never left modified.
#
# --------------------------------------------------------------------
# WHY THIS USES A DEDICATED IAM USER, NOT YOUR SSO LOGIN (2026-08-26)
# --------------------------------------------------------------------
# This originally tried to satisfy ManagementAccountBreakGlass using a
# normal `aws sso login` session. That can NEVER work, for any account, no
# matter how the login is done: IAM Identity Center (AWS SSO) does not set
# the aws:MultiFactorAuthPresent context key on the credentials it hands
# out, even when the user genuinely completed an MFA challenge at sign-in.
# Confirmed directly against CloudTrail during a real incident — every SSO
# attempt showed mfaAuthenticated: false, regardless of re-authenticating,
# clearing every local cache, or using a brand-new browser session. This is
# a documented, current AWS limitation, not a config problem:
# https://repost.aws/questions/QURCTAkCd2RiugphKo3S6zIw
#
# The fix: a dedicated native IAM user (BreakGlassAdmin, created in
# Terraform-Org's platform/breakglass-user.tf), with its own registered MFA
# device, authenticating via `sts:GetSessionToken` — which DOES correctly
# set aws:MultiFactorAuthPresent, since it comes from the user's own
# long-term credentials plus a real MFA proof, not federation. This script
# now does exactly that: uses a local `breakglass` CLI profile for
# BreakGlassAdmin's long-term key (set up once, see Requires below), prompts
# only for one fresh MFA code, gets one session token, and reuses that
# single session across every account below — no per-account
# re-authentication needed.
#
# An earlier version of this script prompted for the access key and secret
# with hand-rolled `read -s -p` calls instead of a profile. Dropped after a
# real run showed that path silently failing to capture pasted input on at
# least one terminal setup (zsh + Terminal.app on macOS) — `aws configure`
# uses the same underlying prompt mechanism as every other AWS CLI command
# and doesn't have that problem, so credentials go through it once instead.
#
# --------------------------------------------------------------------
# FUTURE USE CASES — when to reach for this again
# --------------------------------------------------------------------
# - Any future PR that adds a new self-referential IAM action to
#   TerraformDeploy's policy in modules/github-oidc-roles/main.tf — i.e.
#   TerraformDeploy needs to perform some action on its OWN role/policy
#   that it couldn't do before. Same bootstrap gap, same fix: target the
#   resource that grants the new permission, apply it once via break-glass,
#   then let CI proceed normally.
# - Recovering from a PR that accidentally narrowed TerraformDeploy's own
#   policy in a way that removed something it needs to manage itself (e.g.
#   its own state-file access, or a self-tagging permission) — CI can't fix
#   its own policy if the fix itself needs a permission that same PR just
#   removed. Point TARGET_RESOURCE at the policy resource and apply the
#   corrected code via break-glass to recover.
# - General-purpose "CI is locked out of one specific resource and needs a
#   privileged nudge" utility: change TARGET_RESOURCE below (or pass a
#   different -target inline) to bootstrap any other single resource this
#   same way, not only the inline policy this script defaults to.
#
# --------------------------------------------------------------------
# WHAT THIS DOES NOT COVER
# --------------------------------------------------------------------
# - An overly-restrictive PERMISSIONS BOUNDARY (module.terraform_deploy_
#   boundary), as opposed to the identity policy. Assuming TerraformDeploy
#   via break-glass still assumes TerraformDeploy — the boundary applies to
#   that role no matter how it's assumed, so a boundary that's the actual
#   blocker needs genuinely separate admin credentials operating on
#   TerraformDeploy from outside, not this script.
# - Bootstrapping a brand-new AWS account's very first apply. There's no
#   TerraformDeploy role to assume yet in an account that doesn't have one,
#   so "assume TerraformDeploy via break-glass" doesn't apply — that's a
#   different, more fundamental bootstrap problem, solved elsewhere (see
#   Terraform-Org's account-creation process).
#
# --------------------------------------------------------------------
# Requires: aws CLI, jq, terraform; a working `management` SSO profile
# (used only for the read-only account-ID lookups below — that part never
# needed MFA and was never broken); and a ONE-TIME setup of BreakGlassAdmin's
# long-term key in its own local CLI profile:
#
#   aws configure --profile breakglass
#     AWS Access Key ID:     <BreakGlassAdmin's access key>
#     AWS Secret Access Key: <BreakGlassAdmin's secret key>
#     Default region:        eu-west-2
#     Default output format: <blank>
#
# After that, this script only ever prompts you for a fresh MFA code — the
# long-term key is never typed again, and (unlike the access key/secret)
# never appears in this script's own prompts at all.
#
# Usage:
#   ./breakglass-bootstrap.sh                      # all six accounts
#   ./breakglass-bootstrap.sh network production    # just these two
#   TARGET_RESOURCE='module.some_other_module.some_resource.x' \
#     ./breakglass-bootstrap.sh network             # a different resource
#   MFA_SERIAL='arn:aws:iam::145678291484:mfa/some-other-device' \
#     ./breakglass-bootstrap.sh                     # different MFA device
#   BREAKGLASS_PROFILE='some-other-profile' \
#     ./breakglass-bootstrap.sh                     # different CLI profile

set -euo pipefail

ACCOUNTS=(network development monitoring production security security_analytics)
if [ "$#" -gt 0 ]; then
  ACCOUNTS=("$@")
fi

MGMT_PROFILE="management"
BREAKGLASS_PROFILE="${BREAKGLASS_PROFILE:-breakglass}"
TARGET_RESOURCE="${TARGET_RESOURCE:-module.github-oidc-roles.aws_iam_role_policy.terraform_deploy_policy}"
MFA_SERIAL="${MFA_SERIAL:-arn:aws:iam::145678291484:mfa/iphone}"

# The neutralize/verify/restore dance below only applies to the DEFAULT
# target (the known role-vs-policy ordering problem this script exists
# for). A custom TARGET_RESOURCE is a different, unknown resource — this
# script has no way to know what (if anything) needs neutralizing for it,
# so it falls back to a plain targeted apply for that case, same as before.
DEFAULT_TARGET="module.github-oidc-roles.aws_iam_role_policy.terraform_deploy_policy"
BOUNDARY_LINE="permissions_boundary_arn = module.terraform_deploy_boundary.arn"
ROLE_RESOURCE_ADDR="module.github-oidc-roles.aws_iam_role.terraform_deploy"

# Tracks the one account main.tf currently neutralized, if any, so the
# EXIT trap can always restore it — even on Ctrl-C or an unexpected error
# partway through an account, this never leaves a repo file modified.
NEUTRALIZED_FILE=""

# Resolve the repo root regardless of where this script is run from, so
# `cd member-accounts/<account>` below always lands in the right place.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "❌ Not inside the Terraform-platform git repo (or git isn't available). Run this from within the repo." >&2
  exit 1
fi

for bin in aws jq terraform; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "❌ '$bin' not found on PATH." >&2
    exit 1
  fi
done

if ! aws configure list --profile "$BREAKGLASS_PROFILE" >/dev/null 2>&1; then
  echo "❌ No '$BREAKGLASS_PROFILE' CLI profile found." >&2
  echo "   One-time setup: aws configure --profile $BREAKGLASS_PROFILE" >&2
  echo "   (BreakGlassAdmin's access key + secret — see this script's header comment.)" >&2
  exit 1
fi

CRED_FILE="$(mktemp)"
ASSUME_ERR_FILE="$(mktemp)"
PLAN_FILE="$(mktemp)"
# Always clear exported credentials, delete temp files, AND restore any
# still-neutralized account file on exit — whether the script finishes
# normally, fails partway, or is interrupted. Session credentials are
# never echoed to the screen anywhere in this script — only ever written
# to CRED_FILE (0600 via mktemp) and read back with jq.
cleanup() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN || true
  rm -f "$CRED_FILE" "$ASSUME_ERR_FILE" "$PLAN_FILE"
  if [ -n "$NEUTRALIZED_FILE" ]; then
    echo "Restoring $NEUTRALIZED_FILE on exit..." >&2
    git -C "$REPO_ROOT" checkout -- "$NEUTRALIZED_FILE" || true
    NEUTRALIZED_FILE=""
  fi
}
trap cleanup EXIT

# Comments out this account's permissions_boundary_arn line so the role
# resource has nothing pending, and records the file so the EXIT trap
# above can always restore it. Refuses to touch a file that already has
# uncommitted changes, or one where the expected line isn't found exactly
# once - no guessing.
neutralize_boundary_line() {
  local file="$1"
  if ! git -C "$REPO_ROOT" diff --quiet -- "$file"; then
    echo "$file already has uncommitted local changes - refusing to touch it." >&2
    return 1
  fi
  local matches
  matches=$(grep -cF "$BOUNDARY_LINE" "$file")
  if [ "$matches" -ne 1 ]; then
    echo "Expected exactly one boundary line in $file, found $matches - refusing to guess." >&2
    return 1
  fi
  # [[:space:]] (POSIX class), not \s — macOS ships BSD sed by default,
  # which does not understand \s at all. Confirmed directly: with \s this
  # silently matched nothing and left the file completely unchanged, sed
  # still exited 0, and every downstream check that trusted "sed didn't
  # error" was fooled into applying against the unmodified role resource.
  sed -i.bak "s|^\([[:space:]]*\)${BOUNDARY_LINE}\$|\1# ${BOUNDARY_LINE}  # TEMP: neutralized by breakglass-bootstrap.sh, auto-restored|" "$file"
  rm -f "${file}.bak"

  # Don't just trust sed's exit code — it exits 0 whether or not it
  # actually substituted anything. Confirm the marker text is really
  # there. (Checking that BOUNDARY_LINE is "gone" would be wrong: after a
  # correct comment-out the line still CONTAINS that text, just prefixed
  # with '#' — that substring never disappears, so that isn't a valid
  # signal either way. The marker text can only exist after a real edit.)
  if ! grep -qF "TEMP: neutralized by breakglass-bootstrap.sh" "$file"; then
    echo "sed ran but $file was not actually modified - not proceeding." >&2
    return 1
  fi

  NEUTRALIZED_FILE="$file"
}

restore_boundary_line() {
  local file="$1"
  git -C "$REPO_ROOT" checkout -- "$file"
  NEUTRALIZED_FILE=""
}

# ──────────────────────────────────────────────────────────────────────────
# Get ONE MFA-backed session token from BreakGlassAdmin, once, up front.
# Every account below reuses this same session — no per-account
# re-authentication. The only thing this ever prompts for is the MFA code
# itself (can't be stored ahead of time — it's single-use and expires in
# ~30s) — the long-term key comes from the 'breakglass' CLI profile set up
# once via `aws configure`, not typed here.
# ──────────────────────────────────────────────────────────────────────────
read -r -p "🔐 MFA code for BreakGlassAdmin (fresh, from the authenticator app): " MFA_CODE

echo "🔑 Requesting an MFA-backed session token (serial: $MFA_SERIAL)..."
if ! aws sts get-session-token \
      --serial-number "$MFA_SERIAL" \
      --token-code "$MFA_CODE" \
      --profile "$BREAKGLASS_PROFILE" \
      --output json > "$CRED_FILE" 2>"$ASSUME_ERR_FILE"; then
  echo "❌ get-session-token failed:" >&2
  cat "$ASSUME_ERR_FILE" >&2
  echo "   (Check the '$BREAKGLASS_PROFILE' profile's key is current, the MFA code is fresh — codes expire in ~30s — and MFA_SERIAL matches the device actually registered on BreakGlassAdmin.)" >&2
  exit 1
fi

SESSION_ACCESS_KEY_ID=$(jq -r .Credentials.AccessKeyId "$CRED_FILE")
SESSION_SECRET_ACCESS_KEY=$(jq -r .Credentials.SecretAccessKey "$CRED_FILE")
SESSION_TOKEN=$(jq -r .Credentials.SessionToken "$CRED_FILE")
echo "✅ Session token acquired (valid until $(jq -r .Credentials.Expiration "$CRED_FILE"))."

echo "🎯 Target resource: $TARGET_RESOURCE"

FAILED=()

for ACCOUNT in "${ACCOUNTS[@]}"; do
  echo
  echo "════════════════════════════════════════════════════════════"
  echo "=== $ACCOUNT ==="
  echo "════════════════════════════════════════════════════════════"

  # Plain read-only lookup — never needed MFA, never was the broken part.
  # Still goes through the normal SSO 'management' profile.
  ACCOUNT_ID=$(aws ssm get-parameter \
    --name "/organizations/accounts/${ACCOUNT}" \
    --profile "$MGMT_PROFILE" --query 'Parameter.Value' --output text)

  if [ -z "$ACCOUNT_ID" ] || [ "$ACCOUNT_ID" = "None" ]; then
    echo "❌ Could not resolve account ID for '$ACCOUNT' from SSM. Skipping." >&2
    FAILED+=("$ACCOUNT")
    continue
  fi
  echo "Account ID: $ACCOUNT_ID"

  if ! AWS_ACCESS_KEY_ID="$SESSION_ACCESS_KEY_ID" \
      AWS_SECRET_ACCESS_KEY="$SESSION_SECRET_ACCESS_KEY" \
      AWS_SESSION_TOKEN="$SESSION_TOKEN" \
      aws sts assume-role \
      --role-arn "arn:aws:iam::${ACCOUNT_ID}:role/TerraformDeploy" \
      --role-session-name "breakglass-bootstrap" \
      --output json > "$CRED_FILE" 2>"$ASSUME_ERR_FILE"; then
    echo "❌ sts assume-role failed for $ACCOUNT:" >&2
    cat "$ASSUME_ERR_FILE" >&2
    FAILED+=("$ACCOUNT")
    continue
  fi

  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID=$(jq -r .Credentials.AccessKeyId "$CRED_FILE")
  AWS_SECRET_ACCESS_KEY=$(jq -r .Credentials.SecretAccessKey "$CRED_FILE")
  AWS_SESSION_TOKEN=$(jq -r .Credentials.SessionToken "$CRED_FILE")
  unset AWS_PROFILE

  pushd "${REPO_ROOT}/member-accounts/${ACCOUNT}" > /dev/null

  if ! terraform init -input=false; then
    echo "❌ terraform init failed for $ACCOUNT." >&2
    FAILED+=("$ACCOUNT")
    popd > /dev/null
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    continue
  fi

  ACCOUNT_MAIN_TF="${REPO_ROOT}/member-accounts/${ACCOUNT}/main.tf"

  if [ "$TARGET_RESOURCE" = "$DEFAULT_TARGET" ]; then
    # The known case: neutralize the boundary line first, so -target's
    # dependency pull-in of the role resource has nothing pending to
    # apply. Verify via plan before touching anything.
    if ! neutralize_boundary_line "$ACCOUNT_MAIN_TF"; then
      FAILED+=("$ACCOUNT")
      popd > /dev/null
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      continue
    fi

    terraform plan -target="$TARGET_RESOURCE" -out="$PLAN_FILE" > /dev/null

    # Fail CLOSED, not open: capture terraform show's own exit code
    # explicitly rather than checking it inside a piped `if`, where a
    # failure of terraform show itself (not just "no match") could
    # silently be treated the same as "role resource is clean" and let an
    # unsafe apply through — exactly the gap that let the earlier sed bug
    # slip past this check undetected.
    PLAN_TEXT="$(terraform show -no-color "$PLAN_FILE")"
    if [ -z "$PLAN_TEXT" ]; then
      echo "❌ terraform show produced no output for $ACCOUNT's plan - can't verify it's safe. Not applying." >&2
      restore_boundary_line "$ACCOUNT_MAIN_TF"
      FAILED+=("$ACCOUNT")
      popd > /dev/null
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      continue
    fi
    if printf '%s' "$PLAN_TEXT" | grep -qF "# ${ROLE_RESOURCE_ADDR} will be"; then
      echo "❌ Neutralizing didn't work as expected - the role resource still shows a pending change for $ACCOUNT. Not applying." >&2
      restore_boundary_line "$ACCOUNT_MAIN_TF"
      FAILED+=("$ACCOUNT")
      popd > /dev/null
      unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
      continue
    fi

    # No -auto-approve on purpose: review the plan before typing yes. This
    # should only ever show ONE resource changing (the inline policy) — if
    # it shows anything else, the grep above should already have caught
    # it, but look again anyway before confirming.
    if ! terraform apply "$PLAN_FILE"; then
      echo "❌ terraform apply failed for $ACCOUNT." >&2
      FAILED+=("$ACCOUNT")
    else
      echo "✅ $ACCOUNT bootstrapped (permission now live)."
    fi

    restore_boundary_line "$ACCOUNT_MAIN_TF"
  else
    # A custom TARGET_RESOURCE — no known neutralization to apply, plain
    # targeted apply same as before.
    if ! terraform apply -target="$TARGET_RESOURCE"; then
      echo "❌ terraform apply failed for $ACCOUNT." >&2
      FAILED+=("$ACCOUNT")
    else
      echo "✅ $ACCOUNT bootstrapped."
    fi
  fi

  popd > /dev/null
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
done

echo
echo "════════════════════════════════════════════════════════════"
if [ "${#FAILED[@]}" -eq 0 ]; then
  echo "✅ All accounts bootstrapped: ${ACCOUNTS[*]}"
  echo "Next: re-run the failed Terraform Apply job(s) in GitHub Actions — no new push needed."
else
  echo "⚠️  Bootstrapped: $(comm -23 <(printf '%s\n' "${ACCOUNTS[@]}" | sort) <(printf '%s\n' "${FAILED[@]}" | sort) | tr '\n' ' ')"
  echo "❌ Failed: ${FAILED[*]}"
  echo "Re-run this script with just the failed accounts once fixed, e.g.:"
  echo "  ./breakglass-bootstrap.sh ${FAILED[*]}"
fi
echo "════════════════════════════════════════════════════════════"
