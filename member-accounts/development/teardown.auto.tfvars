# Committed switch for the billable networking layer in this account.
# See the ORDERING rule on variable "networking_enabled" in variables.tf —
# this account (and production) must both be applied with false BEFORE
# the network account's own teardown.auto.tfvars is changed to false.
# Flipping this is a normal PR that rides the existing
# plan -> approval -> apply pipeline.
networking_enabled = false
