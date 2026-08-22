# Committed switch for the billable networking layer in this account.
# See the ORDERING rule on variable "networking_enabled" in variables.tf —
# production and development must both be applied with false before this
# file is changed to false here. Flipping this back to true is a normal
# PR that rides the existing plan -> approval -> apply pipeline.
networking_enabled = false
