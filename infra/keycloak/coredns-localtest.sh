#!/usr/bin/env bash
# Make keycloak.localtest.me resolve to the Keycloak Service inside the cluster.
#
# The OIDC issuer must be byte-identical for the browser and the kagent controller. localtest.me is
# public DNS that resolves to 127.0.0.1, so on the workstation it reaches a port-forward; inside the
# cluster this CoreDNS rewrite sends the same name to keycloak.keycloak.svc.cluster.local, whose
# Service listens on the same port (18080). Idempotent. CoreDNS's reload plugin applies it within
# about 30 seconds.
set -euo pipefail
LINE='    rewrite name keycloak.localtest.me keycloak.keycloak.svc.cluster.local'
cur="$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')"
if grep -qF 'rewrite name keycloak.localtest.me' <<<"$cur"; then
  echo "rewrite already present"; exit 0
fi
new="$(awk -v line="$LINE" '{print} /^[[:space:]]*ready[[:space:]]*$/ && !done {print line; done=1}' <<<"$cur")"
kubectl create configmap coredns -n kube-system --from-literal=Corefile="$new" --dry-run=client -o yaml \
  | kubectl patch configmap coredns -n kube-system --type merge --patch-file /dev/stdin
echo "rewrite added"
