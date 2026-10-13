# Persistent fleet status bar. Source this from ~/.tmux.conf using the exact
# line printed by fm-statusbar.sh source-line from a stable installed checkout.
# current_file and socket_path bind the loader to this snippet and server.
run-shell 'bash "#{d:current_file}/fm-statusbar.sh" --socket "#{socket_path}" theme'
