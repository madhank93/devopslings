#!/bin/bash
set -e

# Behind the load balancer, count the last X-Forwarded-For entry: the one the
# LB appended. Anyone else is counted by the address it connected from.
cat > /etc/fail2ban/filter.d/web-login.conf <<'CFG'
[Definition]
failregex = ^10\.9\.0\.9 \S+ \S+ \[[^]]*\] "[A-Z]+ [^"]*" 401 .*"(?:[^"]*, )?<ADDR>"$
            ^<HOST> \S+ \S+ \[[^]]*\] "[A-Z]+ [^"]*" 401 
ignoreregex =
CFG

cat > /etc/fail2ban/jail.local <<'CFG'
[DEFAULT]
backend = polling

[web-login]
enabled  = true
filter   = web-login
logpath  = /var/log/app/access.log
maxretry = 5
findtime = 600
bantime  = 3600
ignoreip = 127.0.0.1/8 10.9.0.9
CFG

fail2ban-client -t

cat > /root/answers/fail2ban.md <<'ANS'
wrongly_banned_ip: 10.9.0.9
real_client_in: X-Forwarded-For (last entry, only when the peer is the load balancer)
ANS
