. "$(dirname "$0")/env.sh"
G="$W/bin/fm-treehouse-guard.sh"
mkclone() { # <origin> <dest>
  git init -q --bare -b main "$1"; git clone -q "$1" "$2" 2>/dev/null
  ( cd "$2"; git checkout -q -b main 2>/dev/null; echo hi > README; git add README; git commit -qm init; git push -q origin main; git remote set-head origin main )
}
LAB2="$SBX/lab2"; "$W/bin/fm-lab-home.sh" create "$LAB2" >/dev/null
mkclone "$SBX/origin-other.git" "$LAB2/projects/other"
( cd "$LAB2/projects/other"; c=$(treehouse get --lease 2>/dev/null); treehouse return --force "$c" >/dev/null 2>&1 )
( cd "$LAB/projects/demo"; c=$(treehouse get --lease 2>/dev/null); treehouse return --force "$c" >/dev/null 2>&1 )
st() { for p in "$LAB/projects/demo" "$LAB2/projects/other" "$LAB"; do echo "-- pool of $p"; ( cd "$p" && treehouse status 2>&1 | grep -v -e 'new version' -e 'treehouse update' -e '^$' ); done; }
echo "## before: this home's project pool (demo), another home's project pool (other), and the home's own pool each hold one prunable copy"
st
echo "## sweep for home LAB, pool root well under 5 GB"
run du -sh "$HOME/.treehouse"
run env FM_HOME="$LAB" "$G" sweep
run cat "$LAB/state/.treehouse-guard.result"
echo "## after: only this home's project pool was pruned; plain-dir under projects/ was skipped silently"
st
echo "## size boundary: 4.9 GB of real allocated blocks inside a leased copy -> still nothing to report"
fallocate -l 5000M "$HOME/.treehouse/demo-e6da16/2/demo/build-output.bin"
run du -sk "$HOME/.treehouse"
run env FM_HOME="$LAB" "$G" sweep
run cat "$LAB/state/.treehouse-guard.result"
echo "## push it past 5 GB -> one finding line, printed and recorded"
fallocate -l 400M "$HOME/.treehouse/demo-e6da16/2/demo/build-output-2.bin"
run du -sk "$HOME/.treehouse"
run env FM_HOME="$LAB" "$G" sweep
run cat "$LAB/state/.treehouse-guard.result"
echo "## the oversized leased copy was reported, not deleted"
run ls -la "$HOME/.treehouse/demo-e6da16/2/demo"
