# Copyright (c) 2026 GitOps Manager, S.L.
# SPDX-License-Identifier: Apache-2.0
"""Run one tofu command apart from the workflow step, for run_tofu_stage.sh.

  setsid --fork python3 tofu_session.py <run dir> <tofu args...>

Started in a session of its own, so it is not in the step's process tree and
a cancelled step can't kill it: OpenTofu then gets to finish what it's doing,
write its state and release its lock. Writes, in <run dir>:

  session.pid  this process          tofu.pid  OpenTofu's
  log          OpenTofu's output     rc        its exit code, when it ends

The output goes to a file, never the step's pipe, which closes when a
cancelled step is killed. Only run_tofu_stage.sh signals OpenTofu, and only
once (a second interrupt makes it exit at once): this process ignores the
signals itself, and OpenTofu keeps the default handling.
"""
import os
import signal
import subprocess
import sys


def write(path, text):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def main():
    run, args = sys.argv[1], sys.argv[2:]
    write(os.path.join(run, "session.pid"), str(os.getpid()))
    # OpenTofu must get the default handling of the interrupt, whatever this
    # was started with: a step started in the background starts its children
    # with SIGINT ignored, and an ignored interrupt would never reach it.
    for s in (signal.SIGINT, signal.SIGTERM):
        signal.signal(s, signal.SIG_DFL)
    with open(os.path.join(run, "log"), "ab", buffering=0) as log:
        tofu = subprocess.Popen(["tofu", *args], stdin=subprocess.DEVNULL,
                                stdout=log, stderr=subprocess.STDOUT)
        # Ignored here only after the start, so OpenTofu doesn't inherit it.
        for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(s, signal.SIG_IGN)
        write(os.path.join(run, "tofu.pid"), str(tofu.pid))
        rc = tofu.wait()
    # Killed by a signal: the shell's convention, 128 + the signal.
    write(os.path.join(run, "rc"), str(rc if rc >= 0 else 128 - rc))


if __name__ == "__main__":
    main()
