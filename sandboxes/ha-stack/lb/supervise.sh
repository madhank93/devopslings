#!/bin/bash
# Keeps this node's HAProxy and keepalived in step with /ha.
#
#   /ha/haproxy.cfg               shared by both load balancers
#   /ha/<node>/keepalived.conf    this node's VRRP config; absent = no keepalived
#   /ha/<node>/log                what happened here, newest last
#
# A config change is validated and then applied. A config that fails
# validation is logged and the running one is kept.
#
# A crashed HAProxy is not restarted. A load balancer whose proxy has died
# while the box stays up is a failure lessons need to stand still long enough
# to be observed; `lbctl start` brings it back.
set -u
node=$(hostname)
dir=/ha/$node
log=$dir/log
mkdir -p "$dir"
say() { echo "$(date +%T) $*" | tee -a "$log"; }

hap=(haproxy -f /etc/haproxy/base.cfg -f /ha/haproxy.cfg)
hap_pid=
ka_pid=
hap_sum=
ka_sum=

start_haproxy() {
  "${hap[@]}" -db >>"$log" 2>&1 &
  hap_pid=$!
  say "haproxy started (pid $hap_pid)"
}

start_keepalived() {
  # keepalived refuses to start beside a pid file left by a killed container.
  rm -f /run/keepalived.pid /run/vrrp.pid /run/checkers.pid
  keepalived -n -l -D -f "$dir/keepalived.conf" >>"$log" 2>&1 &
  ka_pid=$!
  say "keepalived started (pid $ka_pid)"
}

stop_keepalived() {
  [ -n "$ka_pid" ] && kill "$ka_pid" 2>/dev/null && wait "$ka_pid" 2>/dev/null
  ka_pid=
}

trap 'stop_keepalived; [ -n "$hap_pid" ] && kill "$hap_pid" 2>/dev/null; exit 0' TERM INT

while :; do
  if [ -f /ha/haproxy.cfg ]; then
    sum=$(md5sum /ha/haproxy.cfg | cut -d' ' -f1)
    if [ "$sum" != "$hap_sum" ] || [ -f "$dir/start-haproxy" ]; then
      rm -f "$dir/start-haproxy"
      if out=$("${hap[@]}" -c 2>&1); then
        if [ -n "$hap_pid" ] && kill -0 "$hap_pid" 2>/dev/null; then
          kill -USR2 "$hap_pid"
          say "haproxy reloaded /ha/haproxy.cfg"
        else
          start_haproxy
        fi
      else
        say "haproxy REJECTED /ha/haproxy.cfg, keeping the running config:"
        printf '%s\n' "$out" | grep -E 'ALERT|WARNING' | head -5 | tee -a "$log"
      fi
      hap_sum=$sum
    fi
  fi
  if [ -n "$hap_pid" ] && ! kill -0 "$hap_pid" 2>/dev/null; then
    wait "$hap_pid" 2>/dev/null
    say "haproxy exited; not restarting it (lbctl start)"
    hap_pid=
  fi

  if [ -f "$dir/keepalived.conf" ]; then
    sum=$(md5sum "$dir/keepalived.conf" | cut -d' ' -f1)
    if [ "$sum" != "$ka_sum" ]; then
      if out=$(keepalived -t -f "$dir/keepalived.conf" 2>&1); then
        stop_keepalived
        start_keepalived
      else
        say "keepalived REJECTED $dir/keepalived.conf:"
        printf '%s\n' "$out" | head -5 | tee -a "$log"
      fi
      ka_sum=$sum
    fi
  elif [ -n "$ka_pid" ]; then
    stop_keepalived
    ka_sum=
    say "keepalived stopped: $dir/keepalived.conf was removed"
  fi
  sleep 0.5
done
