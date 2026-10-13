#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The 2019 script still loads its rules through iptables-legacy, into x_tables,
# beside the managed nftables ruleset. A packet must pass both, and
# `iptables` (nft) only shows one. Stop the old script from running at boot,
# then empty the legacy table it filled.

systemctl disable --now api1-legacy-fw.service
ip netns exec api1 iptables-legacy -F INPUT
