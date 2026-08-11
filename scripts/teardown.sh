#!/usr/bin/env bash
#
# teardown.sh
#
# Fully removes all resources and workload across the whole AWS environment, in dependency
# order, while keeping the AWS accounts themselves, GitHub OIDC roles, the
# S3 state bucket, and the SSM account manifest intact.
#
# This is a different, more final tool than the networking_enabled feature
# flag (see variable "networking_enabled" in production/development/network's
# variables.tf, and docs/teardown.md). That flag pauses billable resources
# cheaply and reversibly via a normal PR (count = 0), while leaving them
# fully declared in state and config. THIS script runs a real
# `terraform destroy` and removes the targeted resources from state
# entirely — the right tool for "the project is finished," not for
# "pause it over the weekend." Use the flag for the latter.
#
# --------------------------------------------------------------------
# ORDERING (strict, sequential within each tier — never parallel, even
# within a tier, for a destructive operation like this)
# --------------------------------------------------------------------
#   Tier 1: production, development
#   Tier 2: network
#   Tier 3: monitoring, security, security_analytics
#
# WHY THIS ORDER: production and development each hold a TGW VPC
# attachment into the network account's Transit Gateway. If network is
# destroyed first, deleting the TGW fails with DependencyViolation while
# those attachments still exist — AWS won't delete a TGW that still has
# attachments. Separately, and worse: both spokes read /transit-gateway/id
# from network via a data source (data "aws_ssm_parameter" "tgw_id",
# through the aws.network provider), and data sources are evaluated at
# DESTROY time too, not just apply time. Once network is gone, that data
# source has nothing to read and the spokes can't even compute a PLAN,
# let alone a destroy — they'd be stuck, unable to tear themselves down
# via Terraform at all. Spokes must go first, always.
#
# Tier 3's three accounts have no dependency relationship to network or
# to each other — their internal order doesn't matter — but they run
# after network regardless, to keep the script's overall direction
# "leaves before roots" throughout.
#
# --------------------------------------------------------------------
# HARD EXCLUSION
# --------------------------------------------------------------------
# This script will never operate on a directory named "AWS Organizations"
# (or any path containing that segment) — checked explicitly, for every
# directory, before anything runs. That directory doesn't exist in this
# repo today; the guard exists so it's still true the day one is added
# and nobody remembers to update this file.
#
# --------------------------------------------------------------------
# -exclude DOESN'T EXIST IN THIS TERRAFORM VERSION
# --------------------------------------------------------------------
# The original brief for this script called for
# `terraform plan -destroy -exclude=module.github-oidc-roles`. That flag
# does not exist in this repo's pinned Terraform version (required_version
# ~> 1.11.0 / installed v1.11.4 — confirmed directly: neither
# `terraform plan -help` nor `terraform destroy -help` lists it).
# -target is the only selection mechanism this Terraform version actually
# has, and it SELECTS rather than excludes — so this script discovers
# "everything currently in state except the excluded set" via
# `terraform state list`, filtered, and passes the result as repeated
# -target= arguments. Functionally the inverse of what -exclude would
# have done, same result.
#
# --------------------------------------------------------------------
# WHAT'S EXCLUDED FROM DESTRUCTION, AND WHY
# --------------------------------------------------------------------
# module.github-oidc-roles, in every account — the one exclusion asked
# for. GitHub Actions' OIDC trust roles; losing them locks CI out of the
# account until manually restored.
#
# ALSO excluded, beyond what was asked for, because targeting them would
# not destroy anything anyway — these carry lifecycle.prevent_destroy,
# added earlier in this project's life after an incident where a
# less-careful teardown script deleted resources it didn't know existed:
#
#   - network: module.tgw_spoke_wiring_production,
#     module.tgw_spoke_wiring_development — their aws_iam_role.this is
#     prevent_destroy-protected. Targeting it makes `plan -destroy`
#     hard-error before it can even produce a plan. Excluding it here
#     doesn't change the outcome (prevent_destroy refuses either way,
#     loudly) — it just avoids a guaranteed failure on every tier 2 run.
#
#   - security: every IAM Identity Center resource this repo manages —
#     the admin user, all 3 groups, all 3 permission sets, all 3 managed
#     policy attachments, and TerraformDeploy's own SSO-management
#     policy (member-accounts/security/sso.tf and iam-supplemental.tf).
#     All prevent_destroy-protected, same reasoning.
#
# NOT prevent_destroy-protected, excluded anyway as a judgment call:
# security's SSO account ASSIGNMENTS (aws_ssoadmin_account_assignment.*
# — who has admin/readonly access to which account). Nothing stops
# Terraform from destroying these; they're deliberately left mutable
# because revoking access is sometimes a legitimate, intentional action.
# But they are not "the workload layer" either — they're access control,
# same category as the OIDC roles this script is explicitly told to
# keep. Excluded by default. If you actually want a run that revokes
# everyone's assignments too, that's a deliberate edit to
# EXCLUDE_PATTERN_security below, not this script's default behavior.
#
# monitoring and security_analytics currently contain nothing but
# module.github-oidc-roles (each account's main.tf is ~60 lines, pure CI
# bootstrap, nothing else has been added). After exclusions, tier 3
# destroys nothing at all today, in either account — not a bug, just
# what's actually there.
#
# --------------------------------------------------------------------
# Usage:
#   ./scripts/teardown.sh --confirm
# Then type the literal string  destroy-workloads  when prompted.
#
# Requires AWS SSO profiles matching each account name (see profile_for
# below for the one naming exception) with an active session
# (`aws sso login --profile X`) before running — this script switches
# AWS_PROFILE per account as it goes. This is a local, human-run,
# interactively-confirmed tool. The CI counterpart,
# .github/workflows/terraform-teardown.yaml, is a deliberately separate
# implementation — see that file for why it isn't just this script
# invoked non-interactively.
# --------------------------------------------------------------------

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

TIER1_ACCOUNTS=(production development)
TIER2_ACCOUNTS=(network)
TIER3_ACCOUNTS=(monitoring security security_analytics)

# member-accounts/<dir> -> AWS SSO profile name. Only differs for
# security_analytics (directory uses an underscore, the profile in
# ~/.aws/config uses a hyphen) — everything else matches its directory.
profile_for() {
  case "$1" in
    security_analytics) echo "security-analytics" ;;
    *) echo "$1" ;;
  esac
}

# Per-account regex of state addresses to KEEP (never target for
# destroy). Matched with `grep -v -E` against `terraform state list`, so
# what's left is exactly what gets -target='d.
exclude_pattern_for() {
  case "$1" in
    network)
      echo '^module\.github-oidc-roles(\.|$)|^module\.tgw_spoke_wiring_(production|development)(\.|$)'
      ;;
    security)
      echo '^module\.github-oidc-roles(\.|$)|^aws_identitystore_(user|group|group_membership)\.|^aws_ssoadmin_(permission_set|managed_policy_attachment)\.|^aws_ssoadmin_account_assignment\.|^aws_iam_role_policy\.terraform_deploy_sso_identity_center_access$'
      ;;
    *)
      echo '^module\.github-oidc-roles(\.|$)'
      ;;
  esac
}

# --------------------------------------------------------------------
# HARD EXCLUSION guard — evaluated for every directory this script is
# about to touch, not assumed once at the top.
# --------------------------------------------------------------------
assert_not_organizations_dir() {
  local dir="$1"
  if [[ "$dir" == *"AWS Organizations"* ]]; then
    echo "REFUSING: '$dir' contains the hard-excluded 'AWS Organizations' path segment. This script must never operate there." >&2
    exit 1
  fi
}

# --------------------------------------------------------------------
# Confirmation gate
# --------------------------------------------------------------------
confirm_flag=false
for arg in "$@"; do
  [[ "$arg" == "--confirm" ]] && confirm_flag=true
done

if ! $confirm_flag; then
  echo "Refusing to run without --confirm. This script runs real 'terraform destroy' against real infrastructure." >&2
  echo "Usage: $0 --confirm" >&2
  exit 1
fi

if [[ ! -t 0 ]]; then
  echo "Refusing to run without an interactive terminal — the typed confirmation phrase can't be read from a non-interactive shell." >&2
  echo "(This is also why the CI workflow does not simply invoke this script — see terraform-teardown.yaml.)" >&2
  exit 1
fi

echo "This will run 'terraform destroy' (targeted, see this script's header for exclusions) against:"
echo "  Tier 1: ${TIER1_ACCOUNTS[*]}"
echo "  Tier 2: ${TIER2_ACCOUNTS[*]}"
echo "  Tier 3: ${TIER3_ACCOUNTS[*]}"
echo ""
read -r -p "Type 'destroy-workloads' to proceed: " typed_confirmation
if [[ "$typed_confirmation" != "destroy-workloads" ]]; then
  echo "Confirmation phrase did not match. Aborting, nothing was touched." >&2
  exit 1
fi

# --------------------------------------------------------------------
# Per-account teardown
# --------------------------------------------------------------------
teardown_account() {
  local account="$1"
  local dir="$ROOT/member-accounts/$account"
  local profile
  profile="$(profile_for "$account")"

  assert_not_organizations_dir "$dir"

  echo ""
  echo "=================================================================="
  echo "== $account (profile: $profile)"
  echo "=================================================================="

  if [[ ! -d "$dir" ]]; then
    echo "  $dir does not exist — skipping."
    return
  fi

  echo "-- init --"
  AWS_PROFILE="$profile" terraform -chdir="$dir" init -input=false -reconfigure

  echo "-- discovering destroy targets (excluding: $(exclude_pattern_for "$account")) --"
  local exclude_re targets
  exclude_re="$(exclude_pattern_for "$account")"
  targets=$(AWS_PROFILE="$profile" terraform -chdir="$dir" state list 2>/dev/null \
    | grep -v '^data\.' \
    | grep -v -E "$exclude_re" || true)

  if [[ -z "$targets" ]]; then
    echo "  nothing to destroy in $account after exclusions."
    return
  fi

  echo "  will target for destroy:"
  echo "$targets" | sed 's/^/    /'

  local target_args=()
  while IFS= read -r addr; do
    target_args+=(-target="$addr")
  done <<< "$targets"

  echo "-- plan -destroy --"
  # Fail loudly, and STOP THE WHOLE SCRIPT, if the plan itself can't be
  # computed — a broken data source here means an upstream account is
  # already gone (ordering was violated, or a prior run partially
  # failed) and continuing would orphan resources rather than cleanly
  # tear them down.
  if ! AWS_PROFILE="$profile" terraform -chdir="$dir" plan -destroy -input=false -lock-timeout=120s \
      "${target_args[@]}" -out=destroy.tfplan; then
    echo "" >&2
    echo "!! STOPPING: plan -destroy failed for $account. !!" >&2
    echo "!! This most likely means an upstream account this one depends on (via a data source) is already gone, or state here is otherwise broken. Fix that before re-running — do NOT re-run blindly, it will not get further. !!" >&2
    exit 1
  fi

  echo "-- apply destroy.tfplan --"
  AWS_PROFILE="$profile" terraform -chdir="$dir" apply -input=false -lock-timeout=120s "$dir/destroy.tfplan"
  rm -f "$dir/destroy.tfplan"

  echo "-- post-apply verification plan (expect this to NOT be empty — see this script's header re: -target's state-consistency caveat) --"
  set +e
  local post_plan_output
  post_plan_output=$(AWS_PROFILE="$profile" terraform -chdir="$dir" plan -input=false -lock-timeout=120s -detailed-exitcode -no-color 2>&1)
  local post_plan_exit=$?
  set -e

  case $post_plan_exit in
    0)
      echo "  post-apply plan: clean, no residual diff."
      ;;
    2)
      echo "  ⚠ WARNING: post-apply plan is NOT empty. This is EXPECTED after a" >&2
      echo "  targeted destroy — -target updates state but not the .tf config," >&2
      echo "  so a plain plan will want to recreate everything just destroyed." >&2
      echo "  This is the state-consistency caveat -target carries. Full diff:" >&2
      echo "$post_plan_output" | sed 's/^/    /' >&2
      ;;
    *)
      echo "  ⚠ WARNING: the post-apply verification plan itself failed (exit $post_plan_exit)." >&2
      echo "  Inspect $account manually — do not assume the destroy above was clean." >&2
      echo "$post_plan_output" | sed 's/^/    /' >&2
      ;;
  esac
}

echo ""
echo "########## TIER 1: spokes ##########"
for account in "${TIER1_ACCOUNTS[@]}"; do
  teardown_account "$account"
done

echo ""
echo "########## TIER 2: network ##########"
for account in "${TIER2_ACCOUNTS[@]}"; do
  teardown_account "$account"
done

echo ""
echo "########## TIER 3: monitoring / security / security_analytics ##########"
for account in "${TIER3_ACCOUNTS[@]}"; do
  teardown_account "$account"
done

echo ""
echo "Teardown run complete. Review any ⚠ WARNING lines above."
