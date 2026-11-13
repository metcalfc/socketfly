#!/usr/bin/env bash
# Runs INSIDE the Sprite: sprite exec -s <name> -- bash -s < scripts/check-sfw.sh
# Prints PASS/FAIL per check and a final "GATE: PASS|FAIL" line.
# Branch on that line, not on the exit status of the remote command.
set -uo pipefail

fail=0
pass() { echo "PASS  $*"; }
bad()  { echo "FAIL  $*"; fail=1; }

if command -v sfw >/dev/null; then pass "sfw on PATH: $(command -v sfw)"; else bad "sfw not on PATH"; fi

for h in firewall-api.socket.dev registry.npmjs.org; do
  if getent hosts "$h" >/dev/null; then pass "resolves $h"
  else bad "cannot resolve $h (network policy needs it)"; fi
done

case "$(command -v npm)" in
  "$HOME/.local/bin/npm") pass "npm resolves to sfw shim" ;;
  *) echo "WARN  npm resolves to $(command -v npm), not the shim" ;;
esac

work=$(mktemp -d)
cd "$work" && /.sprite/bin/npm init -y >/dev/null 2>&1
/.sprite/bin/npm cache clean --force >/dev/null 2>&1

if sfw /.sprite/bin/npm install --ignore-scripts is-number >/dev/null 2>&1; then
  pass "clean package installs through sfw"
else
  bad "clean package failed through sfw (Socket API unreachable? sfw fails closed)"
fi

# crossenv@0.0.2-security is npm's inert placeholder for a removed typosquat.
# Socket lists it as known malware, so sfw must refuse it.
out=$(sfw /.sprite/bin/npm install --ignore-scripts crossenv 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'blocked npm package: name: crossenv'; then
  pass "known-malware package blocked (exit $rc)"
else
  bad "known-malware package NOT blocked (exit $rc)"
fi

cd / && rm -rf "$work"
[ "$fail" -eq 0 ] && echo "GATE: PASS" || echo "GATE: FAIL"
