#!/usr/bin/env python3
"""Checks the Transit Gateway (TGW) teardown/rebuild ORDERING rule across accounts.

The network account owns the TGW; production and development attach to it.
Each account has its own on/off flags in its own tfvars files, and nothing in
Terraform ties them together — a spoke left "wired" while the network account
is torn down plans against a TGW ID that no longer exists. This script reads
the committed flags (no AWS access needed) and fails the PR when:

  1. The network account's networking_enabled is false while a spoke is still
     wired into the TGW.
  2. The network account is switched back on in the same PR as a spoke is
     rewired. A spoke's plan is computed on the PR, before the network
     account has applied, so it would plan against a TGW that doesn't exist
     yet. Rebuild the network account in its own PR first.

A teardown (network and spokes switched off together) IS allowed in one PR:
deploy-apply.yaml applies the spokes first and the network account last
whenever this script reports the network account is being switched off.

Usage:
  check-tgw-ordering.py [--base <git-ref>]
  check-tgw-ordering.py --base <git-ref> --network-direction
      Prints only "teardown" (network switched off by this change), "rebuild"
      (switched on) or "none", for deploy-apply.yaml to order its jobs by.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

ACCOUNTS_DIR = "member-accounts"


def read(path, ref):
    """Returns a file's contents from the working tree, or from a git ref."""
    if ref is None:
        p = Path(path)
        return p.read_text() if p.exists() else None
    result = subprocess.run(
        ["git", "show", f"{ref}:{path}"], capture_output=True, text=True
    )
    return result.stdout if result.returncode == 0 else None


def list_tfvars(account, ref):
    """Lists an account's tfvars files in the order Terraform loads them."""
    if ref is None:
        names = [p.name for p in Path(ACCOUNTS_DIR, account).glob("*.tfvars")]
    else:
        out = subprocess.run(
            ["git", "ls-tree", "--name-only", ref, f"{ACCOUNTS_DIR}/{account}/"],
            capture_output=True, text=True,
        ).stdout
        names = [Path(n).name for n in out.split()]
    auto = sorted(n for n in names if n.endswith(".auto.tfvars"))
    return (["terraform.tfvars"] if "terraform.tfvars" in names else []) + auto


def bool_var(account, name, ref):
    """Resolves a bool variable the way Terraform would: default, then tfvars."""
    value = None

    variables = read(f"{ACCOUNTS_DIR}/{account}/variables.tf", ref) or ""
    block = re.search(
        rf'^variable\s+"{name}"\s*{{(.*?)^}}', variables, re.MULTILINE | re.DOTALL
    )
    if block:
        default = re.search(r"^\s*default\s*=\s*(true|false)\b", block.group(1), re.MULTILINE)
        if default:
            value = default.group(1) == "true"

    for tfvars in list_tfvars(account, ref):
        text = read(f"{ACCOUNTS_DIR}/{account}/{tfvars}", ref) or ""
        for match in re.finditer(rf"^{name}\s*=\s*(true|false)\b", text, re.MULTILINE):
            value = match.group(1) == "true"

    if value is None:
        sys.exit(f"::error::Could not resolve {account}.{name} (ref: {ref or 'working tree'})")
    return value


def topology(ref):
    """Returns the network flag and each spoke's effective TGW wiring."""
    return {
        "network": bool_var("network", "networking_enabled", ref),
        # Mirrors local.tgw_wiring in each spoke's main.tf.
        "production": bool_var("production", "networking_enabled", ref),
        "development": bool_var("development", "networking_enabled", ref)
        and bool_var("development", "tgw_attachment_enabled", ref),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--base", help="git ref to compare against (the PR's base)")
    parser.add_argument(
        "--network-direction", action="store_true",
        help="print teardown / rebuild / none and exit (requires --base)",
    )
    args = parser.parse_args()

    if args.network_direction:
        if not args.base:
            parser.error("--network-direction requires --base")
        before = bool_var("network", "networking_enabled", args.base)
        after = bool_var("network", "networking_enabled", None)
        print("teardown" if before and not after else "rebuild" if after and not before else "none")
        return 0

    head = topology(None)
    print(f"{'network.networking_enabled':26} = {head['network']}")
    for spoke in ("production", "development"):
        print(f"{spoke + ' wired into TGW':26} = {head[spoke]}")

    errors = []

    if not head["network"]:
        for spoke in ("production", "development"):
            if head[spoke]:
                errors.append(
                    f"{spoke} is still wired into the Transit Gateway, but the network "
                    "account has networking_enabled = false, so that TGW doesn't exist. "
                    f"Detach {spoke} (see member-accounts/{spoke}/teardown.auto.tfvars"
                    + (" and terraform.tfvars" if spoke == "development" else "")
                    + "), or turn the network account back on first."
                )

    if args.base:
        base = topology(args.base)
        # Only the rebuild direction is blocked. A combined teardown is safe
        # because deploy-apply.yaml applies the spokes before the network
        # account when it's being switched off.
        if head["network"] and not base["network"]:
            for spoke in ("production", "development"):
                if head[spoke] and not base[spoke]:
                    errors.append(
                        f"This PR switches the network account back on AND rewires {spoke} "
                        f"into the TGW. {spoke}'s plan is computed now, before the network "
                        "account has applied, so it would plan against a TGW that doesn't "
                        "exist yet. Merge the network account's change on its own first, "
                        f"then rewire {spoke} in a follow-up PR."
                    )

    for error in errors:
        print(f"::error::{error}")
    if errors:
        return 1
    print("TGW ordering rule OK.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
