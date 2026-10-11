# Deployment Guide for Operating, Isolating, and Scaling Agent Workloads on Kubernetes

**Updated:** October 11th, 2026

**Certified against:** kagent-enterprise 1.0.0-alpha8, Agent Substrate (substrate-enterprise) 0.4.0-alpha1-066b803, Solo Enterprise for agentgateway v2026.7.1

## Introduction

Running one agent is a deployment. Running a platform of them is a different problem: every team
needs somewhere to run its agents, a way to keep each agent's credentials away from the agent
itself, and one controlled path out to the models and tools those agents call.

This guide runs agents on Agent Substrate under kagent, and sends every model call they make
through Solo Enterprise for agentgateway.

## What goes wrong on the ungoverned path

These are the failure modes of running agents as ordinary pods, each with its own copy of
everything. Each one is addressed by a step in this guide.

- **An idle agent holds its pod.** An agent spends most of its life waiting for the next message,
  and a pod holds its memory reservation and CPU request the whole time. On this release, a pod per
  open conversation with the same isolation holds about 58 MiB whether anything is happening or not.
  SCALE measures it against Substrate, where memory follows the turns actually running.
- **The model key lives in the agent.** The usual setup puts the provider key in the agent's
  environment, where anything that can read the process can read the key.
- **Every agent calls the provider directly.** There is no single place to authenticate agents,
  enforce a budget, or see which team spent what.
- **Agents share a kernel.** Containers on one node share the host kernel, so packing agents from
  different teams onto a node means trusting every one of them with it.
- **The UI and API are open by default.** On this release the bundled login issues an admin token
  to anyone who asks.

## What you will build

- kagent and Agent Substrate on a kind cluster: each conversation is its own actor, restored from
  a warm snapshot when a message arrives and suspended when the turn ends
- A gVisor sandbox per conversation, on a shared pool of worker pods
- Model credentials injected on the way out, so the agent only ever holds a placeholder
- Solo Enterprise for agentgateway in front of every model call: one consumer key per team,
  budgets and cost attribution, and nothing else in the cluster able to reach it
- MCP tools reached through the same gateway
- The UI and API behind Keycloak, with roles that decide who can chat and who can only read
- A measured answer to what a conversation costs, idle and running

## How this guide is organized

**Up and Running** installs everything and ends with one agent answering, its model call verified
as having passed through the enterprise gateway. Nothing else works until this does.

**Operate** follows one conversation through its life: how an agent becomes actors, where context
is kept between turns, how to inspect and act on actors, and what deleting one leaves behind.

**Isolate** covers what keeps conversations, credentials and users apart: the sandbox, credential
injection, the egress allowlist, MCP tools through the gateway, budgets, the snapshot store, and
Keycloak in front of the UI and API.

**Scale** compares a pod per conversation with Substrate and sizes the worker pool from the numbers.

**Validate** sends one conversation through every control and maps each result to the step that
set it.

**The order matters.** Isolate closes things Up and Running leaves open, in particular the bundled
login, so do not expose this cluster to anyone until Isolate is done.

## Version support

kagent-enterprise and Agent Substrate are pre-release. This guide is pinned to one tested set, and
every version, chart and image below is part of that set:

| Component | Version |
|---|---|
| kagent-enterprise (CRD and controller charts) | 1.0.0-alpha8 |
| Agent Substrate (substrate-enterprise chart) | 0.4.0-alpha1-066b803 |
| kubectl-ate | v0.4.0-alpha1 |
| kagent runtime image (`golang-adk`) | 1.0.0-alpha9, pinned by digest |
| Solo Enterprise for agentgateway | v2026.7.1 |
| Kubernetes | 1.35.0 on kind 0.32.0 |

Do not mix versions across this set. The Substrate chart, the worker image and kubectl-ate come
from the same release, and the runtime image is the one this kagent release was tested with.

## Environment setup

Set these before running anything. Every command below uses them.

```bash run id=environment-setup-env
# Pinned versions
export KAGENT_VERSION=1.0.0-alpha8
export SUBSTRATE_VERSION=0.4.0-alpha1-066b803
export KUBECTL_ATE_VERSION=v0.4.0-alpha1
export AGENT_GATEWAY_VERSION=v2026.7.1
export GATEWAY_API_VERSION=v1.6.1

# The cluster. The node image is pinned by digest.
export KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-agents}
export KIND_NODE_IMAGE=kindest/node:v1.35.0@sha256:4613778f3cfcd10e615029370f5786704559103cf27bef934597ba562b269661

# The worker image Substrate runs sandboxes on, and the agent runtime image.
# Substrate refuses an image that is not pinned: a changed image invalidates snapshots.
export WORKER_IMAGE=us-docker.pkg.dev/solo-public/substrate-enterprise/ateom-gvisor:v0.4.0-alpha1-066b803
export RUNTIME_IMAGE=ghcr.io/kagent-dev/kagent/golang-adk@sha256:26ae5c772d4a59b24ecb3619c3499e106e3b28abbc239de25b4ff8d746f97e69

# Licenses. Contact your Solo account team if you do not have them.
export KAGENT_LICENSE_KEY='<your-kagent-enterprise-license-key>'
export AGENTGATEWAY_LICENSE_KEY='<your-agentgateway-enterprise-license-key>'

# Model provider. Anthropic is the reference provider.
export ANTHROPIC_API_KEY='<your-anthropic-api-key>'
export MODEL=claude-haiku-4-5

# Where kubectl-ate is installed in Step 4. Must be on your PATH.
export ATE_BIN_DIR=${ATE_BIN_DIR:-$HOME/.local/bin}

# Local ports for the port-forwards in Step 9.
export KAGENT_API_PORT=${KAGENT_API_PORT:-18083}
export KAGENT_UI_PORT=${KAGENT_UI_PORT:-14000}
```

### What you need before you start

| **Requirement** | **Needed for** | **Notes** |
|---|---|---|
| Docker on a machine with 6 CPU and 12 GiB for it | Everything | The reference environment is Colima on macOS (`colima start --cpu 6 --memory 12`). The full stack settles at about 5 GiB on the node. |
| `kind` 0.32.0, `kubectl`, `helm`, `jq`, `curl`, `openssl` | Everything | |
| kagent-enterprise license key | Step 5 | |
| Solo Enterprise for agentgateway license key | Steps 3 and 6 | Substrate's chart requires one too |
| Anthropic API key | Step 6 | It is stored once, in the gateway. Nothing else holds it. |
| Egress from the cluster to `ghcr.io`, `us-docker.pkg.dev`, `docker.io` and `api.anthropic.com` | Everything | Images, and the model calls |
| `kubectl-ate` | Step 4 | Downloaded in Step 4 |

> [!WARNING]
> Use `curl -sS` rather than `curl -s` **throughout this guide.** The checks in Step 9 go through a port-forward, and a port-forward that has died prints nothing and exits 7. An empty result then looks like a pass. `-S` keeps curl quiet on success and makes it say so on failure.
>
> **If you paste these blocks into zsh, turn on comments first.** zsh is the default shell on macOS and does not allow `#` comments in an interactive session, so every commented line returns `command not found: #`. Run `setopt interactive_comments` once per shell.
>
> **Running a second kind cluster on the same Docker host** can leave the new cluster's `kube-proxy` crashing with `too many open files`, and every pod then times out reaching the API server. Raise the inotify limit on the Docker host: on Colima, `colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=512`. It resets when the VM restarts.

### Ports used in this guide

| **Port** | **What** |
|---|---|
| 18083 | kagent controller API, port-forwarded from Step 9. `KAGENT_API_PORT` moves it. |
| 14000 | kagent UI, port-forwarded from Step 9. `KAGENT_UI_PORT` moves it. |

kubectl-ate opens and closes its own port-forward to Substrate's API on every call, so it needs no
port of yours.

**Every port-forward binds 127.0.0.1 only.** Until Step 23, anyone who can reach the UI port can
get an admin token without a password (Step 5 explains). `kubectl port-forward` binds localhost by
default; the `--address 127.0.0.1` below makes it explicit so it is not changed by accident.

**Port-forwards die.** A port-forward is attached to one pod, and a rollout replaces the pod. The
symptom is `Failed to connect to localhost port ...` or an empty reply right after a step that
appeared to work. Define this now and re-run it whenever something refuses to connect:

```bash run id=ports-forwards-helper
forwards() {
  pkill -f "kubectl port-forward.*-n kagent" 2>/dev/null || true
  kubectl rollout status deployment/kagent-controller -n kagent --timeout=120s
  kubectl rollout status deployment/kagent-ui -n kagent --timeout=120s
  kubectl port-forward --address 127.0.0.1 -n kagent deployment/kagent-controller ${KAGENT_API_PORT}:8083 >/dev/null 2>&1 &
  kubectl port-forward --address 127.0.0.1 -n kagent service/kagent-ui ${KAGENT_UI_PORT}:8080 >/dev/null 2>&1 &
  sleep 2
  echo "forwards up: controller ${KAGENT_API_PORT}, ui ${KAGENT_UI_PORT}"
}
```

The `pkill` pattern closes every forward you have open against the `kagent` namespace. The
`|| true` matters on a first run: `pkill` exits non-zero when nothing matched.

## UP AND RUNNING

Before you can operate, isolate or scale anything, you need kagent running agents on Substrate and
their model calls going through the enterprise gateway.

If something breaks later, come back here and confirm this still works before changing anything
else.

**What you are going to do:** create a cluster with the certificate APIs Substrate uses, install
Substrate and its certificate authorities, install kagent with a pool of workers, put Solo
Enterprise for agentgateway in front of the model, fence it so only agent traffic reaches it,
declare one agent, and prove its first answer went through the gateway.

**What you will have that you did not have before:** an agent that holds no model key, whose
conversations each run in their own sandbox, and whose every model call is authenticated and
recorded by one gateway.

**Verified on:** kind cluster `agents` (kind 0.32.0, `kindest/node:v1.35.0`), created fresh beside another cluster on the same Docker host, 2026-10-11 21:56 UTC, then deleted and rebuilt from this document with `auto-build/run.sh` at 22:16 UTC. Every `run` block in this section was executed verbatim, in document order, in one bash session, with the credentials applied after the environment block. kagent-enterprise 1.0.0-alpha8, substrate-enterprise 0.4.0-alpha1-066b803, kubectl-ate v0.4.0-alpha1, Solo Enterprise for agentgateway v2026.7.1, Gateway API v1.6.1.

### Step 1: Create the cluster

Substrate gives every control plane and worker pod a certificate through two Kubernetes APIs,
PodCertificateRequest and ClusterTrustBundle, both in `certificates.k8s.io/v1beta1` and behind
feature gates on 1.35. This is the configuration kagent's own CI tests on. A cluster where you
cannot turn them on is covered in Attachment B.

```bash run id=kind-cluster
kind create cluster --name "${KIND_CLUSTER_NAME}" --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
featureGates:
  ClusterTrustBundle: true
  ClusterTrustBundleProjection: true
  PodCertificateRequest: true
runtimeConfig:
  "api/alpha": "false"
  "certificates.k8s.io/v1beta1": "true"
nodes:
  - role: control-plane
    image: ${KIND_NODE_IMAGE}
EOF
```

Confirm the API is served and the gates are on:

```bash run id=step-1-certificates-api
kubectl api-resources --api-group=certificates.k8s.io
kubectl get --raw /metrics | grep -E 'kubernetes_feature_enabled\{name="(ClusterTrustBundle|ClusterTrustBundleProjection|PodCertificateRequest)"'
```

**Verified on 2026-10-11:**

```text
NAME                         SHORTNAMES   APIVERSION                    NAMESPACED   KIND
certificatesigningrequests   csr          certificates.k8s.io/v1        false        CertificateSigningRequest
clustertrustbundles                       certificates.k8s.io/v1beta1   false        ClusterTrustBundle
podcertificaterequests                    certificates.k8s.io/v1beta1   true         PodCertificateRequest
kubernetes_feature_enabled{name="ClusterTrustBundle",stage="BETA"} 1
kubernetes_feature_enabled{name="ClusterTrustBundleProjection",stage="BETA"} 1
kubernetes_feature_enabled{name="PodCertificateRequest",stage="BETA"} 1
```

`clustertrustbundles` and `podcertificaterequests` at `v1beta1`, and all three gates at 1. A gate
at 0 or a missing resource here means Step 4 never finishes: every Substrate pod waits for a
certificate that nothing can issue.

### Step 2: Install the CRDs

The kagent-enterprise CRD chart carries Substrate's CRDs as well (`WorkerPool`, `SandboxConfig`,
`EnterpriseSubstrateClusterTrustBundle`) when `substrate.enabled` is set. Substrate's own release
in Step 3 needs them first. The Gateway API CRDs are for the enterprise gateway in Step 6.

```bash run id=helm-kagent-crds
helm upgrade -i kagent-crds \
  oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds \
  --version ${KAGENT_VERSION} \
  --namespace kagent --create-namespace \
  --set substrate.enabled=true
```

```bash run id=gateway-api-crds
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml
```

Check what arrived:

```bash run id=step-2-crds
kubectl get crd -o name | grep -E 'kagent\.dev|ate\.dev|ate\.solo\.io' | sort
```

**Verified on 2026-10-11:**

```text
customresourcedefinition.apiextensions.k8s.io/agents.api.kagent.dev
customresourcedefinition.apiextensions.k8s.io/agenttemplates.api.kagent.dev
customresourcedefinition.apiextensions.k8s.io/csidriverconfigs.ate.dev
customresourcedefinition.apiextensions.k8s.io/enterprisesubstrateclustertrustbundles.ate.solo.io
customresourcedefinition.apiextensions.k8s.io/harnesses.api.kagent.dev
customresourcedefinition.apiextensions.k8s.io/mcpservers.kagent.dev
customresourcedefinition.apiextensions.k8s.io/modelconfigs.api.kagent.dev
customresourcedefinition.apiextensions.k8s.io/modelproviderconfigs.api.kagent.dev
customresourcedefinition.apiextensions.k8s.io/remotemcpservers.api.kagent.dev
customresourcedefinition.apiextensions.k8s.io/sandboxconfigs.ate.dev
customresourcedefinition.apiextensions.k8s.io/sandboxtemplates.api.kagent.dev
customresourcedefinition.apiextensions.k8s.io/workerpools.ate.dev
```

There is no `ActorTemplate` and no `Actor` CRD. kagent creates those through Substrate's own API
(ate-api), not as Kubernetes objects, which is why Step 4 installs a CLI to see them.

The CRD chart version must equal the controller chart version in Step 5. Both come from
`KAGENT_VERSION`.

### Step 3: Install Substrate

Substrate is its own Helm release, named `substrate`, in namespace `ate-system`. The kagent chart
in Step 5 addresses Substrate's API at `api.ate-system.svc`, so keep both names.

The chart requires an enterprise license Secret before it will render. Create it from your
agentgateway license, over stdin so the key never appears in a command line or in your shell
history:

```bash run id=substrate-license
kubectl create namespace ate-system
printf '%s' "$AGENTGATEWAY_LICENSE_KEY" | kubectl create secret generic enterprise-agentgateway-license \
  -n ate-system --from-file=enterprise-agentgateway-license-key=/dev/stdin
```

Install the chart:

```bash run id=helm-substrate
helm upgrade -i substrate \
  oci://us-docker.pkg.dev/solo-public/enterprise-substrate-helm/substrate \
  --version ${SUBSTRATE_VERSION} \
  --namespace ate-system \
  -f - <<EOF
global:
  licensing:
    createSecret: false
    secretName: enterprise-agentgateway-license
usePodCertificateAPI: true
credentialProvider:
  namespacePolicies:
    - atespace: kagent
      allowedNamespaces: [kagent]
EOF
```

`credentialProvider.namespacePolicies` is how a model key gets from a Kubernetes Secret into an
outbound request without passing through the agent. The credential provider reads Secrets only for
the grants listed here, and the default is none. This one lets actors in the `kagent` atespace,
which is where kagent places every conversation, use Secrets in the `kagent` namespace.

> [!NOTE]
> **The Substrate pods sit in `ContainerCreating` until Step 4, and that is correct.** They mount certificates issued from certificate authorities that Substrate consumes but never creates. Do not wait for them here.

The chart also deploys a snapshot store, RustFS, with fixed default credentials. Step 22 replaces
them. Until then, treat anything stored in it as readable by anyone in the cluster.

### Step 4: Create Substrate's certificate authorities

Substrate signs every certificate it issues from five pools: two for the pod certificate
controller (service DNS names and pod identities), and three in `ate-system` (actor identity
certificates, actor identity tokens, and the egress gateway's interception CA). Helm creates none
of them. `kubectl-ate` does.

Install kubectl-ate and check it against the release's published digest:

```bash run id=kubectl-ate-install
ATE_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ATE_ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
mkdir -p "$ATE_BIN_DIR"
curl -sSLf -o "$ATE_BIN_DIR/kubectl-ate" \
  "https://github.com/kagent-dev/substrate/releases/download/${KUBECTL_ATE_VERSION}/kubectl-ate-${ATE_OS}-${ATE_ARCH}"
chmod +x "$ATE_BIN_DIR/kubectl-ate"
case "${ATE_OS}-${ATE_ARCH}" in
  darwin-arm64) ATE_SHA=4e22bd87ed76f5b03f51b5f9fa1393e097ba8d19cbcbb6b568187fc65eed4379 ;;
  darwin-amd64) ATE_SHA=031f28ebdc6fdb5a5ccb2dcc4b3873daf6644e0ba42f1ec5e051f11791180ed9 ;;
  linux-arm64)  ATE_SHA=da62dd5137c03e9ede464ddd9cb43ab25577c8f2c3710406a9dbc3731c230cc9 ;;
  linux-amd64)  ATE_SHA=81e60a6dfd9691ff1c41c8ffafb1042db05bfd0a94f8e0ec466a853284956faf ;;
esac
echo "${ATE_SHA}  $ATE_BIN_DIR/kubectl-ate" | shasum -a 256 -c -
```

`shasum` prints the binary's path followed by `OK`. Anything else, stop: the download is not the release this guide was tested with.

The binary has no `version` command, so the URL and the digest are the only record of which
release you have.

Create the pools. `make-ca-pool` and `make-jwt-pool` fail if the Secret already exists, so each is
skipped when it is already there and the block is safe to re-run:

```bash run id=substrate-pools
ca_pool() {
  local name="$1" ns="$2"; shift 2
  if kubectl get secret "$name" -n "$ns" >/dev/null 2>&1; then echo "exists: $ns/$name"; return; fi
  kubectl-ate admin make-ca-pool --ca-id=1 --name="$name" --secret-namespace="$ns" "$@"
}
jwt_pool() {
  local name="$1" ns="$2"
  if kubectl get secret "$name" -n "$ns" >/dev/null 2>&1; then echo "exists: $ns/$name"; return; fi
  kubectl-ate admin make-jwt-pool --key-id=1 --name="$name" --secret-namespace="$ns"
}
ca_pool  service-dns-ca-pool  podcertificate-controller-system
ca_pool  pod-identity-ca-pool podcertificate-controller-system
jwt_pool actor-id-jwt-pool    ate-system
ca_pool  actor-id-ca-pool     ate-system
ca_pool  egress-mitm-ca-pool  ate-system --key-type=ECDSAP256
```

**Verified on 2026-10-11:**

```text
Successfully created CA pool secret podcertificate-controller-system/service-dns-ca-pool
Successfully created CA pool secret podcertificate-controller-system/pod-identity-ca-pool
Successfully created JWT authority pool secret ate-system/actor-id-jwt-pool
Successfully created CA pool secret ate-system/actor-id-ca-pool
Successfully created CA pool secret ate-system/egress-mitm-ca-pool
```

ate-api verifies actor identity certificates against the actor identity root, which it reads as
plain PEM from its own Secret:

```bash run id=substrate-actor-id-ca-certs
kubectl get secret actor-id-ca-pool -n ate-system -o jsonpath='{.data.pool}' \
  | base64 --decode | jq -r '.CAs[0].RootCertificateDER' | base64 --decode \
  | openssl x509 -inform der -outform pem \
  | kubectl create secret generic actor-id-ca-certs -n ate-system --from-file=ca.crt=/dev/stdin
```

ate-api also authenticates operators, and kubectl-ate, by their Kubernetes ServiceAccount tokens.
It accepts a token only if the token's issuer matches its configuration exactly, so read the issuer
from your cluster rather than writing it down:

```bash run id=substrate-ate-api-authentication
ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
kubectl create configmap ate-api-authentication -n ate-system --from-literal=authentication.yaml="actorIdentityJWTProvider: kubernetes
jwtProviders:
- name: kubernetes
  issuer: ${ISSUER}
  audiences: [api.ate-system.svc]
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
"
echo "issuer: ${ISSUER}"
```

> [!WARNING]
> **A wrong issuer breaks nothing you will notice until you need it.** Agents keep working, because kagent authenticates to ate-api with its pod certificate, not a token. Only kubectl-ate fails, with `token issuer "…" not trusted`, and every inspect, suspend and resume in this guide uses it. kind 1.35 issues `https://kubernetes.default.svc.cluster.local`; examples that hardcode `https://kubernetes.default.svc` do not match it.

Wait for Substrate to come up, then prove kubectl-ate can talk to it:

```bash run id=step-4-substrate-ready
kubectl wait --for=condition=Available deployment --all -n ate-system --timeout=600s
kubectl wait --for=condition=Available deployment --all -n podcertificate-controller-system --timeout=300s
kubectl rollout status daemonset/atelet -n ate-system --timeout=300s
kubectl get pods -n ate-system
kubectl-ate get actors -A
```

**Verified on 2026-10-11:**

```text
deployment.apps/ate-api-server condition met
deployment.apps/ate-controller condition met
deployment.apps/atenet-egress condition met
deployment.apps/atenet-router condition met
deployment.apps/k8s-credential-provider condition met
deployment.apps/rustfs condition met
deployment.apps/podcertificate-controller condition met
daemon set "atelet" successfully rolled out
NAME                                       READY   STATUS      RESTARTS      AGE
ate-api-server-765bf85685-2ghnc            1/1     Running     2 (28s ago)   3m43s
ate-api-server-765bf85685-mt7qz            1/1     Running     2 (28s ago)   3m43s
ate-controller-646868d96b-6hwlx            1/1     Running     0             3m43s
atelet-cj7z7                               1/1     Running     0             3m32s
atenet-egress-7f9d4d9675-svcwc             2/2     Running     0             3m43s
atenet-router-7f49cf46bd-z5fmp             2/2     Running     0             3m43s
k8s-credential-provider-7575bd788b-xzqzt   1/1     Running     0             3m43s
postgres-0                                 2/2     Running     0             3m43s
rustfs-56cdbc9dcb-g8czq                    1/1     Running     0             3m43s
rustfs-bucket-init-98mph                   0/1     Completed   0             3m43s
ATESPACE   NAME   TEMPLATE   STATE   WORKER POD   WORKER IPS   VERSION   AGE
```

No actors yet, and no error. An error here, rather than an empty list, is the issuer warning above.

Both `ate-api-server` pods restart a couple of times while they wait for the authentication
ConfigMap you created last, then settle. Restarts here are not a fault; a pod still restarting
after the waits above have passed is.

The pools are valid for one year from now. Nothing rotates them, and when they expire nothing that
was issued from them validates. Before production covers rotation.

### Step 5: Install kagent

kagent is the control plane for agents: you declare agents as Kubernetes resources, and it turns
each conversation into a Substrate actor. The release also deploys the UI, a Postgres for its own
state, ClickHouse for traces, and a `WorkerPool`: the worker pods every sandbox runs in.

```bash run id=kagent-license
printf '%s' "$KAGENT_LICENSE_KEY" | kubectl create secret generic enterprise-kagent-license \
  -n kagent --from-file=enterprise-kagent-license-key=/dev/stdin
```

```bash run id=helm-kagent
helm upgrade -i kagent \
  oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise \
  --version ${KAGENT_VERSION} \
  --namespace kagent \
  --wait --timeout 15m \
  -f - <<EOF
global:
  cluster: ${KIND_CLUSTER_NAME}
enterprise:
  licensing:
    createSecret: false
  substrate:
    usePodCertificateAPI: true
kmcp:
  licensing:
    createSecret: false
controller:
  substrate:
    enabled: true
    ateApiEndpoint: "dns:///api.ate-system.svc:443"
    atenetRouterURL: "http://atenet-router.ate-system.svc:80"
substrateWorkerPool:
  create: true
  name: kagent-default
  replicas: 2
  sandboxClass: gvisor
  workerImage: ${WORKER_IMAGE}
EOF
```

> [!WARNING]
> **From here until Step 23, the UI hands out admin tokens to anyone who asks.** With no identity provider configured, kagent runs a bundled login whose token endpoint issues an admin token without a password. Keep every port-forward on 127.0.0.1 (the `forwards` helper does), do not expose the UI or controller Services, and do not leave this cluster reachable by anyone else. Step 23 replaces the bundled login with Keycloak and removes the endpoint.

`global.cluster` names this installation. The UI sends it on every request and the controller
rejects a name it does not recognise, so set it on any real install.

Two worker replicas, because every agent keeps a golden snapshot resident on a worker, and the pool
needs room for conversations beside it. SCALE sizes this properly.

Check the release:

```bash run id=step-5-kagent-ready
kubectl get pods -n kagent
kubectl get workerpool -n kagent
kubectl logs -n kagent deployment/kagent-controller -c controller | grep -o '"state":"[A-Za-z]*"' | sort | uniq -c
```

**Verified on 2026-10-11:**

```text
NAME                                                 READY   STATUS    RESTARTS      AGE
kagent-clickhouse-shard0-0                           1/1     Running   0             3m31s
kagent-controller-656fdf4b8c-ctxjh                   2/2     Running   2 (28s ago)   3m31s
kagent-default-ff8dfbd47-b7jxl                       1/1     Running   0             3m30s
kagent-default-ff8dfbd47-zf68s                       1/1     Running   0             3m30s
kagent-postgresql-54c6c8d89-9wjmw                    1/1     Running   0             3m31s
kagent-ui-74d4cd497b-2p5z8                           1/1     Running   0             3m31s
kmcp-enterprise-controller-manager-c6b5ff6c4-9r79m   1/1     Running   0             3m31s
NAME             DESIRED   REPLICAS   READY   AGE
kagent-default   2         2          2       3m31s
   1 "state":"Licensed"
   1 "state":"Warning"
```

> [!NOTE]
> **The controller may restart once or twice during the install.** It starts before its Postgres accepts connections, logs `run database migrations: … failed to connect to user=kagent database=kagent`, and recovers on its own. `--wait` covers it.
>
> **One `Licensed` and one `Warning` line is a correctly licensed controller.** The controller logs a license line per tracked product, and labels a trial tracker's state as the kagent license, so a valid license always shows one `kagent enterprise license missing or invalid` line beside the `valid` one. Read for `"state":"Licensed"`.

### Step 6: Put Solo Enterprise for agentgateway in front of the model

Every agent's model calls will go to this gateway rather than to the provider. The gateway holds the
real provider key, authenticates each caller by its own consumer key, and is the one place budgets
and cost attribution are applied in Isolate. The Deployment Guide for *Securing, Observing, and
Controlling LLM Consumption on Kubernetes* covers the gateway in depth; this step builds the minimum
the agents need.

Install the CRDs and the control plane, with the license from a Secret you create:

```bash run id=helm-enterprise-agentgateway-crds
helm upgrade -i enterprise-agentgateway-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway-crds \
  --create-namespace --namespace agentgateway-system \
  --version ${AGENT_GATEWAY_VERSION}
```

```bash run id=agentgateway-license
printf '%s' "$AGENTGATEWAY_LICENSE_KEY" | kubectl create secret generic enterprise-agentgateway-license \
  -n agentgateway-system --from-file=enterprise-agentgateway-license-key=/dev/stdin
```

```bash run id=helm-enterprise-agentgateway
helm upgrade -i enterprise-agentgateway \
  oci://us-docker.pkg.dev/solo-public/enterprise-agentgateway/charts/enterprise-agentgateway \
  --namespace agentgateway-system \
  --version ${AGENT_GATEWAY_VERSION} \
  --set licensing.createSecret=false
```

Create the Gateway:

```bash run id=gateway-agentgateway-proxy
kubectl apply -f- <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: agentgateway-proxy
  namespace: agentgateway-system
spec:
  gatewayClassName: enterprise-agentgateway
  listeners:
    - name: http
      protocol: HTTP
      port: 80
      allowedRoutes:
        namespaces:
          from: All
EOF
```

```bash run id=step-6-gateway-programmed
kubectl wait --for=condition=Programmed --timeout=180s gateway/agentgateway-proxy -n agentgateway-system
kubectl rollout status deployment/agentgateway-proxy -n agentgateway-system --timeout=180s
```

**Verified on 2026-10-11:**

```text
gateway.gateway.networking.k8s.io/agentgateway-proxy condition met
Waiting for deployment "agentgateway-proxy" rollout to finish: 0 out of 1 new replicas have been updated...
Waiting for deployment "agentgateway-proxy" rollout to finish: 0 of 1 updated replicas are available...
deployment "agentgateway-proxy" successfully rolled out
```

Store the provider key in the gateway's namespace. This is the only copy of it in the cluster:

```bash run id=secret-anthropic-api-key
printf '%s' "$ANTHROPIC_API_KEY" | kubectl create secret generic anthropic-api-key \
  -n agentgateway-system --from-file=Authorization=/dev/stdin
```

Connect the provider and expose it on a route. kagent's runtime calls Anthropic's native Messages
API at `/v1/messages`, so the backend maps that path to the Messages route type and the route
matches it:

```bash run id=backend-anthropic-messages
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: anthropic-messages-backend
  namespace: agentgateway-system
spec:
  ai:
    provider:
      anthropic:
        model: "${MODEL}"
  policies:
    auth:
      secretRef:
        name: anthropic-api-key
    ai:
      routes:
        "/v1/messages": Messages
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: anthropic-messages
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /v1/messages
      backendRefs:
        - group: enterpriseagentgateway.solo.io
          kind: EnterpriseAgentgatewayBackend
          name: anthropic-messages-backend
          namespace: agentgateway-system
EOF
```

Issue the agents a consumer key. It identifies the caller to the gateway, not to Anthropic, and its
`group` is what budgets and attribution hang on in Isolate. The key is generated in your shell and
stored in a Secret created with `kubectl create`, not `apply`: `apply` would copy the whole Secret,
key included, into a `last-applied-configuration` annotation that anyone allowed to read the
object's metadata can see.

```bash run id=secret-llm-virtual-keys
export AGENT_CONSUMER_KEY="agw_team_agents_$(openssl rand -hex 32)"
kubectl create -f- <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: llm-virtual-keys
  namespace: agentgateway-system
type: Opaque
stringData:
  team-agents: |
    {
      "key": "${AGENT_CONSUMER_KEY}",
      "metadata": {
        "id": "team-agents-key",
        "user": "assistant-agent",
        "group": "team-agents"
      }
    }
EOF
```

Require that key on the route, on its own header:

```bash run id=policy-anthropic-messages-apikey-auth
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: anthropic-messages-apikey-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: anthropic-messages
  traffic:
    apiKeyAuthentication:
      mode: Strict
      location:
        header:
          name: x-api-key
      secretRef:
        name: llm-virtual-keys
EOF
```

`x-api-key` is the header Anthropic's SDKs send their key in, so the agent runtime sends the
consumer key there without being told anything about the gateway.

Prove the route refuses a caller with no key and serves one with the consumer key, before any agent
is involved. The port-forward goes straight to the proxy pod and is closed again at the end:

```bash run id=step-6-gateway-check
kubectl port-forward --address 127.0.0.1 -n agentgateway-system deployment/agentgateway-proxy 18081:80 >/dev/null 2>&1 &
GW_PF=$!
sleep 3
MSG="{\"model\":\"${MODEL}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: gateway ok\"}]}"
echo -n "no key:       "; curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18081/v1/messages \
  -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' -d "$MSG"
echo -n "consumer key: "; curl -sS http://127.0.0.1:18081/v1/messages \
  -H 'content-type: application/json' -H 'anthropic-version: 2023-06-01' \
  -H "x-api-key: ${AGENT_CONSUMER_KEY}" -d "$MSG" | jq -r '.content[0].text'
kill $GW_PF
```

**Verified on 2026-10-11:**

```text
no key:       401
consumer key: gateway ok
```

A 401 with no key and an answer with the consumer key means the gateway is authenticating callers
and holding the provider key itself.

### Step 7: Fence the gateway

The gateway accepts any caller that presents a valid consumer key, from anywhere in the cluster. The
only callers it should have are agents, and every call an agent makes leaves through Substrate's
egress gateway, `atenet-egress`. The one other caller is the kagent controller, which discovers an
MCP server's tools by calling it itself, so an MCP server behind this gateway (Step 20) needs it
admitted.

```bash run id=networkpolicy-agentgateway-proxy
kubectl apply -f- <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: agentgateway-proxy-from-substrate-egress
  namespace: agentgateway-system
spec:
  podSelector:
    matchLabels:
      gateway.networking.k8s.io/gateway-name: agentgateway-proxy
  policyTypes: [Ingress]
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ate-system
          podSelector:
            matchLabels:
              app: atenet-egress
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kagent
          podSelector:
            matchLabels:
              app.kubernetes.io/component: controller
              app.kubernetes.io/name: kagent-enterprise
      ports:
        - protocol: TCP
          port: 80
        - protocol: TCP
          port: 443
EOF
```

Only the listener ports are admitted; the proxy's admin and metrics ports are reachable from no pod.

Prove another pod cannot reach it. Read the error text rather than the exit status: `wget` exits 1
both when the connection is dropped and when the gateway answers 401, and only the first proves the
policy:

```bash run id=step-7-fence-check
kubectl run fence-check -n default --rm -i --restart=Never --image=busybox:1.36 --quiet -- \
  sh -c 'wget -T 8 -O /dev/null http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/messages 2>&1 | tail -1' \
  < /dev/null
```

**Verified on 2026-10-11:**

```text
wget: download timed out
```

`< /dev/null` keeps `kubectl run -i` from reading your terminal: without it, anything pasted after
this block is fed to the pod instead of your shell, and silently never runs.

`download timed out` is the policy dropping the connection. `401 Unauthorized` would mean the pod
reached the gateway and only the key check stopped it.

> [!NOTE]
> **The policy admits by label, not identity.** Any pod someone can create in `kagent` with the controller's two labels passes it, and still needs a valid consumer key. Restrict who can create pods in `kagent`.

### Step 8: Declare the first agent

An agent is four resources. A `ModelConfig` says which model and with which credential. An
`AgentTemplate` says what the agent is: its instructions and tools. A `Harness` says what runs it:
the runtime image and the worker pool. The `Agent` pairs a template with a harness.

The agent's credential is the consumer key, not the Anthropic key. kagent never gives it to the
agent: it gives the agent the placeholder `kagent-credential-injected`, and tells Substrate's egress
gateway to replace the `x-api-key` header with the real value on the way to the address in
`baseUrl`.

```bash run id=secret-kagent-gateway-consumer-key
: "${AGENT_CONSUMER_KEY:?is empty: Step 6 exported it in another shell. Read it back first (below).}"
printf '%s' "$AGENT_CONSUMER_KEY" | kubectl create secret generic kagent-gateway-consumer-key \
  -n kagent --from-file=api-key=/dev/stdin
```

> [!WARNING]
> **An empty consumer key fails nothing until the first turn.** `AGENT_CONSUMER_KEY` exists only in the shell that ran Step 6. In a new shell it is empty, and without the guard above an empty Secret is created without complaint, the agent still goes `Ready`, and the first turn fails with `503 Service Unavailable credential provider returned an unusable secret`. If the guard stops you, read the key back from the gateway's Secret and run the block again:

```bash run id=step-8-read-back-consumer-key when=manual
export AGENT_CONSUMER_KEY=$(kubectl get secret llm-virtual-keys -n agentgateway-system \
  -o jsonpath='{.data.team-agents}' | base64 --decode | jq -r .key)
```

```bash run id=agent-assistant
kubectl apply -f- <<EOF
apiVersion: api.kagent.dev/v1alpha3
kind: ModelConfig
metadata:
  name: anthropic-via-gateway
  namespace: kagent
spec:
  provider: Anthropic
  model: ${MODEL}
  apiKeySecret: kagent-gateway-consumer-key
  apiKeySecretKey: api-key
  anthropic:
    baseUrl: http://agentgateway-proxy.agentgateway-system.svc.cluster.local
---
apiVersion: api.kagent.dev/v1alpha3
kind: AgentTemplate
metadata:
  name: assistant
  namespace: kagent
spec:
  description: A general assistant with no tools.
  modelConfig:
    name: anthropic-via-gateway
  systemPrompt: |
    You are a helpful assistant. Answer concisely.
---
apiVersion: api.kagent.dev/v1alpha3
kind: Harness
metadata:
  name: kagent-adk
  namespace: kagent
spec:
  kagent: {}
  workload:
    image: ${RUNTIME_IMAGE}
  substrate:
    workerPoolRef:
      name: kagent-default
    snapshotPolicy:
      location: gs://ate-snapshots/kagent/
---
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata:
  name: assistant
  namespace: kagent
spec:
  templateRef:
    name: assistant
  harnessRef:
    name: kagent-adk
EOF
```

`snapshotPolicy.location` is required. Only its bucket and prefix are used: with the chart's
bundled store, snapshots go to bucket `ate-snapshots` under `kagent/` in RustFS whatever the scheme
says. A bucket that does not exist does not produce a storage error on the Agent; it produces
`GoldenActorCrashed: golden actor crashed before its snapshot was taken`, and only atelet's log
names the bucket.

`baseUrl` is `http://`. The hop from Substrate's egress gateway to the enterprise gateway cannot be
HTTPS to a private certificate on this release: Substrate's egress gateway trusts only public CAs,
and the turn fails with `503 … invalid peer certificate: UnknownIssuer`.

Wait for the agent:

```bash run id=step-8-agent-ready
kubectl wait agent/assistant -n kagent --for=condition=Ready --timeout=300s
kubectl get agent assistant -n kagent -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.message}{"\n"}{end}'
```

**Verified on 2026-10-11:**

```text
agent.api.kagent.dev/assistant condition met
Accepted=True Agent explicitly selects its template and harness
ResolvedRefs=True All runtime references resolved
Compatible=True Resolved configuration is compatible with the Harness
Ready=True ActorTemplate golden snapshot is ready
```

`Ready` means Substrate started the agent once, let it initialize, and saved that state as a
golden snapshot. Every conversation from now on starts from a copy of it instead of booting.

### Step 9: Verify the first turn through the enterprise gateway

Bring the forwards up:

```bash run id=step-9-forwards
forwards
```

Two helpers. `kagent_token` gets a token from the bundled login, which is exactly the open endpoint
Step 5 warned about; Step 23 replaces it. `kagent_send` sends one message to an agent over A2A and
prints the reply and the conversation's ID:

```bash run id=step-9-helpers
kagent_token() {
  curl -sS --max-time 10 -X POST "http://127.0.0.1:${KAGENT_UI_PORT}/autoauth/token" \
    -H 'Content-Type: application/json' -d '{"user_type":"admin"}' | jq -r .access_token
}

# kagent_send <agent> <message> [contextId]
kagent_send() {
  local ctx=""
  [ -n "${3:-}" ] && ctx="\"contextId\":\"$3\","
  curl -sS --max-time 300 -X POST "http://127.0.0.1:${KAGENT_API_PORT}/agents/kagent/$1" \
    -H "Authorization: Bearer $(kagent_token)" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"SendMessage\",\"params\":{\"message\":{\"messageId\":\"$(openssl rand -hex 8)\",${ctx}\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"$2\"}]}}}" \
    | jq -r '.result.task | "\(.status.state)\t\(.contextId)\t\(.artifacts[-1].parts[0].text // .status.message.parts[0].text // "")"'
}
```

It prints the reply, or for a failed turn the error the agent got, so a failure is never a blank
line. `--max-time 300` because a turn includes a model call. A dead port-forward otherwise leaves `curl`
waiting rather than failing.

Send the first message:

```bash run id=step-9-first-turn
TURN=$(kagent_send assistant "Reply with exactly: up and running")
echo "$TURN"
export FIRST_CONTEXT=$(echo "$TURN" | cut -f2)
```

**Verified on 2026-10-11:**

```text
TASK_STATE_COMPLETED	01a12d00-c737-72d8-95e5-bf441ebd855b	up and running
```

`TASK_STATE_COMPLETED`, the conversation's ID, and the reply. An answer alone does not prove the
call went through the enterprise gateway, so check both ends.

The conversation's actor is named after its ID. Its egress policy is what kagent told Substrate's
egress gateway to allow:

```bash run id=step-9-egress-policy
kubectl-ate get egress-policy "session-${FIRST_CONTEXT}" --atespace kagent -o json \
  | jq -r '.rules[] | to_entries[0] | "\(.key)\t\(.value.hostnames[0]):\(.value.ports.numbers[0])\t\([.value.effects.replaceHeaders[]? | "\(.header) <- \(.credentialUri)"] | join(", "))"'
```

**Verified on 2026-10-11:**

```text
http	agentgateway-proxy.agentgateway-system.svc.cluster.local:80	x-api-key <- ate-secret://k8s.io/default/kagent/kagent-gateway-consumer-key/api-key
http	kagent-controller.kagent:8083	
https	api.anthropic.com:443
```

The gateway rule replaces `x-api-key` with the consumer key Secret. The `api.anthropic.com` rule is
added by kagent for the provider whatever `baseUrl` says, with no credential on it, so an actor can
reach Anthropic but has nothing to authenticate with.

And the enterprise gateway's own record of the call:

```bash run id=step-9-gateway-log
EGRESS_IP=$(kubectl get pod -n ate-system -l app=atenet-egress -o jsonpath='{.items[0].status.podIP}')
echo "atenet-egress: ${EGRESS_IP}"
kubectl logs -n agentgateway-system deployment/agentgateway-proxy --since=10m \
  | grep 'route=agentgateway-system/anthropic-messages' | grep "src.addr=${EGRESS_IP}:" | tail -1 \
  | tr ' ' '\n' | grep -E '^(route|src.addr|http.status|gen_ai.usage.input_tokens|gen_ai.usage.output_tokens|endpoint)='
```

**Verified on 2026-10-11:**

```text
atenet-egress: 10.244.0.12
route=agentgateway-system/anthropic-messages
endpoint=api.anthropic.com:443
src.addr=10.244.0.12:54122
http.status=200
gen_ai.usage.input_tokens=702
gen_ai.usage.output_tokens=6
```

The call arrived from `atenet-egress`'s address, on the `anthropic-messages` route, and went on to
Anthropic. The log does not name the key, but that route refuses any request without a valid
consumer key (Step 6), so a 200 there means the consumer key was presented and accepted. The
token counts are the gateway's own, which is what budgets and attribution in Isolate are built on.

**What you now have:** an agent that never holds a model key, conversations that each run in their
own sandbox and stop costing memory when a turn ends, and a gateway that every model call passes
through and nothing else in the cluster can reach. What you do not have yet is anything protecting
the UI and API, or the snapshot store, from the rest of the cluster. Isolate closes both.
