Delivery-failure live validation: PASS

Head: 3c6f7ab48d676c831e10f3c3a05a3c5b7367cf46
Transport: tmux 3.4, private worktree-local socket.
Command: fm-validate timeout 300 bash .delivery-lab/check.sh
Exit code: 0

The reported problem was an evidence gap, not an observed failing product assertion.
One bounded exercise drove public bin/fm-spawn.sh against real tmux, real shells, isolated Git fixtures, and a lightweight shell worker standing in for Codex.
No paid sessions, other-home endpoints, shared worktree-pool administration, lint, static analysis, or broad tests ran.
At most one lab worker ran at a time.
Existing fixture helpers stubbed external preflights; treehouse acquisition was replaced with cd into the isolated fixture worktree.
The real transport, command buffer, launch wrapper, reservation handling, cleanup C-c, and worker process executed.

Unstarted: a real pane received the literal source command, then Enter was redirected to a nonexistent target on the private server, producing a real tmux rejection.
Spawn failed, cleanup sent C-c, and the reservation was removed.
Sending Enter again followed by a marker command confirmed the pane remained responsive and the cancelled buffered command did not start a worker.

Started: the shim delivered Enter to the real pane, waited for the worker startup acknowledgement, then returned the error from the same rejected tmux operation.
This deliberately injected a delivery error after acceptance; it was not an organically occurring lost acknowledgement.
Spawn failed with its preservation message.
The worker PID stayed alive, metadata and reservation remained, and the reservation disappeared when the worker finished.

No source changes were needed.
The private server was stopped and the worktree-local lab removed after evidence retention.
This closes the requested live transport cases only, not full-suite, all-backend, or vendor-harness validation.
