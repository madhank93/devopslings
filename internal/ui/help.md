## Keys

These match [kubelings](https://github.com/madhank93/kubelings) and
[golings](https://github.com/madhank93/golings), so the muscle memory carries
between the three courses.

| key | does |
| --- | --- |
| `↵` | play — start the lesson, then open a shell in it |
| `i` | start the lesson, staying here |
| `t` | shell into the sandbox |
| `v` | verify — grade your work |
| `r` | reset the lesson from scratch |
| `d` | stop the sandbox (asks first — it drops volumes) |
| `h` | hint · `s` solution (asks first) |
| `/` | filter · `n` next unsolved · `esc` clear |
| `tab` | move focus · `j/k` scroll · `pgup/pgdn` page |
| `g` | reload the course from disk · `G` jump to the end |
| `m` | copy mode — release the mouse to the terminal |
| `esc` | cancel a running task · `q` quit |

## Inside the sandbox

`t` (and `↵`) open a shell with the lesson wired into it:

| command | does |
| --- | --- |
| `task` | print the task again |
| `hint` · `solution` | the same text these panes show |
| `verify` | run the check without leaving the box |
| `reset` | start the lesson over |

On a host-side lesson `verify` calls the binary, so a pass is recorded. Inside
a container it runs the lesson's own check script — same result, but nothing
records it, so press `v` here afterwards.

## While a task runs

Output streams into the lower pane as it is produced. A first `start` on a
heavy sandbox pulls images and takes minutes; that is what the pane is for.
`esc` kills the process group — the sandbox may be left half-built, and `r` is
the way back to a known state.
