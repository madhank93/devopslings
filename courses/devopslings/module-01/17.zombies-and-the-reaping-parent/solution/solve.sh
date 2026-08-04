#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

install -d /root/answers

# A zombie is not a process. It is an exit status being held in the table until
# its parent collects it. There is nothing there to receive a signal, which is
# why kill -9 returns 0 and changes nothing.
echo alreadydead > /root/answers/why

# The fix belongs in the parent. Two ways, both correct:
#
#   - call waitpid(-1, WNOHANG) in the loop and collect whatever has finished
#   - set SIGCHLD to SIG_IGN, which tells the kernel not to keep exit statuses
#     for this process's children at all
#
# The explicit wait is used here because it keeps the exit status available,
# which a real job runner wants — a worker that failed is worth knowing about.
cat > /usr/local/bin/job-runner <<'PY'
#!/usr/bin/env python3
import os, time

print("job-runner: started", flush=True)
done = 0
failed = 0
while True:
    pid = os.fork()
    if pid == 0:
        time.sleep(0.05)
        os._exit(0)

    # Collect everything that has finished since the last pass. WNOHANG means
    # this never blocks: if no child is ready, it returns immediately.
    while True:
        try:
            reaped, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if reaped == 0:
            break
        if os.waitstatus_to_exitcode(status) != 0:
            failed += 1

    done += 1
    with open("/srv/jobrunner/completed", "w") as f:
        f.write(str(done))
    time.sleep(0.05)
PY
chmod 0755 /usr/local/bin/job-runner

systemctl restart job-runner.service
sleep 3
