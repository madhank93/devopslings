#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# catalog reads the higher %util and is not the problem. It takes index lookups
# and answers them in a small fraction of a millisecond, so it nearly always has
# a request in flight and nearly never has one waiting. audit reads roughly half
# the utilisation and takes well over a millisecond per write — tens of times
# longer for each one — because those writes are O_DIRECT|O_SYNC and have to
# reach the device before they are acknowledged. Half the utilisation, and the
# same queue depth, at many times the cost per request.
echo audit > /root/answers/saturated

# await is the only column here that answers the question. util is higher on the
# healthy volume, iops is far higher on the healthy volume, and the queue depths
# are within a request of each other. Service time per request is what separates
# a device keeping up from a device that cannot.
echo await > /root/answers/metric

# %util is the fraction of the sample interval during which at least one request
# was in flight. That is a statement about time, not about capacity: a device
# given one slow request at a time can read 100% while moving nothing, and a
# device given a constant stream of instant requests reads the same. It was a
# reasonable proxy on a single mechanical spindle that could serve exactly one
# request at a time, and it stopped being one the moment devices could serve
# many at once.
echo residency > /root/answers/util-means
