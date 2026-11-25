#!/bin/sh
set -e
# A shell exec'd with an AF_INET/AF_INET6 socket on fd 0. sched_process_exec
# fires after the new image is in place, so comm is the shell's own name.
cat > /root/revshell.bt <<'BT'
tracepoint:sched:sched_process_exec
/ comm == "sh" || comm == "bash" || comm == "dash" || comm == "zsh" /
{
  $f = curtask->files->fdt->fd[0];
  if ($f != 0 && ($f->f_inode->i_mode & 0xf000) == 0xc000) {
    $fam = ((struct socket *)$f->private_data)->sk->__sk_common.skc_family;
    if ($fam == 2 || $fam == 10) {
      time("%H:%M:%S ");
      printf("reverse shell: comm=%s uid=%d\n", comm, uid);
    }
  }
}
BT

# The same answer from the box, as a student would find it: the bash whose
# fd 0 is a socket, and the remote end of its TCP connection.
conns=$(ss -tnpH)
found=""
for p in $(pgrep -x bash || true); do
  case "$(readlink "/proc/$p/fd/0" 2>/dev/null || true)" in socket:*) ;; *) continue ;; esac
  case "$conns" in *"pid=$p,"*) found=$p; break ;; esac
done
peer=$(printf '%s\n' "$conns" | awk -v p="pid=$found," 'index($0, p) {print $5; exit}')
mkdir -p /root/answers
printf 'pid: %s\npeer: %s\n' "$found" "$peer" > /root/answers/revshell.md
cat /root/answers/revshell.md
