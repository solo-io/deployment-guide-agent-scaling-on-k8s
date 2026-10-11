#!/usr/bin/env bash
# Create the CA and JWT pools Substrate consumes but never creates, after `helm install substrate`.
# Until they exist the pod-certificate-controller cannot sign PodCertificateRequests and every
# Substrate pod stays in ContainerCreating.
#
# Adapted from enterprise-kagent v1.0.0-alpha8
# test/environment/config/kagent/bootstrap-substrate-ca.sh:73-137.
#
# Usage: KUBECTL_ATE=/path/to/kubectl-ate bootstrap-pools.sh [substrate-namespace]
# kubectl-ate must be v0.4.0-alpha1 (the upstream release substrate-enterprise
# 0.4.0-alpha1-066b803 is built from).
#
# make-ca-pool and make-jwt-pool fail if the Secret already exists, so existing pools are skipped.
# Pools are valid for one year by default (--validity 8760h0m0s). Rotation is delete and re-run.
set -euo pipefail

NAMESPACE="${1:-ate-system}"
PCC_NAMESPACE="podcertificate-controller-system"   # fixed by the pod-certificate-controller
ATE="${KUBECTL_ATE:?set KUBECTL_ATE to the kubectl-ate v0.4.0-alpha1 binary}"

ca_pool() {
  local name="$1" ns="$2"; shift 2
  if kubectl get secret "$name" -n "$ns" >/dev/null 2>&1; then
    echo "exists: $ns/$name"; return
  fi
  "$ATE" admin make-ca-pool --ca-id=1 --name="$name" --secret-namespace="$ns" "$@"
}

jwt_pool() {
  local name="$1" ns="$2"
  if kubectl get secret "$name" -n "$ns" >/dev/null 2>&1; then
    echo "exists: $ns/$name"; return
  fi
  "$ATE" admin make-jwt-pool --key-id=1 --name="$name" --secret-namespace="$ns"
}

ca_pool  service-dns-ca-pool  "$PCC_NAMESPACE"
ca_pool  pod-identity-ca-pool "$PCC_NAMESPACE"
jwt_pool actor-id-jwt-pool    "$NAMESPACE"
ca_pool  actor-id-ca-pool     "$NAMESPACE"
# The egress gateway terminates actor HTTPS and re-signs it with this pool.
ca_pool  egress-mitm-ca-pool  "$NAMESPACE" --key-type=ECDSAP256

# ate-api-server verifies actor identity certificates against the actor-id CA root, as plain PEM.
root_pem="$(kubectl get secret actor-id-ca-pool -n "$NAMESPACE" -o jsonpath='{.data.pool}' \
  | base64 --decode | jq -r '.CAs[0].RootCertificateDER' | base64 --decode \
  | openssl x509 -inform der -outform pem)"
kubectl create secret generic actor-id-ca-certs -n "$NAMESPACE" \
  --from-literal=ca.crt="$root_pem" --dry-run=client -o yaml | kubectl apply --server-side -f -

# ServiceAccount-token validation for ate-api. The chart sets no audience of its own.
# The issuer must be the cluster's own: the product's fleet script hardcodes
# https://kubernetes.default.svc, but kind 1.35.0 issues https://kubernetes.default.svc.cluster.local,
# and with the mismatch every token-authenticated ate-api call (kubectl-ate get, suspend, ...)
# fails with `token issuer ... not trusted`. Read it from the API server instead.
ISSUER="$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)"
kubectl create configmap ate-api-authentication -n "$NAMESPACE" \
  --from-literal=authentication.yaml="actorIdentityJWTProvider: kubernetes
jwtProviders:
- name: kubernetes
  issuer: ${ISSUER}
  audiences: [api.ate-system.svc]
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
" \
  --dry-run=client -o yaml | kubectl apply --server-side --force-conflicts -f -
