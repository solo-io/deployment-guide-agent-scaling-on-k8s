#!/bin/bash
# Run the guide's blocks verbatim against the cluster your KUBECONFIG points at.
#
#   auto-build/run.sh                  every block, in order
#   auto-build/run.sh --from <id>      resume at a block
#   auto-build/run.sh --to <id>        stop after a block
#   auto-build/run.sh --dry-run        print the script, run nothing
#
# Credentials come from the environment, or from auto-build/.env.local (gitignored).
# The log, one section per block, goes to auto-build/logs/.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
GUIDE="$HERE/../docs/deployment-guide-keycloak.md"
CREDS="KAGENT_LICENSE_KEY AGENTGATEWAY_LICENSE_KEY ANTHROPIC_API_KEY"

if [ -f "$HERE/.env.local" ]; then set -a; . "$HERE/.env.local"; set +a; fi
# Step 23 saves the UI users' generated passwords here, and reuses any already set, so a rebuilt
# cluster keeps the same sign-in.
export KAGENT_UI_CREDENTIALS_FILE="$HERE/.env.local"
for c in $CREDS; do
  v="${!c:-}"
  if [ -z "$v" ] || [ "${v#<}" != "$v" ]; then
    echo "run.sh: $c is not set (or is still the guide's placeholder)" >&2; exit 2
  fi
  export "__CRED_$c=$v"
done

SCRIPT="$(python3 -I "$HERE/extract.py" "$GUIDE" "$@")" || exit 2
case " $* " in *" --dry-run "*) printf '%s\n' "$SCRIPT"; exit 0 ;; esac
bash -n <(printf '%s\n' "$SCRIPT") || { echo "run.sh: extracted script is not valid bash" >&2; exit 2; }

mkdir -p "$HERE/logs"
LOG="$HERE/logs/run-$(date -u +%Y%m%dT%H%M%SZ).log"
echo "context: $(kubectl config current-context 2>/dev/null || echo none)   log: $LOG"
# Run from a file with stdin closed: a block that reads stdin (kubectl run -i, for one) would
# otherwise consume the rest of the script and end the run early with status 0.
SCRIPT_FILE="$HERE/logs/$(basename "$LOG" .log).sh"
printf '%s\n' "$SCRIPT" > "$SCRIPT_FILE"
bash "$SCRIPT_FILE" < /dev/null > "$LOG" 2>&1
rc=$?
last=$(grep '^>>>' "$LOG" | tail -1)
if [ $rc -eq 0 ] && [ "$last" != ">>>DONE" ]; then
  echo "run.sh: the script ended without reaching its last block" >&2; rc=1
fi
echo "exit $rc   last marker: $last"
exit $rc
