#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# The box sends the VIP's frames to app-a's MAC because a permanent neighbour
# entry says to, and ARP never revises a permanent entry. Remove the pin from
# the file that reapplies it at boot, then from the live table; the next packet
# to the VIP triggers an ARP request that app-b answers.

sed -i '/^[[:space:]]*10\.70\.0\.100[[:space:]]/d' /etc/neighbours.conf
ip neigh del 10.70.0.100 dev lan1
