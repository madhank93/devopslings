#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two steps, and the order is not negotiable: read the evidence off the live
# process first, because repairing the pipeline is what makes it exit.
set -euo pipefail

install -d /root/answers

# 1. What is it waiting in?
#
#    The export is a shell blocked in open() on a FIFO that no process has
#    opened for reading. wchan is the kernel function the task is sleeping in;
#    for this it is the FIFO's rendezvous wait, not anything to do with the
#    application.
pid=$(systemctl show -p MainPID --value export-orders.service)
if [ -n "$pid" ] && [ "$pid" != "0" ] && [ -r "/proc/$pid/wchan" ]; then
  cat "/proc/$pid/wchan" > /root/answers/wchan
else
  # The process is already gone — fall back to the value recorded when the
  # scenario was built. A student cannot do this, which is exactly why the
  # lesson says to look before you touch anything.
  cp /var/lib/devopslings/blocked-on-a-pipe.wchan /root/answers/wchan
fi

# 2. Why is there no reader?
#
#    orders-shipper.service opens /var/spool/export/order.fifo. The pipe is
#    /var/spool/export/orders.fifo. It failed instantly at 03:00, hours before
#    anyone noticed the export was still running, and nothing correlated the
#    two events.
sed -i 's#/var/spool/export/order\.fifo#/var/spool/export/orders.fifo#' \
  /etc/systemd/system/orders-shipper.service
systemctl daemon-reload

# The check tears both units down and runs the pipeline itself, so there is
# nothing further to start here.
