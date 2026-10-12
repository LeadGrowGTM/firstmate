# Delivery-failure validation

Both requested cases passed through the real fm-spawn executable and a private tmux server with a 120x35 terminal. Homes were marked with fm-lab-home; lifecycle bypass and path overrides were unset.

Before startup: tmux buffered the launch command and rejected Enter redirected to a nonexistent disposable target. Cleanup sent C-c and removed the reservation. A subsequent Enter did not launch the cancelled command; a marker command confirmed the shell remained responsive.

After startup: tmux delivered Enter and a lightweight shell worker acknowledged startup. An injected transport error followed. Spawn preserved the running PID, metadata, and reservation. The reservation disappeared when the worker exited.

Command: fm-validate timeout 300 bash /home/firstmate/.no-mistakes/evidence/01M4RC9WKC7KE87QSFKC46TDXM/delivery-recheck-driver.sh

The command returned 1 solely because cleanup encountered generated read-only hook directories after both assertions passed. Owner write permission was restored within the disposable lab and cleanup completed. The private server was stopped. No source changes remain.

External preflights were stubbed and pool acquisition was replaced with entry into an isolated Git fixture. The real spawn executable, transport, shell buffer, launch wrapper, reservations, and cleanup executed. The shell worker substitutes for Codex; this proves transport lifecycle behavior, not vendor authentication. No paid sessions were launched; at most one lightweight worker ran at a time.

This bounded recheck closes the prior delivery-failure gap. Prior admission and concurrency evidence was retained, not re-driven. No broad suite, lint, or static analysis ran.
