#!/bin/bash
# Bring the kagent UI up for a demo on the cluster your KUBECONFIG points at, after the guide has run.
#
#   auto-build/demo-ui.sh
#
# Restarts the worker pool if its containers restarted in place (a node restart, D18 in the guide's
# Attachment C.23), forwards the UI to 127.0.0.1:${KAGENT_UI_PORT:-14000} and Keycloak to
# 127.0.0.1:${KEYCLOAK_PORT:-18080}, checks both answer, and says where the passwords are. A port
# that already answers is left as it is. Prints no password.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
UI_PORT=${KAGENT_UI_PORT:-14000}
KC_PORT=${KEYCLOAK_PORT:-18080}
CREDS=${KAGENT_UI_CREDENTIALS_FILE:-$HERE/.env.local}
ATE=$(command -v kubectl-ate || echo "${ATE_BIN_DIR:-$HOME/.local/bin}/kubectl-ate")
echo "context: $(kubectl config current-context)"

# Containers that restarted in place keep stale worker registrations: turns are refused until the
# pool is restarted and every worker has registered again.
restarts=$(kubectl get pods -n kagent -o json \
  | jq '[.items[] | select(.metadata.name | startswith("kagent-default-")) | .status.containerStatuses[]?.restartCount] | add // 0')
if [ "$restarts" -gt 0 ]; then
  echo "worker pool: containers restarted in place ($restarts); restarting the pool"
  kubectl rollout restart deployment/kagent-default -n kagent >/dev/null
  kubectl rollout status deployment/kagent-default -n kagent --timeout=300s
  for i in $(seq 1 60); do
    want=$(kubectl get pods -n kagent -o name | grep -c '/kagent-default-')
    have=$("$ATE" get workers | awk 'NR > 1 && $4 != "0/0" {print $(NF-1)}' | while read -r pod; do
      kubectl get pod -n kagent "${pod#kagent/}" >/dev/null 2>&1 && echo registered; done | grep -c registered || true)
    [ "$have" -ge "$want" ] && break
    sleep 5
  done
  echo "worker pool: ${have} of ${want} workers registered"
else
  echo "worker pool: no in-place restarts, left as it is"
fi

# forward <local port> <namespace> <service> <service port> <check URL>
forward() {
  if curl -sS -o /dev/null --max-time 5 "$5" 2>/dev/null; then
    echo "$3: already answering on 127.0.0.1:$1, left as it is"; return 0
  fi
  if lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "$3: port $1 is held by something that does not answer; free it and run this again" >&2; return 1
  fi
  nohup kubectl port-forward --address 127.0.0.1 -n "$2" "service/$3" "$1:$4" >/dev/null 2>&1 &
  for i in $(seq 1 20); do curl -sS -o /dev/null --max-time 2 "$5" 2>/dev/null && break; sleep 1; done
  if curl -sS -o /dev/null --max-time 5 "$5" 2>/dev/null; then echo "$3: forwarded to 127.0.0.1:$1"
  else echo "$3: started a forward on $1, but it does not answer" >&2; return 1; fi
}
ok=0
forward "$UI_PORT" kagent kagent-ui 8080 "http://127.0.0.1:${UI_PORT}/" || ok=1
forward "$KC_PORT" keycloak keycloak "$KC_PORT" "http://keycloak.localhost:${KC_PORT}/realms/kagent/.well-known/openid-configuration" || ok=1
[ "$ok" -eq 0 ] || exit 1

echo
echo "UI:          http://localhost:${UI_PORT}"
echo "Users:       admin, writer, reader"
echo "Passwords:   ${CREDS} (KAGENT_ADMIN_PASSWORD, KAGENT_WRITER_PASSWORD, KAGENT_READER_PASSWORD)"
