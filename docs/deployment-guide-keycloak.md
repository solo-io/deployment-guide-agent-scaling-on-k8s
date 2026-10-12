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
# The Claude Code runtime, used in Step 15. Same kagent release as RUNTIME_IMAGE.
export CLAUDE_HARNESS_IMAGE=ghcr.io/kagent-dev/kagent/claude-harness@sha256:e72d66d9f3b6eafbc59d18cef150fb5d31cb89ead83999a33c06264c21e86d4c

# The S3 client Step 13 uses to read the snapshot store.
export AWS_CLI_IMAGE=amazon/aws-cli:2.17.0@sha256:643507c10ada7964ca6157b3d799f030b90577643da9955d319a77399ed80d73

# The reference MCP server's runtime, Step 20.
export MCP_SERVER_IMAGE=python:3.12-alpine@sha256:1b668429b3511ab407d8e00648891631b0b1a4d7e15e3ca70f38ab5b91ad4ab4

# The reference identity provider, Step 23. The port is part of the OIDC issuer URL, so it is the
# same on your machine and inside the cluster.
export KEYCLOAK_VERSION=26.2.5
export KEYCLOAK_PORT=${KEYCLOAK_PORT:-18080}

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
| 18080 | Keycloak, port-forwarded from Step 23. `KEYCLOAK_PORT` moves it, and it is part of the issuer URL. |
| 18081 | agentgateway proxy, port-forwarded briefly in Step 6's check |
| 18082 | agentgateway proxy metrics (15020 on the pod), port-forwarded briefly in Step 21 |

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

**Verified on:** certification run on kind cluster `agents` (kind 0.32.0, `kindest/node:v1.35.0`), created fresh for it, 2026-10-12 04:27 to 04:36 UTC. Every `run` block from Step 1 to Step 31 was executed verbatim, in document order, in one uninterrupted pass of `auto-build/run.sh`, on the versions in Version support; every output block in this guide comes from that pass.

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

**Verified on 2026-10-12:**

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

**Verified on 2026-10-12:**

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

**Verified on 2026-10-12:**

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

**Verified on 2026-10-12:**

```text
deployment.apps/ate-api-server condition met
deployment.apps/ate-controller condition met
deployment.apps/atenet-egress condition met
deployment.apps/atenet-router condition met
deployment.apps/k8s-credential-provider condition met
deployment.apps/rustfs condition met
deployment.apps/podcertificate-controller condition met
daemon set "atelet" successfully rolled out
NAME                                       READY   STATUS      RESTARTS   AGE
ate-api-server-765bf85685-d2dt8            1/1     Running     0          65s
ate-api-server-765bf85685-pjdsp            1/1     Running     0          65s
ate-controller-646868d96b-wnfmt            1/1     Running     0          65s
atelet-br9qw                               1/1     Running     0          55s
atenet-egress-7f9d4d9675-gd4z5             2/2     Running     0          65s
atenet-router-7f49cf46bd-vk2dd             2/2     Running     0          65s
k8s-credential-provider-7575bd788b-9mldw   1/1     Running     0          65s
postgres-0                                 2/2     Running     0          66s
rustfs-56cdbc9dcb-jlqn6                    1/1     Running     0          65s
rustfs-bucket-init-qlv45                   0/1     Completed   0          66s
ATESPACE   NAME   TEMPLATE   STATE   WORKER POD   WORKER IPS   VERSION   AGE
```

No actors yet, and no error. An error here, rather than an empty list, is the issuer warning above.

The `ate-api-server` pods may restart a few times while they wait for the authentication ConfigMap
you created last, then settle (in this guide's runs they restarted twice or not at all). Restarts here
are not a fault; a pod still restarting after the waits above have passed is.

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

**Verified on 2026-10-12:**

```text
NAME                                                 READY   STATUS    RESTARTS      AGE
kagent-clickhouse-shard0-0                           1/1     Running   0             76s
kagent-controller-656fdf4b8c-2mkd7                   2/2     Running   2 (36s ago)   76s
kagent-default-ff8dfbd47-dm22t                       1/1     Running   0             76s
kagent-default-ff8dfbd47-sr45m                       1/1     Running   0             76s
kagent-postgresql-54c6c8d89-2kwxk                    1/1     Running   0             76s
kagent-ui-74d4cd497b-ggw28                           1/1     Running   0             76s
kmcp-enterprise-controller-manager-c6b5ff6c4-ps6l2   1/1     Running   0             76s
NAME             DESIRED   REPLICAS   READY   AGE
kagent-default   2         2          2       76s
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

**Verified on 2026-10-12:**

```text
gateway.gateway.networking.k8s.io/agentgateway-proxy condition met
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

**Verified on 2026-10-12:**

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

**Verified on 2026-10-12:**

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

**Verified on 2026-10-12:**

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
    | jq -r '.result.task | "\(.status.state)\t\(.contextId)\t\((.artifacts[-1].parts[0].text // .status.message.parts[0].text // "") | gsub("\\s*\n\\s*"; " "))"'
}
```

It prints the reply, or for a failed turn the error the agent got, so a failure is never a blank
line, and always on one line, so `cut -f2` gets the conversation ID even when the model answers in
paragraphs. `--max-time 300` because a turn includes a model call. A dead port-forward otherwise leaves `curl`
waiting rather than failing.

Send the first message:

```bash run id=step-9-first-turn
TURN=$(kagent_send assistant "Reply with exactly: up and running")
echo "$TURN"
export FIRST_CONTEXT=$(echo "$TURN" | cut -f2)
```

**Verified on 2026-10-12:**

```text
TASK_STATE_COMPLETED	01a12e60-9a03-70f0-bd18-ea0d1054702b	up and running
```

`TASK_STATE_COMPLETED`, the conversation's ID, and the reply. An answer alone does not prove the
call went through the enterprise gateway, so check both ends.

The conversation's actor is named after its ID. Its egress policy is what kagent told Substrate's
egress gateway to allow:

```bash run id=step-9-egress-policy
kubectl-ate get egress-policy "session-${FIRST_CONTEXT}" --atespace kagent -o json \
  | jq -r '.rules[] | to_entries[0] | "\(.key)\t\(.value.hostnames[0]):\(.value.ports.numbers[0])\t\([.value.effects.replaceHeaders[]? | "\(.header) <- \(.credentialUri)"] | join(", "))"'
```

**Verified on 2026-10-12:**

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

**Verified on 2026-10-12:**

```text
atenet-egress: 10.244.0.15
route=agentgateway-system/anthropic-messages
endpoint=api.anthropic.com:443
src.addr=10.244.0.15:60142
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

## OPERATE

Up and Running proved one turn works. This section follows a conversation through its whole life,
so that when something misbehaves you know which part to look at.

**What you are going to do:** see what kagent created in Substrate for the agent, follow one
conversation through two turns and a suspension, inspect and act on its actor directly, find where
its context is stored, delete it and check what is left, and run the same agent on a second
runtime.

**What you will have that you did not have before:** a working model of the agent lifecycle on this
platform, and the commands to see each stage of it on your own cluster.

**Verified on:** certification run on kind cluster `agents` (kind 0.32.0, `kindest/node:v1.35.0`), created fresh for it, 2026-10-12 04:27 to 04:36 UTC. Every `run` block from Step 1 to Step 31 was executed verbatim, in document order, in one uninterrupted pass of `auto-build/run.sh`, on the versions in Version support; every output block in this guide comes from that pass.

### Step 10: How an agent becomes actors

Applying the `Agent` in Step 8 did not start a pod. kagent asked Substrate for an **actor template**:
the image, the sandbox class and the egress policy every conversation with this agent will get.
Substrate started one actor from it, let it initialize, and saved its memory as a **golden
snapshot**. That snapshot is what `Ready` meant.

```bash run id=step-10-template
kubectl-ate get actor-template -a kagent
kubectl-ate get tags -a ate-golden
```

**Verified on 2026-10-12:**

```text
ATESPACE   NAME                     SANDBOX CLASS          GOLDEN TAG                             ERROR   AGE
kagent     assistant-b24ff6be83c3   SANDBOX_CLASS_GVISOR   68f45bb6-0e17-43c9-8190-345f61bb97eb           8s
ATESPACE     NAME                                   SCOPE                 STATE   SNAPSHOT                                                                                   CONTENT SCOPE                 AGE
ate-golden   68f45bb6-0e17-43c9-8190-345f61bb97eb   TAG_SCOPE_PUBLISHED   Ready   gs://ate-snapshots/kagent/atespaces/ate-golden/tags/f9979e5b-ec83-48f3-96a5-66a178f835e4   SNAPSHOT_CONTENT_SCOPE_FULL   3s
```

The template's `GOLDEN TAG` is the tag in the `ate-golden` atespace, and the tag's snapshot is a
full memory image in the snapshot store. Every agent you declare gets one of each.

Then each conversation becomes its own **actor**, named `session-<conversation id>`, in the `kagent`
atespace:

```bash run id=step-10-actors
kubectl-ate get actors -a kagent
kubectl-ate get workers
```

**Verified on 2026-10-12:**

```text
ATESPACE   NAME                                           TEMPLATE                        STATE                 WORKER POD                              WORKER IPS    VERSION   AGE
kagent     session-01a12e60-9a03-70f0-bd18-ea0d1054702b   kagent/assistant-b24ff6be83c3   ACTOR_STATE_RUNNING   kagent/kagent-default-ff8dfbd47-sr45m   10.244.0.24   3         1s
NAME                                   POOL             STATE                 ACTORS   CPU   MEMORY         POD                                     AGE
0deec7ce-237c-419d-a18a-47f98dd9c207   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-ff8dfbd47-dm22t   92s
e9e21500-511a-46af-9bfd-0a3ce46fc9f7   kagent-default   WORKER_STATE_ACTIVE   1/1000   0/6   0/12220312Ki   kagent/kagent-default-ff8dfbd47-sr45m   91s
```

Step 9's conversation is `SUSPENDED`, with no worker pod and no IP. It holds nothing on a worker
until its next message. The workers report the actors placed on them right now, which is none.

There is no long-lived actor per agent. Ten conversations with one agent are ten actors, each
restored from the same golden snapshot, which is why Scale counts conversations rather than agents.

### Step 11: Follow one conversation

Two helpers. `actor_events` reads atelet's log, where Substrate records every restore and
checkpoint with its timing. `wait_suspended` polls the actor until it is suspended:

```bash run id=step-11-helpers
# actor_events <conversation id>: restores and checkpoints for that conversation's actor.
actor_events() {
  kubectl logs -n ate-system daemonset/atelet --since=30m \
    | jq -r --arg a "session-$1" 'select(."ate.actor.name" == $a and (.msg | test("timing breakdown")))
        | [.time[11:23], .msg, ."ate.snapshot.kind" + "/" + ."ate.snapshot.scope",
           (((."ate.actor.restore.duration.total" // ."ate.actor.checkpoint.duration.total") * 1000 | floor | tostring) + " ms")]
        | @tsv'
}

# wait_suspended <conversation id>: block until the actor is suspended, at most 60s.
wait_suspended() {
  local waited=0 state
  while [ "$waited" -lt 60 ]; do
    state=$(kubectl-ate get actor "session-$1" -a kagent -o json | jq -r .status.state)
    [ "$state" = ACTOR_STATE_SUSPENDED ] && { echo "suspended (polled ${waited}s after the reply)"; return 0; }
    sleep 1; waited=$((waited + 1))
  done
  echo "still ${state} after 60s" >&2; return 1
}
```

`daemonset/atelet` reads one atelet pod. On a single-node cluster that is the only one; on more
nodes, read the pod on the node the actor ran on.

Send the first turn of a new conversation, then watch its actor:

```bash run id=step-11-turn-1
TURN=$(kagent_send assistant "My project is called Larkspur. Reply with OK.")
echo "$TURN"
export CONV=$(echo "$TURN" | cut -f2)
wait_suspended "$CONV"
kubectl-ate get actor "session-${CONV}" -a kagent
```

**Verified on 2026-10-12:**

```text
TASK_STATE_COMPLETED	01a12e60-9eb8-7de1-949e-ab146122b86d	OK.
suspended (polled 1s after the reply)
ATESPACE   NAME                                           TEMPLATE                        STATE                   WORKER POD   WORKER IPS   VERSION   AGE
kagent     session-01a12e60-9eb8-7de1-949e-ab146122b86d   kagent/assistant-b24ff6be83c3   ACTOR_STATE_SUSPENDED   <none>                    5         1s
```

The actor was suspended as soon as the turn ended. **There is no idle timeout to configure.** kagent
checks every second for conversations whose last turn has finished and suspends them, so idle lasts
about a second. A turn that ends waiting for input (approval, authentication) pauses the actor on
its worker instead of suspending it.

Send the second turn in the same conversation:

```bash run id=step-11-turn-2
kagent_send assistant "What is my project called?" "$CONV"
wait_suspended "$CONV"
actor_events "$CONV"
```

**Verified on 2026-10-12:**

```text
TASK_STATE_COMPLETED	01a12e60-9eb8-7de1-949e-ab146122b86d	Your project is called Larkspur.
suspended (polled 1s after the reply)
04:30:46.609	Restore timing breakdown	golden/full	86 ms
04:30:47.954	Checkpoint timing breakdown	latest/data	43 ms
04:30:48.518	Restore timing breakdown	latest/data	93 ms
04:30:49.944	Checkpoint timing breakdown	latest/data	35 ms
```

The agent remembered, and atelet's log shows how:

| Event | Snapshot | What it means |
|---|---|---|
| First restore | `golden/full` | The new actor started from the agent's golden memory image |
| Checkpoint | `latest/data` | At the end of the turn, only the conversation's data directory was saved |
| Second restore | `latest/data` | Memory again from the golden image, the conversation's data on top |
| Checkpoint | `latest/data` | Saved again, replacing the previous one |

A suspended conversation can resume on a different worker from the one it last ran on, because
everything it needs is in the snapshot store.

### Step 12: Inspect and act on an actor

kagent drives actors for you. kubectl-ate lets you look at one and act on it directly, which is
what you need when a conversation is stuck:

```bash run id=step-12-inspect
kubectl-ate get actor "session-${CONV}" -a kagent -o json \
  | jq '{name: .metadata.name, uid: .metadata.uid, version: .metadata.version, state: .status.state, snapshot: .status.externalSnapshot}'
```

**Verified on 2026-10-12:**

```text
{
  "name": "session-01a12e60-9eb8-7de1-949e-ab146122b86d",
  "uid": "2538ed83-c609-4163-9ac3-eb7d6e7ee47f",
  "version": "9",
  "state": "ACTOR_STATE_SUSPENDED",
  "snapshot": {
    "actorTemplateUid": "68f45bb6-0e17-43c9-8190-345f61bb97eb",
    "contentScope": "SNAPSHOT_CONTENT_SCOPE_DATA",
    "snapshotUri": "gs://ate-snapshots/kagent/atespaces/kagent/actors/2538ed83-c609-4163-9ac3-eb7d6e7ee47f/snapshots/fc4360d6-63b5-449d-9a70-4a303875879e"
  }
}
```

`version` counts state changes: every turn moves it through resuming, running, suspending and
suspended. `snapshot` is where its latest checkpoint is.

Resume it by hand, see it placed on a worker, then suspend it again:

```bash run id=step-12-resume-suspend
kubectl-ate resume actor "session-${CONV}" -a kagent
kubectl-ate get workers
kubectl-ate suspend actor "session-${CONV}" -a kagent
```

**Verified on 2026-10-12:**

```text
ATESPACE   NAME                                           TEMPLATE                        STATE                 WORKER POD                              WORKER IPS    VERSION   AGE
kagent     session-01a12e60-9eb8-7de1-949e-ab146122b86d   kagent/assistant-b24ff6be83c3   ACTOR_STATE_RUNNING   kagent/kagent-default-ff8dfbd47-dm22t   10.244.0.23   11        3s
NAME                                   POOL             STATE                 ACTORS   CPU   MEMORY         POD                                     AGE
0deec7ce-237c-419d-a18a-47f98dd9c207   kagent-default   WORKER_STATE_ACTIVE   1/1000   0/6   0/12220312Ki   kagent/kagent-default-ff8dfbd47-dm22t   96s
e9e21500-511a-46af-9bfd-0a3ce46fc9f7   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-ff8dfbd47-sr45m   95s
ATESPACE   NAME                                           TEMPLATE                        STATE                   WORKER POD   WORKER IPS   VERSION   AGE
kagent     session-01a12e60-9eb8-7de1-949e-ab146122b86d   kagent/assistant-b24ff6be83c3   ACTOR_STATE_SUSPENDED   <none>                    13        3s
```

> [!WARNING]
> **A hand-resumed actor stays running until a turn ends or you suspend it.** kagent suspends an actor when a turn finishes, and a resume with no turn never finishes one, so the actor holds its place on a worker indefinitely. Suspend what you resume.

### Step 13: Where a conversation's context is kept

The conversation survived suspension because atelet wrote it to the snapshot store. With the
bundled store, that is the RustFS bucket `ate-snapshots`, under the prefix the Harness's
`snapshotPolicy.location` named (`kagent/`).

This helper lists a prefix in that bucket from a short-lived pod in `ate-system`. It reads the
store's credentials from the atelet DaemonSet, which is where the chart puts them:

```bash run id=step-13-helpers
# snapshot_ls <prefix>: list objects under s3://ate-snapshots/<prefix>.
# Uses the store's credentials from the atelet DaemonSet, unless S3_ACCESS_KEY and S3_SECRET_KEY are set.
snapshot_ls() {
  local ak sk
  ak=${S3_ACCESS_KEY:-$(kubectl get daemonset atelet -n ate-system -o json | jq -r '[.spec.template.spec.containers[].env[]? | select(.name=="AWS_ACCESS_KEY_ID")][0].value')}
  sk=${S3_SECRET_KEY:-$(kubectl get daemonset atelet -n ate-system -o json | jq -r '[.spec.template.spec.containers[].env[]? | select(.name=="AWS_SECRET_ACCESS_KEY")][0].value')}
  kubectl delete pod snapshot-ls -n ate-system --ignore-not-found >/dev/null
  kubectl create -f- >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: snapshot-ls
  namespace: ate-system
  labels: {app: snapshot-ls}
spec:
  restartPolicy: Never
  containers:
    - name: aws
      image: ${AWS_CLI_IMAGE}
      args: ["s3", "ls", "--recursive", "s3://ate-snapshots/$1", "--endpoint-url", "http://rustfs.ate-system.svc:9000",
             "--cli-connect-timeout", "10", "--cli-read-timeout", "10"]
      env:
        - {name: AWS_ACCESS_KEY_ID, value: "${ak}"}
        - {name: AWS_SECRET_ACCESS_KEY, value: "${sk}"}
        - {name: AWS_DEFAULT_REGION, value: us-east-1}
EOF
  local phase="" waited=0 out
  while [ "$waited" -lt 120 ]; do
    phase=$(kubectl get pod snapshot-ls -n ate-system -o jsonpath='{.status.phase}')
    case "$phase" in Succeeded|Failed) break ;; esac
    sleep 1; waited=$((waited + 1))
  done
  out=$(kubectl logs pod/snapshot-ls -n ate-system)
  if [ -n "$out" ]; then echo "$out"; else echo "(no objects)"; fi
  kubectl delete pod snapshot-ls -n ate-system --wait=false >/dev/null
}
```

`aws s3 ls` exits 1 when a prefix holds nothing, so the pod ends `Failed` for an empty prefix. The
helper waits for the pod to finish either way and prints `(no objects)` rather than reading the
phase as an answer.

List this conversation's snapshot, and the agent's golden image:

```bash run id=step-13-snapshot-objects
export CONV_ACTOR_UID=$(kubectl-ate get actor "session-${CONV}" -a kagent -o json | jq -r .metadata.uid)
echo "-- conversation ${CONV} (actor ${CONV_ACTOR_UID})"
snapshot_ls "kagent/atespaces/kagent/actors/${CONV_ACTOR_UID}/"
echo "-- golden images"
snapshot_ls "kagent/atespaces/ate-golden/tags/"
```

**Verified on 2026-10-12:**

```text
-- conversation 01a12e60-9eb8-7de1-949e-ab146122b86d (actor 2538ed83-c609-4163-9ac3-eb7d6e7ee47f)
2026-10-12 04:30:50       1601 kagent/atespaces/kagent/actors/2538ed83-c609-4163-9ac3-eb7d6e7ee47f/snapshots/6c711ca6-3e79-4ba3-9703-b9b18f736931/durable-dir.tar.zstd
2026-10-12 04:30:50        609 kagent/atespaces/kagent/actors/2538ed83-c609-4163-9ac3-eb7d6e7ee47f/snapshots/6c711ca6-3e79-4ba3-9703-b9b18f736931/manifest.json
-- golden images
2026-10-12 04:30:42      78881 kagent/atespaces/ate-golden/tags/f9979e5b-ec83-48f3-96a5-66a178f835e4/checkpoint.img.zstd
2026-10-12 04:30:42        896 kagent/atespaces/ate-golden/tags/f9979e5b-ec83-48f3-96a5-66a178f835e4/durable-dir.tar.zstd
2026-10-12 04:30:42        651 kagent/atespaces/ate-golden/tags/f9979e5b-ec83-48f3-96a5-66a178f835e4/manifest.json
2026-10-12 04:30:42    1025271 kagent/atespaces/ate-golden/tags/f9979e5b-ec83-48f3-96a5-66a178f835e4/pages.img.zstd
2026-10-12 04:30:42       1981 kagent/atespaces/ate-golden/tags/f9979e5b-ec83-48f3-96a5-66a178f835e4/pages_meta.img.zstd
```

Each conversation keeps one snapshot: its data directory, a few kilobytes, which each checkpoint
replaces. Inside it is the runtime's session database, and that **is the conversation, in readable
text**: compressed with zstd, not encrypted. The golden image is the agent's memory, shared by every
conversation with that agent. kagent's own Postgres holds a second copy of each conversation's
events.

> [!WARNING]
> **Anyone who can read the atelet DaemonSet has the store's credentials, and with the chart's defaults anyone who can reach the store can read every conversation.** The helper above works for exactly that reason. Step 22 replaces the credentials and fences the store so that only atelet and ate-api can reach it. Until then, treat every conversation on this cluster as readable by anything in it.

### Step 14: Delete a conversation, and what stays behind

**In the UI.** Open the agent, open the conversation's menu in the chat list (the three dots beside
it), choose **Delete chat**, and confirm with **Delete**. The UI asks kagent to delete the session,
and kagent deletes its actor. Verified on this release with Keycloak sign-in (Step 23), as a writer
deleting their own conversation.

**From a script.** kagent offers no supported CLI or API for this: the session API is gRPC and
gRPC-Web only, with no JSON form and no server reflection, and the open-source `kagent` CLI sends no
token, so it cannot authenticate to this controller. Deleting a session is one string field, so
this helper frames the gRPC-Web request by hand, the same request the UI sends: five bytes of frame
header, then the field (tag `0x0a`, length 36, the conversation ID):

```bash run id=step-14-helpers
# kagent_delete_session <conversation id>: SessionService/DeleteSession; prints grpc-status.
kagent_delete_session() {
  printf '\000\000\000\000\046\012\044%s' "$1" \
    | curl -sS --max-time 30 -X POST "http://127.0.0.1:${KAGENT_API_PORT}/kagent.api.v1alpha1.SessionService/DeleteSession" \
        -H "Authorization: Bearer $(kagent_token)" \
        -H 'Content-Type: application/grpc-web+proto' -H 'X-Grpc-Web: 1' --data-binary @- \
    | LC_ALL=C tr -c '[:print:]' '\n' | grep -E '^grpc-(status|message)'
}
```

`grpc-status: 0` is success. Anything else comes with a `grpc-message` saying why.

Delete the conversation from Step 11, by script:

```bash run id=step-14-delete-script
kagent_delete_session "$CONV"
```

**Verified on 2026-10-12:**

```text
grpc-status: 0
```

Whichever way you deleted it, check the actor, the snapshot and the worker node:

```bash run id=step-14-check
kubectl-ate get actor "session-${CONV}" -a kagent 2>&1 || true
echo "-- snapshot objects left for the actor:"
snapshot_ls "kagent/atespaces/kagent/actors/${CONV_ACTOR_UID}/"
echo "-- directory left on the node:"
docker exec "${KIND_CLUSTER_NAME}-control-plane" ls /var/lib/ate/actors/${CONV_ACTOR_UID}
```

**Verified on 2026-10-12:**

```text
Error: failed to get actor "session-01a12e60-9eb8-7de1-949e-ab146122b86d": rpc error: code = NotFound desc = Actor kagent/session-01a12e60-9eb8-7de1-949e-ab146122b86d not found
-- snapshot objects left for the actor:
(no objects)
-- directory left on the node:
bundles
checkpoint-state
durable-dir
pidfiles
restore-state
runsc-state
sandbox-assets.json
system-info
volumes
```

The actor is gone from Substrate and its snapshot from the store. **Its directory on the node is
not.** Every conversation ever placed on a node leaves `/var/lib/ate/actors/<actor uid>/` behind,
a few dozen kilobytes of empty subdirectories and one small file, and nothing removes them. Plan
node disk and inodes for it; Before production covers it. On a cluster other than kind, read the
directory through a node shell rather than `docker exec`.

Deleting an `Agent` does not delete its conversations. Its actor template and golden image stay
in Substrate for as long as any of its conversations exist, and went about half a minute after the
last one was deleted (observed once, on this release). Delete an agent's conversations as well as
the `Agent` when you retire it.

### Step 15: Choose a Harness

An `Agent` pairs a template with a harness, and the two are independent. The `assistant` template
says what the agent is; the harness says what runs it. This runs the same template on the Claude
Code runtime instead of kagent's Go ADK runtime, with no change to the template, the model
configuration or the gateway:

```bash run id=harness-claude-code
kubectl apply -f- <<EOF
apiVersion: api.kagent.dev/v1alpha3
kind: Harness
metadata:
  name: claude-code
  namespace: kagent
spec:
  claude: {}
  workload:
    image: ${CLAUDE_HARNESS_IMAGE}
  substrate:
    workerPoolRef:
      name: kagent-default
    snapshotPolicy:
      location: gs://ate-snapshots/kagent/
---
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata:
  name: assistant-claude-code
  namespace: kagent
spec:
  templateRef:
    name: assistant
  harnessRef:
    name: claude-code
EOF
kubectl wait agent/assistant-claude-code -n kagent --for=condition=Ready --timeout=300s
```

**Verified on 2026-10-12:**

```text
harness.api.kagent.dev/claude-code created
agent.api.kagent.dev/assistant-claude-code created
agent.api.kagent.dev/assistant-claude-code condition met
```

```bash run id=step-15-claude-code-turn
TURN=$(kagent_send assistant-claude-code "Reply with exactly: claude code harness")
echo "$TURN"
export CLAUDE_CONTEXT=$(echo "$TURN" | cut -f2)
kubectl-ate get egress-policy "session-${CLAUDE_CONTEXT}" --atespace kagent -o json \
  | jq -r '.rules[] | to_entries[0] | "\(.key)\t\(.value.hostnames[0]):\(.value.ports.numbers[0])\t\([.value.effects.replaceHeaders[]? | "\(.header) <- \(.credentialUri)"] | join(", "))"'
```

**Verified on 2026-10-12:**

```text
TASK_STATE_COMPLETED	01a12e61-1de6-70ca-bb19-3dbebde29fd5	claude code har
http	agentgateway-proxy.agentgateway-system.svc.cluster.local:80	x-api-key <- ate-secret://k8s.io/default/kagent/kagent-gateway-consumer-key/api-key
http	kagent-controller.kagent:8083
```

Same consumer key, same injection, same gateway. The runtime changed and nothing around it did.

One difference: this actor's allowlist has no `api.anthropic.com` rule. The kagent runtime's
actors get one whatever `baseUrl` says (Step 9); the Claude Code runtime's do not, so its actors
can reach the provider only through the gateway.

Four harness kinds exist on this release, and an Agent's harness names exactly one:

| Kind | What runs | In this guide |
|---|---|---|
| `kagent` | kagent's Go ADK runtime | Steps 8 to 14 |
| `claude` | Claude Code | This step |
| `codex` | OpenAI Codex | Not covered: not verified on this release |
| `byo` | Your own image | Not covered: see below |

`byo` is the path for other frameworks, such as LangGraph or CrewAI, and it is not a plain
container: the image must implement kagent's agent contract, which kagent's adapter packages for
those frameworks provide. An unmodified framework image does not run.

**What you now have:** the lifecycle of a conversation, end to end, and the commands to see each
stage: the template and golden image behind an agent, an actor per conversation that holds nothing
while suspended, context in the snapshot store, and what deletion leaves behind. You have also seen
how exposed that context is. Isolate starts there.

## ISOLATE

Operate showed how a conversation lives. This section shows what keeps conversations, credentials
and users apart, proves each control from the inside, and closes the two things Up and Running left
open: the snapshot store and the bundled login.

**What you are going to do:** look inside a sandbox, see what is left of a suspended conversation,
prove the agent never holds a key, test the egress allowlist from inside two runtimes, give an
agent an MCP tool through the gateway, put a budget on the team, replace the snapshot store's
credentials and fence it, and move the UI and API to Keycloak with roles.

**What you will have that you did not have before:** every outbound credential held outside the
agent, every conversation's data reachable only by the components that need it, and every caller
of the UI and API authenticated, with roles deciding who can chat.

Each step says which runtime it shows: the kagent Go ADK runtime (agent `assistant`) or Claude Code
(agent `assistant-claude-code`, from Step 15).

**Verified on:** certification run on kind cluster `agents` (kind 0.32.0, `kindest/node:v1.35.0`), created fresh for it, 2026-10-12 04:27 to 04:36 UTC. Every `run` block from Step 1 to Step 31 was executed verbatim, in document order, in one uninterrupted pass of `auto-build/run.sh`, on the versions in Version support; every output block in this guide comes from that pass.

### Step 16: One gVisor sandbox per conversation

*Runtime: kagent.*

Every actor runs in its own gVisor sandbox on a worker pod. gVisor puts a user-space kernel between
the agent and the node's kernel, so actors from different teams packed onto one worker never share a
kernel with each other or make system calls into the host's.

This helper runs a command inside a conversation's sandbox, through `runsc`, the gVisor runtime
Substrate unpacks onto each node:

```bash run id=step-16-helpers
# sandbox_exec <conversation id> <command...>: run a command inside that conversation's sandbox.
# The actor must be running (kubectl-ate resume actor ...).
sandbox_exec() {
  local conv=$1 uid; shift
  uid=$(kubectl-ate get actor "session-${conv}" -a kagent -o json | jq -r .metadata.uid)
  docker exec "${KIND_CLUSTER_NAME}-control-plane" sh -c '
    R=$(find /var/lib/ate/static-files -name runsc -type f | head -1)
    "$R" --root=/var/lib/ate/actors/'"$uid"'/runsc-state exec kagent "$@" 2>&1 | grep -a -v "sandbox is not running" || true' sh "$@"
}

# sandbox_procs <conversation id>: gVisor processes on the node for that conversation's actor.
sandbox_procs() {
  local uid
  uid=$(kubectl-ate get actor "session-$1" -a kagent -o json | jq -r .metadata.uid)
  docker exec "${KIND_CLUSTER_NAME}-control-plane" sh -c "ps -eo args | grep -c '^runsc-sandbox --root=/var/lib/ate/actors/${uid}/' || true"
}
```

On this release `runsc exec` prints `sandbox is not running` and exits non-zero after every command,
including ones that ran. The helper drops that line and ignores the status, so read the output, not
the exit code. On a cluster other than kind, run the same `runsc` command from a node shell.

Resume Step 9's conversation and look inside its sandbox:

```bash run id=step-16-inside
kubectl-ate resume actor "session-${FIRST_CONTEXT}" -a kagent >/dev/null
echo "-- kernel inside the sandbox:"
sandbox_exec "$FIRST_CONTEXT" uname -a
echo "-- kernel on the node:"
docker exec "${KIND_CLUSTER_NAME}-control-plane" uname -r
echo "-- gVisor sandboxes on the node for this actor: $(sandbox_procs "$FIRST_CONTEXT")"
```

**Verified on 2026-10-12:**

```text
-- kernel inside the sandbox:
Linux actor 4.19.0-gvisor #1 SMP Sun Jan 10 15:06:54 PST 2016 aarch64 Linux
-- kernel on the node:
6.8.0-117-generic
-- gVisor sandboxes on the node for this actor: 1
```

The agent sees gVisor's kernel, not the node's. Its processes are not in the node's process table
at all; what the node runs is the gVisor sandbox around them.

### Step 17: What is left of a suspended conversation

*Runtime: kagent.*

Suspend the same conversation and look again:

```bash run id=step-17-suspended
kubectl-ate suspend actor "session-${FIRST_CONTEXT}" -a kagent
echo "-- gVisor sandboxes on the node for this actor: $(sandbox_procs "$FIRST_CONTEXT")"
echo "-- its snapshot:"
snapshot_ls "kagent/atespaces/kagent/actors/$(kubectl-ate get actor "session-${FIRST_CONTEXT}" -a kagent -o json | jq -r .metadata.uid)/"
```

**Verified on 2026-10-12:**

```text
ATESPACE   NAME                                           TEMPLATE                        STATE                   WORKER POD   WORKER IPS   VERSION   AGE
kagent     session-01a12e60-9a03-70f0-bd18-ea0d1054702b   kagent/assistant-b24ff6be83c3   ACTOR_STATE_SUSPENDED   <none>                    9         36s
-- gVisor sandboxes on the node for this actor: 0
-- its snapshot:
2026-10-12 04:31:21       1391 kagent/atespaces/kagent/actors/1746c309-b467-4633-9d65-6c0f56766d06/snapshots/5a4d1d4e-6361-4579-99f8-e256c22e7af2/durable-dir.tar.zstd
2026-10-12 04:31:21        609 kagent/atespaces/kagent/actors/1746c309-b467-4633-9d65-6c0f56766d06/snapshots/5a4d1d4e-6361-4579-99f8-e256c22e7af2/manifest.json
```

| | Running | Suspended |
|---|---|---|
| Process and sandbox | gVisor sandbox on a worker | **None** |
| Network | An IP on the worker | **None** |
| Identity certificate | Mounted in the sandbox | **None**: a new one is issued on resume |
| Conversation data | In the sandbox | One snapshot in the store (Step 13) |
| Record in Substrate | The actor | The actor, `SUSPENDED` |
| On the node | Its actor directory | The directory's empty shell (Step 14) |

A suspended conversation cannot be reached, because there is nothing running to reach. What it
leaves is data, and Step 22 is about who can read that data.

### Step 18: The agent never holds a key

*Runtimes: kagent and Claude Code.*

Both agents authenticate to the gateway with the consumer key, and neither process ever sees it.
Resume one conversation from each runtime:

```bash run id=step-18-resume
kubectl-ate resume actor "session-${FIRST_CONTEXT}" -a kagent >/dev/null
kubectl-ate resume actor "session-${CLAUDE_CONTEXT}" -a kagent >/dev/null
kubectl-ate get actors -a kagent | grep -E "NAME|${FIRST_CONTEXT}|${CLAUDE_CONTEXT}"
```

**Verified on 2026-10-12:**

```text
ATESPACE   NAME                                           TEMPLATE                                    STATE                 WORKER POD                              WORKER IPS    VERSION   AGE
kagent     session-01a12e60-9a03-70f0-bd18-ea0d1054702b   kagent/assistant-b24ff6be83c3               ACTOR_STATE_RUNNING   kagent/kagent-default-ff8dfbd47-sr45m   10.244.0.24   11        39s
kagent     session-01a12e61-1de6-70ca-bb19-3dbebde29fd5   kagent/assistant-claude-code-7ddb87a7ff07   ACTOR_STATE_RUNNING   kagent/kagent-default-ff8dfbd47-dm22t   10.244.0.23   7         6s
```

What each agent process has for a credential:

```bash run id=step-18-environment
for conv in "$FIRST_CONTEXT" "$CLAUDE_CONTEXT"; do
  echo "-- session-${conv}"
  sandbox_exec "$conv" cat /proc/1/environ | tr '\0' '\n' | grep -E '^(ANTHROPIC_API_KEY|KAGENT_CREDENTIAL_)' || true
done
```

**Verified on 2026-10-12:**

```text
-- session-01a12e60-9a03-70f0-bd18-ea0d1054702b
ANTHROPIC_API_KEY=kagent-credential-injected
-- session-01a12e61-1de6-70ca-bb19-3dbebde29fd5
ANTHROPIC_API_KEY=kagent-credential-injected
```

The placeholder, in both. Now look for the real consumer key anywhere in either sandbox's
filesystem. The conversation's own text is the control: it is in the session database, so a search
that cannot find it proves nothing.

```bash run id=step-18-search
# count_in_sandbox <conversation id> <string>: lines of the sandbox's filesystem containing the string.
count_in_sandbox() {
  sandbox_exec "$1" tar -cf - --exclude=./proc --exclude=./sys -C / . | LC_ALL=C grep -a -c -F "$2" || true
}
for pair in "$FIRST_CONTEXT:up and running" "$CLAUDE_CONTEXT:claude code harness"; do
  conv=${pair%%:*}; control=${pair#*:}
  echo "-- session-${conv}: consumer key $(count_in_sandbox "$conv" "$AGENT_CONSUMER_KEY"), control \"${control}\" $(count_in_sandbox "$conv" "$control")"
done
```

**Verified on 2026-10-12:**

```text
-- session-01a12e60-9a03-70f0-bd18-ea0d1054702b: consumer key 0, control "up and running" 1
-- session-01a12e61-1de6-70ca-bb19-3dbebde29fd5: consumer key 0, control "claude code harness" 6
```

The key is not in either sandbox, and the Anthropic key is not even in the `kagent` namespace: it
exists only in the gateway's Secret (Step 6).

Yet the agent authenticates. Send a request from inside the kagent sandbox, carrying only the
placeholder it was given:

```bash run id=step-18-injected
sandbox_exec "$FIRST_CONTEXT" wget -q -O - -T 30 \
  --header 'content-type: application/json' --header 'anthropic-version: 2023-06-01' \
  --header 'x-api-key: kagent-credential-injected' \
  --post-data "{\"model\":\"${MODEL}\",\"max_tokens\":16,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: injected\"}]}" \
  http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/messages | jq -r '.content[0].text'
kubectl-ate suspend actor "session-${FIRST_CONTEXT}" -a kagent >/dev/null
kubectl-ate suspend actor "session-${CLAUDE_CONTEXT}" -a kagent >/dev/null
```

**Verified on 2026-10-12:**

```text
injected
```

The gateway answered a request whose key, as sent, was the placeholder. Substrate's egress gateway
replaced it with the consumer key on the way out, as the egress policy in Step 9 said it would. An
attacker who takes over the agent process gets the placeholder.

> [!NOTE]
> **The agent never holds the key; the kagent controller does.** The controller reads the Secrets it compiles into egress bindings, and sends MCP header values itself during tool discovery (Step 20). Restrict who can read the `kagent` namespace's Secrets and exec into its pods.

### Step 19: Test the egress allowlist from inside

*Runtimes: kagent and Claude Code. The difference between them is the point.*

Each actor can reach only the destinations kagent compiled into its egress policy. Try three from
inside each runtime's sandbox: a site no policy names, the provider, and the gateway:

```bash run id=step-19-allowlist
kubectl-ate resume actor "session-${FIRST_CONTEXT}" -a kagent >/dev/null
kubectl-ate resume actor "session-${CLAUDE_CONTEXT}" -a kagent >/dev/null
for conv in "$FIRST_CONTEXT" "$CLAUDE_CONTEXT"; do
  echo "-- session-${conv}"
  for url in https://example.com/ https://api.anthropic.com/v1/models \
             http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/messages; do
    printf '  %-80s %s\n' "$url" "$(sandbox_exec "$conv" wget -T 10 -O /dev/null "$url" | grep -o 'HTTP/1.1 [0-9]* [A-Za-z ]*' | head -1)"
  done
done
kubectl-ate suspend actor "session-${FIRST_CONTEXT}" -a kagent >/dev/null
kubectl-ate suspend actor "session-${CLAUDE_CONTEXT}" -a kagent >/dev/null
```

**Verified on 2026-10-12:**

```text
-- session-01a12e60-9a03-70f0-bd18-ea0d1054702b
  https://example.com/                                                             HTTP/1.1 403 Forbidden
  https://api.anthropic.com/v1/models                                              HTTP/1.1 401 Unauthorized
  http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/messages      HTTP/1.1 401 Unauthorized
-- session-01a12e61-1de6-70ca-bb19-3dbebde29fd5
  https://example.com/                                                             HTTP/1.1 403 Forbidden
  https://api.anthropic.com/v1/models                                              HTTP/1.1 403 Forbidden
  http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/messages      HTTP/1.1 401 Unauthorized
```

| Destination | `403 Forbidden` | `401 Unauthorized` |
|---|---|---|
| Not in the egress policy | Substrate's egress gateway refused it | |
| In the egress policy, no credential sent | | The destination answered: it is reachable |

`example.com` is refused for both. The gateway is reachable for both. `api.anthropic.com` is the
difference: the kagent runtime's actors can reach it directly (without a key, so they cannot use
it), while the Claude Code runtime's actors cannot reach it at all. With the kagent runtime, the
allowlist alone does not force model traffic through the gateway; on this release no supported
setting removes that rule.

### Step 20: Give an agent an MCP tool through the gateway

*Runtime: kagent.*

An MCP server's credential is handled like a model key: kagent turns a Secret-backed header on a
`RemoteMCPServer` into an egress binding, and the agent gets a placeholder. Put the server behind
the enterprise gateway and the agent needs only the consumer key; the server's own credential stays
in the gateway.

Deploy an MCP server that requires a bearer token. It is a small reference server, written for this
guide with Python's standard library: one tool, `lookup_code`, which returns a code the model cannot
guess, and a log line per request saying whether the token matched, never the token itself.

```bash run id=mcp-deployment-codes
kubectl create namespace mcp-tools
export MCP_SERVER_TOKEN=$(openssl rand -hex 24)
printf '%s' "$MCP_SERVER_TOKEN" | kubectl create secret generic deployment-codes-token \
  -n mcp-tools --from-file=MCP_TOKEN=/dev/stdin
kubectl create configmap deployment-codes-server -n mcp-tools --from-file=server.py=/dev/stdin <<'PY'
# Minimal MCP server: streamable HTTP, JSON responses, one tool.
# Requires "Authorization: Bearer <MCP_TOKEN>". Logs a classification of each request's
# Authorization header, never its value.
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOKEN = os.environ["MCP_TOKEN"]
PLACEHOLDER = "kagent-credential-injected"
CODE = "K7-teal-otter-0429"
TOOL = {"name": "lookup_code", "description": "Look up the deployment code for a named service.",
        "inputSchema": {"type": "object", "properties": {"service": {"type": "string"}}, "required": ["service"]}}

def classify(v):
    if v is None: return "absent"
    if v == "Bearer " + TOKEN: return "bearer-match"
    if v == TOKEN: return "raw-match"
    if PLACEHOLDER in v: return "placeholder"
    return f"other(len={len(v)})"

class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def log(self, **kw):
        kw.update(t=time.strftime("%H:%M:%S", time.gmtime()), src=self.client_address[0], verb=self.command,
                  auth=classify(self.headers.get("Authorization")),
                  headers=sorted(k.lower() for k in self.headers.keys()))
        print(json.dumps(kw), flush=True)
    def send(self, code, body=None, ctype="application/json"):
        data = b"" if body is None else json.dumps(body).encode()
        self.send_response(code)
        if body is not None: self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Mcp-Session-Id", "c10")
        self.end_headers(); self.wfile.write(data)
    def do_GET(self):
        self.log(rpc="GET"); self.send(405)
    def do_DELETE(self):
        self.log(rpc="DELETE"); self.send(200)
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        msg = json.loads(self.rfile.read(n) or b"{}")
        method = msg.get("method"); auth = classify(self.headers.get("Authorization"))
        extra = {}
        if method == "tools/call": extra["tool"] = msg.get("params", {}).get("name")
        self.log(rpc=method, **extra)
        if auth != "bearer-match":
            return self.send(401, {"jsonrpc": "2.0", "id": msg.get("id"), "error": {"code": -32001, "message": "unauthorized"}})
        if "id" not in msg:
            return self.send(202)
        if method == "initialize":
            ver = msg.get("params", {}).get("protocolVersion", "2025-03-26")
            res = {"protocolVersion": ver, "capabilities": {"tools": {}}, "serverInfo": {"name": "c10-stub", "version": "1"}}
        elif method == "tools/list":
            res = {"tools": [TOOL]}
        elif method == "tools/call":
            svc = msg.get("params", {}).get("arguments", {}).get("service", "")
            res = {"content": [{"type": "text", "text": f"The deployment code for {svc} is {CODE}."}]}
        elif method == "ping":
            res = {}
        else:
            return self.send(200, {"jsonrpc": "2.0", "id": msg["id"], "error": {"code": -32601, "message": "method not found"}})
        self.send(200, {"jsonrpc": "2.0", "id": msg["id"], "result": res})

ThreadingHTTPServer(("", 8080), H).serve_forever()
PY
kubectl apply -f- <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: deployment-codes
  namespace: mcp-tools
spec:
  replicas: 1
  selector:
    matchLabels: {app: deployment-codes}
  template:
    metadata:
      labels: {app: deployment-codes}
    spec:
      containers:
        - name: server
          image: ${MCP_SERVER_IMAGE}
          command: ["python", "-u", "/app/server.py"]
          env:
            - name: MCP_TOKEN
              valueFrom: {secretKeyRef: {name: deployment-codes-token, key: MCP_TOKEN}}
          ports: [{containerPort: 8080}]
          volumeMounts: [{name: app, mountPath: /app}]
      volumes:
        - name: app
          configMap: {name: deployment-codes-server}
---
apiVersion: v1
kind: Service
metadata:
  name: deployment-codes
  namespace: mcp-tools
spec:
  selector: {app: deployment-codes}
  ports: [{name: http, port: 8080, targetPort: 8080}]
EOF
kubectl rollout status deployment/deployment-codes -n mcp-tools --timeout=180s
```

**Verified on 2026-10-12:**

```text
namespace/mcp-tools created
secret/deployment-codes-token created
configmap/deployment-codes-server created
deployment.apps/deployment-codes created
service/deployment-codes created
Waiting for deployment "deployment-codes" rollout to finish: 0 of 1 updated replicas are available...
deployment "deployment-codes" successfully rolled out
```

Put it behind the gateway. The backend holds the server's token and sends it as
`Authorization: Bearer <token>`; the route requires the same consumer key as the model route:

```bash run id=backend-deployment-codes-mcp
printf '%s' "$MCP_SERVER_TOKEN" | kubectl create secret generic deployment-codes-gw-auth \
  -n agentgateway-system --from-file=Authorization=/dev/stdin
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBackend
metadata:
  name: deployment-codes-mcp
  namespace: agentgateway-system
spec:
  mcp:
    targets:
      - name: deployment-codes
        static:
          host: deployment-codes.mcp-tools.svc.cluster.local
          port: 8080
          path: /mcp
          protocol: StreamableHTTP
          policies:
            auth:
              secretRef:
                name: deployment-codes-gw-auth
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: deployment-codes-mcp
  namespace: agentgateway-system
spec:
  parentRefs:
    - name: agentgateway-proxy
      namespace: agentgateway-system
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /mcp
      backendRefs:
        - group: enterpriseagentgateway.solo.io
          kind: EnterpriseAgentgatewayBackend
          name: deployment-codes-mcp
          namespace: agentgateway-system
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: deployment-codes-mcp-apikey-auth
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      name: deployment-codes-mcp
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

> [!WARNING]
> **Every route needs its own key policy.** The policy above targets this route only. A route added later without one accepts anonymous traffic, and nothing reports it: the route is accepted, the backend answers.

Declare the tool server to kagent, pointing at the gateway with the consumer key, and an agent that
uses it:

```bash run id=agent-deployment-assistant
kubectl apply -f- <<EOF
apiVersion: api.kagent.dev/v1alpha3
kind: RemoteMCPServer
metadata:
  name: deployment-codes
  namespace: kagent
spec:
  description: Deployment codes, through Solo Enterprise for agentgateway.
  protocol: STREAMABLE_HTTP
  url: http://agentgateway-proxy.agentgateway-system.svc.cluster.local/mcp
  headersFrom:
    - name: x-api-key
      valueFrom:
        type: Secret
        name: kagent-gateway-consumer-key
        key: api-key
---
apiVersion: api.kagent.dev/v1alpha3
kind: AgentTemplate
metadata:
  name: deployment-helper
  namespace: kagent
spec:
  description: Looks up deployment codes.
  modelConfig:
    name: anthropic-via-gateway
  systemPrompt: |
    You are a helpful assistant. Use the lookup_code tool when asked for a deployment code. Answer concisely.
  tools:
    - mcp:
        server:
          kind: RemoteMCPServer
          name: deployment-codes
        tools: [lookup_code]
---
apiVersion: api.kagent.dev/v1alpha3
kind: Agent
metadata:
  name: deployment-helper
  namespace: kagent
spec:
  templateRef:
    name: deployment-helper
  harnessRef:
    name: kagent-adk
EOF
kubectl wait remotemcpserver/deployment-codes -n kagent --for=condition=Accepted --timeout=120s
kubectl get remotemcpserver deployment-codes -n kagent -o jsonpath='{.status.conditions[0].reason}: {.status.conditions[0].message}{"\n"}'
kubectl wait agent/deployment-helper -n kagent --for=condition=Ready --timeout=300s
```

**Verified on 2026-10-12:**

```text
remotemcpserver.api.kagent.dev/deployment-codes created
agenttemplate.api.kagent.dev/deployment-helper created
agent.api.kagent.dev/deployment-helper created
remotemcpserver.api.kagent.dev/deployment-codes condition met
DiscoverySucceeded: Discovered 1 MCP tools
agent.api.kagent.dev/deployment-helper condition met
```

`DiscoverySucceeded` depends on Step 7's second rule. The kagent controller discovers tools by
calling the server's URL itself, from its own pod; without that rule the gateway drops it, the
`RemoteMCPServer` reports `DiscoveryFailed … context deadline exceeded`, and the agent still goes
`Ready` and still works, so nothing else tells you.

Ask for a code, then read the conversation's egress policy and the MCP server's log:

```bash run id=step-20-tool-call
TURN=$(kagent_send deployment-helper "What is the deployment code for the service payments? Use the tool.")
echo "$TURN"
echo "-- egress policy:"
kubectl-ate get egress-policy "session-$(echo "$TURN" | cut -f2)" --atespace kagent -o json \
  | jq -r '.rules[] | to_entries[0] | "\(.key)\t\(.value.hostnames[0]):\(.value.ports.numbers[0])\t\([.value.effects.replaceHeaders[]? | "\(.header) <- \(.credentialUri)"] | join(", "))"'
echo "-- MCP server log for the tool call (gateway pod: $(kubectl get pod -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy -o jsonpath='{.items[0].status.podIP}')):"
kubectl logs -n mcp-tools deployment/deployment-codes | jq -c 'select(.rpc == "tools/call") | {t, src, rpc, tool, auth}' | tail -1
```

**Verified on 2026-10-12:**

```text
TASK_STATE_COMPLETED	01a12e61-6fed-7d72-9b1b-7bb0a0a2f478	The deployment code for the payments service is **K7-teal-otter-0429**.
-- egress policy:
http	agentgateway-proxy.agentgateway-system.svc.cluster.local:80	x-api-key <- ate-secret://k8s.io/default/kagent/kagent-gateway-consumer-key/api-key
http	kagent-controller.kagent:8083	
https	api.anthropic.com:443	
-- MCP server log for the tool call (gateway pod: 10.244.0.27):
{"t":"04:31:41","src":"10.244.0.27","rpc":"tools/call","tool":"lookup_code","auth":"bearer-match"}
```

The answer carries the code only the server knows, so the tool ran. The actor's policy names the
gateway, not the MCP server: it has no route to the server except through the gateway. The server
saw the call come from the gateway's pod with its own token (`bearer-match`). The agent held only a
placeholder for the consumer key, and never had the server's token at all.

### Step 21: Team budgets and cost attribution

*Runtime: either. Both agents present the same consumer key, so they share the team's budget.*

The consumer key's metadata names a `group` (`team-agents`, Step 6). The gateway's default budget
dimensions group traffic by `apiKey.group`, so a budget on that group covers every agent holding the
key, whatever runtime it uses. Enforce budgets on the Gateway, give the team a daily token budget,
and label the gateway's metrics with the caller:

```bash run id=policy-team-budgets
kubectl apply -f- <<EOF
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: llm-budget-enforcement
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  traffic:
    entBudgetEnforcement: {}
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayBudget
metadata:
  name: team-budgets
  namespace: agentgateway-system
spec:
  budgets:
    - name: team-agents-daily-tokens
      subject:
        group: team-agents
      limit:
        unit: Tokens
        amount: 200000
      window:
        unit: Day
      onBudgetExceeded: Block
---
apiVersion: enterpriseagentgateway.solo.io/v1alpha1
kind: EnterpriseAgentgatewayPolicy
metadata:
  name: llm-caller-attribution
  namespace: agentgateway-system
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: agentgateway-proxy
  frontend:
    metrics:
      attributes:
        add:
          - name: user_id
            expression: 'coalesce(apiKey.user, jwt.email)'
          - name: team
            expression: 'apiKey.group'
EOF
sleep 5
```

Send a turn from each runtime, then read the gateway's token metrics. The metrics port is 15020 on the
proxy; the forward uses local port 18082, because 15020 is often still held by a forward from
another gateway guide, and a forward that cannot bind fails silently in the background while
`curl` reads whatever already holds the port:

```bash run id=step-21-attribution
kagent_send assistant "Reply with exactly: attributed"
kagent_send assistant-claude-code "Reply with exactly: attributed"
kubectl port-forward --address 127.0.0.1 -n agentgateway-system deployment/agentgateway-proxy 18082:15020 >/dev/null 2>&1 &
PF=$!; sleep 3
if ! kill -0 $PF 2>/dev/null; then
  echo "the port-forward on 18082 did not start: something else holds the port" >&2
else
  curl -sS http://127.0.0.1:18082/metrics | grep '^agentgateway_gen_ai_client_token_usage_sum' | grep 'team="team-agents"' \
    | while read -r line; do
        printf '%s %s\n' "$(printf '%s' "$line" | grep -oE '(team|user_id|gen_ai_token_type)="[^"]*"' | tr '\n' ' ')" "${line##* }"
      done
  kill $PF
fi
```

**Verified on 2026-10-12:**

```text
TASK_STATE_COMPLETED	01a12e61-8b1f-73b2-884d-0e21599d2aed	attributed
TASK_STATE_COMPLETED	01a12e61-8dd4-7cb9-a871-04215df1d8fa	attributed
gen_ai_token_type="input_cache_write" user_id="assistant-agent" team="team-agents"  2698.0
gen_ai_token_type="output" user_id="assistant-agent" team="team-agents"  46.0
gen_ai_token_type="input_cache_read" user_id="assistant-agent" team="team-agents"  28778.0
gen_ai_token_type="input" user_id="assistant-agent" team="team-agents"  710.0
```

Every token is attributed to the key's `user` and `group`, so spend is per team or per agent key,
not per person: the kagent user behind a conversation is not passed to the gateway.

Prove the budget is enforced, not just accepted: drop it to one token, send a turn, then put it
back:

```bash run id=step-21-budget-block
kubectl patch enterpriseagentgatewaybudget team-budgets -n agentgateway-system --type json \
  -p '[{"op":"replace","path":"/spec/budgets/0/limit/amount","value":1}]'
sleep 5
kagent_send assistant "Reply with exactly: over budget"
kubectl patch enterpriseagentgatewaybudget team-budgets -n agentgateway-system --type json \
  -p '[{"op":"replace","path":"/spec/budgets/0/limit/amount","value":200000}]'
sleep 5
kagent_send assistant "Reply with exactly: back under budget"
```

**Verified on 2026-10-12:**

```text
enterpriseagentgatewaybudget.enterpriseagentgateway.solo.io/team-budgets patched
TASK_STATE_FAILED	01a12e61-b620-7970-a3ad-427dd9787304	llm error response (code STREAM_ERROR): "POST \"http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/messages\": 429 Too Many Requests rate limit exceeded"
enterpriseagentgatewaybudget.enterpriseagentgateway.solo.io/team-budgets patched
TASK_STATE_COMPLETED	01a12e61-cf77-7b12-9515-0d32235d3589	back under budget
```

The blocked turn fails in the agent with the gateway's `429`. The runtime retries a blocked call
three times before giving up, and each attempt counts as a request, though none consumes tokens.

### Step 22: Replace the snapshot store's credentials and fence it

*Runtime: kagent.*

Step 13 showed the problem: the store holds every conversation in readable form, and the chart runs
it with fixed default credentials that anyone in the cluster can use. Two changes close it.

**First, non-default credentials.** The chart cannot read them from a Secret: it writes
`rustfs.accessKey` and `rustfs.secretKey` as plain values into the RustFS, bucket-init, atelet and
ate-api pod specs. So generate them in your shell and pass them at upgrade time, never in a values
file you commit. `--reuse-values` keeps everything Step 3 set. The completed bucket-init Job goes
first, because its pod template changes with the credentials and a finished Job cannot be updated:

```bash run id=substrate-rustfs-credentials
export RUSTFS_ACCESS_KEY=$(openssl rand -hex 10)
export RUSTFS_SECRET_KEY=$(openssl rand -hex 20)
kubectl delete job rustfs-bucket-init -n ate-system --ignore-not-found
helm upgrade substrate \
  oci://us-docker.pkg.dev/solo-public/enterprise-substrate-helm/substrate \
  --version ${SUBSTRATE_VERSION} \
  --namespace ate-system \
  --reuse-values \
  -f - <<EOF
rustfs:
  accessKey: ${RUSTFS_ACCESS_KEY}
  secretKey: ${RUSTFS_SECRET_KEY}
EOF
kubectl rollout status deployment/rustfs -n ate-system --timeout=300s
kubectl rollout status deployment/ate-api-server -n ate-system --timeout=300s
kubectl rollout status daemonset/atelet -n ate-system --timeout=300s
kubectl wait --for=condition=complete job/rustfs-bucket-init -n ate-system --timeout=180s
```

**Verified on 2026-10-12:**

```text
job.batch "rustfs-bucket-init" deleted from ate-system namespace
Release "substrate" has been upgraded. Happy Helming!
NAME: substrate
STATUS: deployed
REVISION: 2
DESCRIPTION: Upgrade complete
(Helm's release notes omitted)
Waiting for deployment "rustfs" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "rustfs" rollout to finish: 1 old replicas are pending termination...
deployment "rustfs" successfully rolled out
Waiting for deployment "ate-api-server" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "ate-api-server" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "ate-api-server" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "ate-api-server" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "ate-api-server" rollout to finish: 1 old replicas are pending termination...
deployment "ate-api-server" successfully rolled out
daemon set "atelet" successfully rolled out
job.batch/rustfs-bucket-init condition met
```

The values go through stdin, so they never appear in a command line, but Helm keeps them in its
release Secret and they are in the four pod specs. Anyone who can read those still has them, which
is why the second change matters more.

Prove the defaults no longer work, and that conversations suspended under the old credentials are
still readable under the new ones:

```bash run id=step-22-credentials-check
echo "-- default credentials:"
S3_ACCESS_KEY=rustfsadmin S3_SECRET_KEY=rustfsadmin snapshot_ls "kagent/" | tail -2
echo "-- Step 9's conversation, suspended before the change:"
kagent_send assistant "What exact phrase did I ask you to reply with in my first message? Answer with only that phrase." "$FIRST_CONTEXT"
```

**Verified on 2026-10-12:**

```text
-- default credentials:

An error occurred (InvalidAccessKeyId) when calling the ListObjectsV2 operation: The Access Key Id you provided does not exist in our records.
-- Step 9's conversation, suspended before the change:
TASK_STATE_COMPLETED	01a12e60-9a03-70f0-bd18-ea0d1054702b	up and running
```

**Second, a NetworkPolicy**, so that only the components that read and write snapshots can reach the
store at all. The chart has no setting to turn off RustFS's web console on port 9001, so the policy
admits the S3 port only:

```bash run id=networkpolicy-rustfs
kubectl apply -f- <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: rustfs-snapshot-store
  namespace: ate-system
spec:
  podSelector:
    matchLabels:
      app: rustfs
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: atelet
        - podSelector:
            matchLabels:
              app: ate-api-server
        - podSelector:
            matchLabels:
              job-name: rustfs-bucket-init
      ports:
        - protocol: TCP
          port: 9000
EOF
```

atelet uploads and downloads snapshots, ate-api lists, copies and deletes them, and the chart's
bucket-init Job creates the bucket on a fresh install. Nothing else needs the store.

Prove it, from a pod in the store's own namespace, with the right credentials:

```bash run id=step-22-fence-check
echo "-- snapshot_ls with the new credentials, from a pod that is not atelet or ate-api:"
snapshot_ls "kagent/" | tail -2
echo "-- a conversation still resumes:"
kagent_send assistant "Reply with exactly: fenced" "$FIRST_CONTEXT"
```

**Verified on 2026-10-12:**

```text
-- snapshot_ls with the new credentials, from a pod that is not atelet or ate-api:

Connect timeout on endpoint URL: "http://rustfs.ate-system.svc:9000/ate-snapshots?list-type=2&prefix=kagent%2F&encoding-type=url"
-- a conversation still resumes:
TASK_STATE_COMPLETED	01a12e60-9a03-70f0-bd18-ea0d1054702b	fenced
```

Correct credentials, wrong pod, no connection. `snapshot_ls` from Step 13 no longer works on this
cluster, which is the point of the step; atelet and ate-api are unaffected.

> [!NOTE]
> **This fences the store; it does not encrypt it.** Substrate sends no server-side encryption parameters, and the bundled store has no encryption setting. On an external store, only the bucket's own default encryption would apply. An external store is also only half supported on this release: atelet can take its endpoint and credentials from a Secret, ate-api cannot through the chart.

### Step 23: Authenticate the UI and API against Keycloak

*Runtime: kagent.*

Until now the bundled login has issued an admin token to anyone who asked (Step 5). Setting an OIDC
issuer on the kagent release removes it: every API, A2A and UI call then needs a token from your
identity provider, and roles come from its groups. Keycloak is the reference provider here;
Attachment A explains its configuration.

**The issuer has to be one URL that both your browser and the kagent controller can reach.** Keycloak
writes its own URL into every token's `iss` claim, and the controller rejects a token whose `iss`
differs from its configured issuer by a single byte. This guide uses `keycloak.localhost`: browsers
and curl resolve any `*.localhost` name to 127.0.0.1 themselves, where a port-forward reaches
Keycloak, and inside the cluster a CoreDNS rewrite sends the same name to the Keycloak Service,
which listens on the same port.

Generate the realm's secrets in your shell. Nothing writes them to a file:

```bash run id=keycloak-secrets
export KEYCLOAK_ADMIN_PASSWORD=$(openssl rand -hex 16)
export KAGENT_OIDC_CLIENT_SECRET=$(openssl rand -hex 24)
export KAGENT_ADMIN_PASSWORD=$(openssl rand -hex 12)
export KAGENT_WRITER_PASSWORD=$(openssl rand -hex 12)
export KAGENT_READER_PASSWORD=$(openssl rand -hex 12)
export KAGENT_NOROLE_PASSWORD=$(openssl rand -hex 12)
```

The realm is in this repository at `infra/keycloak/kagent-realm.template.json`: three clients
(`kagent-backend` for the controller, `kagent-ui` for the browser with PKCE, and `kagent-cli` for
scripts, with the password grant on and the client **disabled**), groups `admins`, `writers` and
`readers`, and four users. Fill
in its placeholders and load it into a Secret. The block resolves the file with
`git rev-parse --show-toplevel`, so it works from any directory inside the clone:

```bash run id=keycloak-realm
kubectl create namespace keycloak
printf '%s' "$KEYCLOAK_ADMIN_PASSWORD" | kubectl create secret generic keycloak-admin \
  -n keycloak --from-file=password=/dev/stdin
sed -e "s|\${KAGENT_OIDC_CLIENT_SECRET}|${KAGENT_OIDC_CLIENT_SECRET}|" \
    -e "s|\${KAGENT_ADMIN_PASSWORD}|${KAGENT_ADMIN_PASSWORD}|" \
    -e "s|\${KAGENT_WRITER_PASSWORD}|${KAGENT_WRITER_PASSWORD}|" \
    -e "s|\${KAGENT_READER_PASSWORD}|${KAGENT_READER_PASSWORD}|" \
    -e "s|\${KAGENT_NOROLE_PASSWORD}|${KAGENT_NOROLE_PASSWORD}|" \
    -e "s|localhost:14000|localhost:${KAGENT_UI_PORT}|g" \
    "$(git rev-parse --show-toplevel)/infra/keycloak/kagent-realm.template.json" \
  | kubectl create secret generic keycloak-realm -n keycloak --from-file=realm.json=/dev/stdin
echo "placeholders left in the realm: $(kubectl get secret keycloak-realm -n keycloak -o jsonpath='{.data.realm\.json}' | base64 --decode | grep -c '\${' || true)"
echo "realm size: $(kubectl get secret keycloak-realm -n keycloak -o jsonpath='{.data.realm\.json}' | base64 --decode | wc -c | tr -d ' ') bytes"
```

**Verified on 2026-10-12:**

```text
namespace/keycloak created
secret/keycloak-admin created
secret/keycloak-realm created
placeholders left in the realm: 0
realm size: 4284 bytes
```

> [!WARNING]
> **An empty or half-filled realm fails silently.** If the render produces nothing, the Secret is created empty and Keycloak never becomes ready, with nothing in kagent pointing at the cause. Check both numbers above: no placeholders left, and a size of several kilobytes.

Deploy Keycloak, with its hostname set to the issuer's:

```bash run id=keycloak-deployment
kubectl apply -f- <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: keycloak
  labels: {app: keycloak}
spec:
  replicas: 1
  selector:
    matchLabels: {app: keycloak}
  template:
    metadata:
      labels: {app: keycloak}
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}
          args: ["start-dev", "--import-realm"]
          env:
            - {name: KC_BOOTSTRAP_ADMIN_USERNAME, value: admin}
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: keycloak-admin, key: password}}
            - {name: KC_HTTP_ENABLED, value: "true"}
            - {name: KC_HOSTNAME_STRICT, value: "false"}
            - {name: KC_HOSTNAME, value: "http://keycloak.localhost:${KEYCLOAK_PORT}"}
          ports: [{name: http, containerPort: 8080}]
          readinessProbe:
            httpGet: {path: /realms/kagent/.well-known/openid-configuration, port: 8080}
            initialDelaySeconds: 20
            periodSeconds: 5
            failureThreshold: 40
          volumeMounts: [{name: realm, mountPath: /opt/keycloak/data/import, readOnly: true}]
      volumes:
        - name: realm
          secret: {secretName: keycloak-realm}
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: keycloak
  labels: {app: keycloak}
spec:
  selector: {app: keycloak}
  ports: [{name: http, port: ${KEYCLOAK_PORT}, targetPort: 8080}]
EOF
kubectl rollout status deployment/keycloak -n keycloak --timeout=600s
```

**Verified on 2026-10-12:**

```text
deployment.apps/keycloak created
service/keycloak created
Waiting for deployment "keycloak" rollout to finish: 0 of 1 updated replicas are available...
deployment "keycloak" successfully rolled out
```

Make `keycloak.localhost` resolve to that Service inside the cluster. The change reaches CoreDNS
only after the kubelet refreshes the mounted ConfigMap and CoreDNS's `reload` plugin next checks it,
which can take a minute or more; the next block waits for it. This block is safe to re-run:

```bash run id=coredns-keycloak-rewrite
CORE=$(kubectl get configmap coredns -n kube-system -o jsonpath='{.data.Corefile}')
if printf '%s' "$CORE" | grep -qF 'rewrite name keycloak.localhost'; then
  echo "rewrite already present"
else
  NEW=$(printf '%s\n' "$CORE" | awk '{print} /^[[:space:]]*ready[[:space:]]*$/ && !done {print "    rewrite name keycloak.localhost keycloak.keycloak.svc.cluster.local"; done=1}')
  kubectl create configmap coredns -n kube-system --from-literal=Corefile="$NEW" --dry-run=client -o yaml \
    | kubectl patch configmap coredns -n kube-system --type merge --patch-file /dev/stdin
fi
```

Forward the same port on your machine, then check that the issuer is byte-identical from both sides:

```bash run id=keycloak-forward
pkill -f "kubectl port-forward.*-n keycloak" 2>/dev/null || true
kubectl port-forward --address 127.0.0.1 -n keycloak service/keycloak ${KEYCLOAK_PORT}:${KEYCLOAK_PORT} >/dev/null 2>&1 &
sleep 3
echo "workstation: $(curl -sS http://keycloak.localhost:${KEYCLOAK_PORT}/realms/kagent/.well-known/openid-configuration | jq -r .issuer)"
CLUSTER_ISSUER=""
for i in $(seq 1 24); do
  CLUSTER_ISSUER=$(kubectl run "issuer-check-${i}" -n default --rm -i --restart=Never --image=busybox:1.36 --quiet -- \
    wget -qO- http://keycloak.localhost:${KEYCLOAK_PORT}/realms/kagent/.well-known/openid-configuration < /dev/null 2>/dev/null \
    | jq -r .issuer 2>/dev/null || true)
  [ -n "$CLUSTER_ISSUER" ] && break
  sleep 5
done
echo "cluster:     ${CLUSTER_ISSUER:-not resolvable from inside the cluster after 24 attempts}"
```

**Verified on 2026-10-12:**

```text
workstation: http://keycloak.localhost:18080/realms/kagent
cluster:     http://keycloak.localhost:18080/realms/kagent
```

Two identical lines, or the controller will reject every token. The cluster side is retried until
the CoreDNS change has arrived; if it never resolves, check the rewrite with `kubectl get configmap
coredns -n kube-system -o yaml`. Then switch kagent to the issuer.
The client secret goes in a Secret; `--reuse-values` keeps everything Step 5 set:

```bash run id=helm-kagent-oidc
: "${KAGENT_OIDC_CLIENT_SECRET:?is empty: it was generated in another shell. Read it back first (below).}"
printf '%s' "$KAGENT_OIDC_CLIENT_SECRET" | kubectl create secret generic kagent-enterprise-oidc-secret \
  -n kagent --from-file=clientSecret=/dev/stdin
helm upgrade kagent \
  oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise \
  --version ${KAGENT_VERSION} \
  --namespace kagent \
  --reuse-values \
  --wait --timeout 10m \
  -f - <<EOF
enterprise:
  oidc:
    issuer: http://keycloak.localhost:${KEYCLOAK_PORT}/realms/kagent
    clientId: kagent-backend
    secretRef: kagent-enterprise-oidc-secret
    secretKey: clientSecret
EOF
kubectl get deployment kagent-controller -n kagent -o jsonpath='{range .spec.template.spec.containers[*]}{.name}{" "}{end}{"\n"}'
forwards
```

**Verified on 2026-10-12:**

```text
secret/kagent-enterprise-oidc-secret created
Release "kagent" has been upgraded. Happy Helming!
NAME: kagent
STATUS: deployed
REVISION: 2
DESCRIPTION: Upgrade complete
(Helm's release notes omitted)
controller 
deployment "kagent-controller" successfully rolled out
deployment "kagent-ui" successfully rolled out
forwards up: controller 18083, ui 14000
```

> [!WARNING]
> **An empty client secret takes the controller down.** The secrets from the start of this step exist only in the shell that generated them. With an empty `KAGENT_OIDC_CLIENT_SECRET` the Secret is created empty, the upgrade rolls a controller that crash-loops with `OIDC client secret must not be empty`, and `--wait` fails with `Progress deadline exceeded`; the old controller keeps serving meanwhile. If the guard stops you, read the secrets back from the realm Secret below and run the block again. If an empty Secret was already created, delete it first (`kubectl delete secret kagent-enterprise-oidc-secret -n kagent`): the block creates it, and a create fails on an existing Secret.

```bash run id=step-23-read-back-secrets when=manual
REALM=$(kubectl get secret keycloak-realm -n keycloak -o jsonpath='{.data.realm\.json}' | base64 --decode)
export KAGENT_OIDC_CLIENT_SECRET=$(printf '%s' "$REALM" | jq -r '.clients[] | select(.clientId == "kagent-backend") | .secret')
for u in admin writer reader norole; do
  export "KAGENT_$(echo "$u" | tr '[:lower:]' '[:upper:]')_PASSWORD=$(printf '%s' "$REALM" | jq -r --arg u "$u" '.users[] | select(.username == $u) | .credentials[0].value')"
done
```

The controller pod no longer has its `idp` container: the bundled login is gone. The upgrade rolled
the controller, which is why `forwards` runs again.

Scripts now need a Keycloak token, and the realm ships `kagent-cli`, the only client that issues one
without a browser, disabled. Prove that, then enable it deliberately through Keycloak's admin API:

```bash run id=keycloak-enable-kagent-cli
KC="http://keycloak.localhost:${KEYCLOAK_PORT}"
echo -n "token from kagent-cli while disabled: "
curl -sS -X POST "${KC}/realms/kagent/protocol/openid-connect/token" -d grant_type=password -d client_id=kagent-cli \
  -d username=writer --data-urlencode "password=${KAGENT_WRITER_PASSWORD}" | jq -r '.error // "issued"'
ADMIN_TOKEN=$(curl -sS -X POST "${KC}/realms/master/protocol/openid-connect/token" -d grant_type=password \
  -d client_id=admin-cli -d username=admin --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" | jq -r .access_token)
CLI_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/clients?clientId=kagent-cli" | jq -r '.[0].id')
curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/clients/${CLI_ID}" | jq '.enabled = true' \
  | curl -sS -o /dev/null -w 'enable kagent-cli: HTTP %{http_code}\n' -X PUT -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H 'Content-Type: application/json' --data-binary @- "${KC}/admin/realms/kagent/clients/${CLI_ID}"
echo -n "token from kagent-cli once enabled:  "
curl -sS -X POST "${KC}/realms/kagent/protocol/openid-connect/token" -d grant_type=password -d client_id=kagent-cli \
  -d username=writer --data-urlencode "password=${KAGENT_WRITER_PASSWORD}" | jq -r '.error // "issued"'
```

**Verified on 2026-10-12:**

```text
token from kagent-cli while disabled: invalid_client
enable kagent-cli: HTTP 204
token from kagent-cli once enabled:  issued
```

Disabling it is the same call with `enabled` set to `false`; Before production lists it. When you are
done scripting against this cluster:

```bash run id=keycloak-disable-kagent-cli when=manual
KC="http://keycloak.localhost:${KEYCLOAK_PORT}"
ADMIN_TOKEN=$(curl -sS -X POST "${KC}/realms/master/protocol/openid-connect/token" -d grant_type=password \
  -d client_id=admin-cli -d username=admin --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" | jq -r .access_token)
CLI_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/clients?clientId=kagent-cli" | jq -r '.[0].id')
curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/clients/${CLI_ID}" | jq '.enabled = false' \
  | curl -sS -o /dev/null -w 'disable kagent-cli: HTTP %{http_code}\n' -X PUT -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H 'Content-Type: application/json' --data-binary @- "${KC}/admin/realms/kagent/clients/${CLI_ID}"
```

These helpers replace Step 9's: `kagent_token` uses the
`kagent-cli` client's password grant, as the user in `KAGENT_USER` (default `writer`), and
`kagent_send` also prints a refused request's error, whether it comes back as JSON or as a bare
HTTP status:

```bash run id=step-23-helpers
kagent_token() {
  local user=${KAGENT_USER:-writer} pw
  case "$user" in
    admin) pw=$KAGENT_ADMIN_PASSWORD ;; writer) pw=$KAGENT_WRITER_PASSWORD ;;
    reader) pw=$KAGENT_READER_PASSWORD ;; norole) pw=$KAGENT_NOROLE_PASSWORD ;;
  esac
  curl -sS --max-time 10 -X POST "http://keycloak.localhost:${KEYCLOAK_PORT}/realms/kagent/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=kagent-cli -d "username=${user}" --data-urlencode "password=${pw}" \
    | jq -r .access_token
}

# kagent_send <agent> <message> [contextId]
kagent_send() {
  local ctx="" out code body
  [ -n "${3:-}" ] && ctx="\"contextId\":\"$3\","
  out=$(curl -sS --max-time 300 -w '\n%{http_code}' -X POST "http://127.0.0.1:${KAGENT_API_PORT}/agents/kagent/$1" \
    -H "Authorization: Bearer $(kagent_token)" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"SendMessage\",\"params\":{\"message\":{\"messageId\":\"$(openssl rand -hex 8)\",${ctx}\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"$2\"}]}}}")
  code=${out##*$'\n'}; body=${out%$'\n'*}
  printf '%s' "$body" | jq -r 'if .error then "REFUSED\t\(.error.message)" else (.result.task | "\(.status.state)\t\(.contextId)\t\((.artifacts[-1].parts[0].text // .status.message.parts[0].text // "") | gsub("\\s*\n\\s*"; " "))") end' 2>/dev/null \
    || printf 'REFUSED\tHTTP %s %s\n' "$code" "$(printf '%s' "$body" | tr -d '\n' | head -c 120)"
}
```

> [!WARNING]
> **`kagent-cli` is a lab convenience.** A public client with the password grant lets anything that knows a user's password get a token without a browser. It ships disabled for that reason. Enable it for scripts on a lab cluster only, disable or delete it when you are done, and in production give scripts a confidential client with the client credentials grant, or tokens from your identity provider's own tooling.

Prove the bundled login is gone and Keycloak tokens work:

```bash run id=step-23-check
echo -n "bundled login /autoauth/token: "; curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  "http://127.0.0.1:${KAGENT_UI_PORT}/autoauth/token" -H 'Content-Type: application/json' -d '{"user_type":"admin"}'
echo -n "API with no token:             "; curl -sS -o /dev/null -w '%{http_code}\n' -X POST \
  "http://127.0.0.1:${KAGENT_API_PORT}/agents/kagent/assistant" -H 'Content-Type: application/json' -d '{}'
echo -n "writer turn:                   "; kagent_send assistant "Reply with exactly: keycloak token accepted"
```

**Verified on 2026-10-12:**

```text
bundled login /autoauth/token: 405
API with no token:             401
writer turn:                   TASK_STATE_COMPLETED	01a12e65-0b42-78ad-98ef-4b7a91efffef	keycloak token accepted
```

**In the browser.** Open `http://localhost:14000` (or your `KAGENT_UI_PORT`). The UI redirects to
Keycloak at `keycloak.localhost`; sign in as `writer` with `KAGENT_WRITER_PASSWORD`, and the UI
returns signed in, with the agents listed. Sign out returns you to the UI. This was verified on this
release with the same realm and settings; the browser half is not part of the scripted run.

### Step 24: Roles: who can chat and who can only read

*Runtime: kagent.*

The chart maps the token's `Groups` claim to kagent's roles: `admins` to Admin, `writers` to Writer,
`readers` to Reader. A user in none of them is treated as unauthenticated. Send the same message as
each user:

```bash run id=step-24-roles
for user in admin writer reader norole; do
  printf '%-7s ' "$user"; KAGENT_USER=$user kagent_send assistant "Reply with exactly: hello ${user}"
done
```

**Verified on 2026-10-12:**

```text
admin   TASK_STATE_COMPLETED	01a12e65-1020-74b7-9b3c-2efbde6d8a5a	hello admin
writer  TASK_STATE_COMPLETED	01a12e65-132e-7707-9e31-81e71814f2e5	hello writer
reader  REFUSED	permission denied
norole  REFUSED	HTTP 401 Unauthorized
```

| User | Group | Result |
|---|---|---|
| `admin` | `admins` | Chats |
| `writer` | `writers` | Chats |
| `reader` | `readers` | Refused: can open the agent, cannot start or continue a conversation |
| `norole` | none | Refused as unauthenticated |

In the UI, `reader` sees the agent and its page, and sending a message returns "Could not start this
conversation. Not authorized". A conversation belongs to the user who started it: another user
opening its address gets "Session not found".

> [!WARNING]
> **Every signed-in user can see every user's conversation list for an agent.** The UI's chat list asks for all creators' sessions, and on this release every role, `reader` included, is allowed that: it lists other users' conversation IDs, who started them and when. Their contents are protected. Treat who-talks-to-which-agent as visible to everyone with access to the UI.

**What you now have:** the agent holds no key and can reach only what its policy names; MCP tools and
the model both sit behind one gateway that holds their credentials, attributes every token and
enforces a budget; conversation data is readable only by the two components that need it; and every
caller of the UI and API is authenticated, with roles. What you have not done is measure what any of
this costs to run. Scale does that.

## SCALE

Isolate made each conversation its own sandbox. This section is about what that costs: what a
conversation holds while it waits, what it holds while it runs, and how to size the worker pool from
that.

**What you are going to do:** compare Substrate with running agents as pods, watch memory follow
turns in flight on your own cluster, measure what suspended conversations leave behind, size the
worker pool, and change it safely.

**What you will have that you did not have before:** numbers to size a platform with, the method to
re-measure them on your own nodes, and a way to change the worker pool without losing capacity.

The steps you run here make five model calls in total and finish in a few minutes. The larger figures
are reference measurements from a longer run on the same reference environment, labelled as such.

**Verified on:** certification run on kind cluster `agents` (kind 0.32.0, `kindest/node:v1.35.0`), created fresh for it, 2026-10-12 04:27 to 04:36 UTC. Every `run` block from Step 1 to Step 31 was executed verbatim, in document order, in one uninterrupted pass of `auto-build/run.sh`, on the versions in Version support; every output block in this guide comes from that pass.

### Step 25: A pod per conversation, a pod per agent, or Substrate

*No runtime: reference measurements.*

There are two ways to run agents as ordinary pods, and they are not the same comparison:

- **A pod per agent**: one long-lived process serves every conversation with that agent. It is the
  cheapest thing you can run. **It uses less memory than Substrate at every load measured**, because
  it adds almost nothing per conversation. What it gives up is everything Isolate built: all of an
  agent's conversations, for every user, share one process, one memory space and one kernel, and the
  process holds the model key in its environment.
- **A pod per conversation**: the plain-Kubernetes way to get Substrate's isolation, one sandboxed
  pod for each open conversation. It holds its memory whether the conversation is active or waiting
  for someone to reply.

Substrate is the second model without its standing cost: a conversation holds memory only while a
turn is running, and costs storage while it waits.

**Reference measurements.** Measured on 2026-10-11 on the reference environment: one kind node,
Kubernetes 1.35.0, Colima on Apple silicon with 6 vCPU and 12 GiB, the versions in this guide.
Memory is the node's used memory before and after (from `/proc/meminfo`), divided by the number of
units. The pod-per-conversation comparator is one pod of the same kagent runtime, run eight times
under gVisor through a RuntimeClass with the same gVisor build Substrate uses, on a separate
throwaway kind cluster, because Substrate's nodes do not register gVisor as a container runtime. The
same pod under runc is included as the comparator most favourable to pods.

| | Memory per unit | Unit |
|---|---|---|
| Substrate control plane (`ate-system`, pod certificate controller) | 291.8 MiB | Fixed, once per cluster |
| Substrate, a turn in flight | about 50 MiB | Per running turn, released when it ends |
| Substrate, a suspended conversation | 0 | It costs storage instead (Step 27) |
| Pod per conversation, gVisor | 57.6 MiB | Per open conversation, active or not |
| Pod per conversation, runc (weaker isolation) | 18.1 MiB | Per open conversation, active or not |
| Pod per agent, runc | 18.1 MiB | Per agent |

None of the pod figures include a turn's own cost: the kagent runtime on this release will not serve
a turn outside Substrate, so that cost could not be measured, and it can only add to the pod side.
The kagent platform itself (controller, UI, Postgres, ClickHouse, about 1.1 GiB) is needed either way
and is left out of every figure.

**Projected from those measured constants**, at 100 open conversations with one agent:

| Turns in flight | Substrate | Pod per conversation, gVisor | Pod per conversation, runc | Pod per agent |
|---|---|---|---|---|
| 5 | 0.55 GiB | 5.6 GiB, plus turn cost | 1.8 GiB, plus turn cost | 18 to 58 MiB, plus turn cost |
| 10 | 0.80 GiB | 5.6 GiB, plus turn cost | 1.8 GiB, plus turn cost | 18 to 58 MiB, plus turn cost |
| 25 | 1.57 GiB | 5.6 GiB, plus turn cost | 1.8 GiB, plus turn cost | 18 to 58 MiB, plus turn cost |

Against equal isolation, Substrate uses less memory at every load, and the gap grows with every
conversation held open, because waiting costs storage rather than memory. Against runc pods, the
break-even is around 29 turns in flight per 100 open conversations. Against a pod per agent,
Substrate always costs more, and buys isolation per conversation with it.

### Step 26: Memory follows turns in flight

*Runtime: kagent.*

Measure it on your own cluster. These helpers read the worker pods' memory from the node (the
working set of each worker's container, through `crictl`, as the reference run did) and count the
actors running right now:

```bash run id=step-26-helpers
# worker_total: summed working set of the worker containers, in MiB.
worker_total() {
  docker exec "${KIND_CLUSTER_NAME}-control-plane" crictl stats -o json --label io.kubernetes.container.name=ateom \
    | jq '[.stats[].memory.workingSetBytes.value | tonumber] | add / 1048576 | floor'
}

# running_actors: actors in the kagent atespace that are running now.
running_actors() {
  kubectl-ate get actors -a kagent -o json | jq '[.actors[] | select(.status.state == "ACTOR_STATE_RUNNING")] | length'
}
```

Start four conversations at once, each asking for a long enough answer to stay in flight for a few
seconds, and sample while they run. The loop watches the four turns by process ID: the port-forwards
`forwards` started are background jobs in the same shell, so waiting for "no background jobs" would
never end:

```bash run id=step-26-burst
BEFORE=$(worker_total); PEAK=$BEFORE; PEAK_RUNNING=0; TURNS=""
for i in 1 2 3 4; do
  kagent_send assistant "Write about 250 words on the history of the bicycle." >/dev/null &
  TURNS="$TURNS $!"
done
in_flight() { for p in $TURNS; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
while in_flight; do
  M=$(worker_total); R=$(running_actors)
  [ "$M" -gt "$PEAK" ] && PEAK=$M
  [ "$R" -gt "$PEAK_RUNNING" ] && PEAK_RUNNING=$R
done
wait $TURNS
sleep 5
AFTER=$(worker_total)
echo "worker memory before:  ${BEFORE} MiB, 0 turns in flight"
echo "worker memory peak:    ${PEAK} MiB, up to ${PEAK_RUNNING} turns in flight"
echo "worker memory after:   ${AFTER} MiB, running actors now: $(running_actors)"
```

**Verified on 2026-10-12:**

```text
worker memory before:  112 MiB, 0 turns in flight
worker memory peak:    315 MiB, up to 4 turns in flight
worker memory after:   99 MiB, running actors now: 0
```

Memory rises with the turns in flight and falls back when they end. The four conversations are
still there, suspended, and hold no memory now. A sample can miss the very top of the curve, so treat
the peak as a lower bound; the reference run held actors running deliberately and measured about
50 MiB each, flat from 1 to 64.

Those turns also used CPU, which is what actually limits a node. In the reference run, with real
model calls on one worker, the platform's own share of a turn's latency stayed under twice its
single-turn value up to **4 concurrent turns per 6-vCPU node**, and doubled beyond that. Model time
stayed flat; the growth was restore time, consistent with CPU contention (CPU was not sampled
directly). No turn failed at any concurrency up to 32.

### Step 27: What suspended conversations leave behind

*Runtime: kagent. No model calls.*

A suspended conversation holds no memory, but it is not free. It leaves data in three places:

```bash run id=step-27-storage
echo "conversations in Substrate: $(kubectl-ate get actors -a kagent -o json | jq '.actors | length')"
echo "-- conversation snapshots atelet uploaded in the last 15 minutes (uncompressed session data, bytes):"
kubectl logs -n ate-system daemonset/atelet --since=15m \
  | jq -r 'select(.msg == "Compressed zstd upload" and (.object | test("/atespaces/kagent/actors/"))) | .logical_bytes' \
  | sort -n | uniq -c
echo "-- kagent's Postgres, conversation tables:"
kubectl exec -n kagent deploy/kagent-postgresql -- psql -U kagent -d kagent -At -c \
  "select relname || ': ' || pg_size_pretty(pg_total_relation_size(relid)) from pg_statio_user_tables where relname like 'session%' order by relname"
echo "-- actor directories on the node: $(docker exec "${KIND_CLUSTER_NAME}-control-plane" sh -c 'ls /var/lib/ate/actors | wc -l') ($(docker exec "${KIND_CLUSTER_NAME}-control-plane" du -sh /var/lib/ate/actors | cut -f1))"
```

**Verified on 2026-10-12:**

```text
conversations in Substrate: 14
-- conversation snapshots atelet uploaded in the last 15 minutes (uncompressed session data, bytes):
   9 38912
-- kagent's Postgres, conversation tables:
session: 48 kB
session_checkpoint: 40 kB
session_share: 32 kB
session_task: 840 kB
session_task_event: 864 kB
-- actor directories on the node: 18 (724K)
```

Every short conversation reports the same uncompressed size, because the session database grows in
whole pages. There are more actor directories on the node than conversations in Substrate: the
difference is conversations deleted since Step 9, whose directories stay.

| Where | What | Grows |
|---|---|---|
| Snapshot store | The conversation's session data, compressed | One snapshot per conversation, replaced at each turn |
| kagent's Postgres | Every task event of every conversation | With every turn; the larger store |
| The worker node | One directory per actor ever placed there | One per conversation, never removed (Step 14) |

The snapshot store's view is fenced since Step 22, so the figures above are what atelet reports
(uncompressed) rather than the stored objects. **Reference measurements** for short turns, from the
same run as Step 25:

| Turns in the conversation | Snapshot in the store | kagent Postgres |
|---|---|---|
| 1 | 2.3 KB | 8.2 KB |
| 5 | 2.5 KB | 30.0 KB |
| 10 | 3.2 KB | 65.5 KB |
| 20 | 4.5 KB | 136.5 KB |

Plus about 40 KB of node directory per conversation, and 1.09 MB of golden image per agent. Prompt
content dominates real sizes, so treat these as floors: the snapshot grows about 115 bytes and
Postgres about 6.7 KB per short turn.

**Projected from those measured constants:** 1,000 suspended conversations need 63 to 219 MB across
the store, Postgres and node directories, and 10,000 need 0.63 to 2.19 GB, while needing no memory at
all until someone sends a message.

### Step 28: Size the worker pool for concurrent turns

*No runtime: arithmetic, with one reading from your cluster.*

What a node can run at once is set by its CPU, not by how many conversations exist. Read what your
node and workers offer:

```bash run id=step-28-capacity
echo "node CPU: $(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}'), memory: $(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}')"
kubectl-ate get workers
```

**Verified on 2026-10-12:**

```text
node CPU: 6, memory: 12220312Ki
NAME                                   POOL             STATE                 ACTORS   CPU   MEMORY         POD                                     AGE
0deec7ce-237c-419d-a18a-47f98dd9c207   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-ff8dfbd47-dm22t   6m36s
e9e21500-511a-46af-9bfd-0a3ce46fc9f7   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-ff8dfbd47-sr45m   6m35s
```

Each worker advertises the whole node and room for 1,000 actors, and actors request no CPU or
memory, so Substrate will place far more running actors on a worker than its node can serve well.
Nothing in admission stops it; the node's CPU does. Size for turns in flight:

| Input | Reference value |
|---|---|
| Peak turns in flight | Yours to estimate: conversations active at the busiest moment, not conversations open |
| Turns per node before latency doubles | 4 per 6-vCPU node, measured; scale with vCPU as a starting point (**projected**) |
| Memory per turn in flight | about 50 MiB, measured |
| Fixed control plane | 291.8 MiB per cluster, measured |

For 10 turns in flight at the busiest moment: 10 ÷ 4 rounds up to 3 nodes of this size, and memory
is about 0.3 GiB plus 0.5 GiB for the turns, which every node here has many times over. **Projected,
not measured:** that adding nodes adds turns at that rate has not been tested, and two workers on one
node do not add turns, because they share its CPU.

Two settings change how the pool behaves under that load:

- **Worker resources** (`substrateWorkerPool.template.resources`). Requests are the only way to
  reserve node capacity for workers; without them, nothing reserves room for running actors. Limits
  become a hard ceiling for everything the worker runs: at about 50 MiB per running actor, a 2 GiB
  limit would be reached near 40 running actors (**projected**; what happens at the ceiling was not
  tested).
- **Replicas.** At least one worker per node you want to use, and enough that a worker restarting
  does not take your only capacity with it.

### Step 29: Change the worker pool without losing capacity

*Runtime: kagent. One model call.*

The worker Deployment that Substrate creates for a pool rolls out with `maxSurge: 0`: it removes an
old worker before starting its replacement. So any change that makes workers roll, such as new
resources, takes capacity away first, and if the replacement cannot schedule (a request larger than
the node has free), the pool stays a worker short. The WorkerPool's status does not say why; only the
Pending pod's event does.

Check the node's headroom before changing worker resources:

```bash run id=step-29-headroom
kubectl describe node | sed -n '/Allocated resources/,/Events/p' | sed '$d'
```

**Verified on 2026-10-12:**

```text
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                5060m (84%)   12100m (201%)
  memory             5954Mi (49%)  17286Mi (144%)
  ephemeral-storage  50Mi (0%)     0 (0%)
  hugepages-1Gi      0 (0%)        0 (0%)
  hugepages-2Mi      0 (0%)        0 (0%)
  hugepages-32Mi     0 (0%)        0 (0%)
  hugepages-64Ki     0 (0%)        0 (0%)
```

A worker's new request must fit inside what is not yet requested, or the rollout leaves a worker
Pending. On the node above, 84% of the CPU is already requested, so about 940m is free: a worker
request of 1 CPU would leave its replacement Pending, with one worker already gone.

The change that never removes capacity is adding a worker. Raise the replica count, wait for the new
worker, and check it serves:

```bash run id=workerpool-scale-up
helm upgrade kagent \
  oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise \
  --version ${KAGENT_VERSION} \
  --namespace kagent \
  --reuse-values \
  --set substrateWorkerPool.replicas=3 \
  --wait --timeout 10m >/dev/null
for i in $(seq 1 60); do
  [ "$(kubectl get workerpool kagent-default -n kagent -o jsonpath='{.status.readyReplicas}')" = 3 ] && break
  sleep 2
done
kubectl get workerpool -n kagent
kubectl-ate get workers
forwards
kagent_send assistant "Reply with exactly: three workers"
```

**Verified on 2026-10-12:**

```text
NAME             DESIRED   REPLICAS   READY   AGE
kagent-default   3         3          3       7m13s
NAME                                   POOL             STATE                 ACTORS   CPU   MEMORY         POD                                     AGE
0deec7ce-237c-419d-a18a-47f98dd9c207   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-ff8dfbd47-dm22t   6m41s
146cb7f1-18c0-4fd0-a88d-ae4e9aa9c395   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-ff8dfbd47-nh6lv   0s
e9e21500-511a-46af-9bfd-0a3ce46fc9f7   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-ff8dfbd47-sr45m   6m40s
deployment "kagent-controller" successfully rolled out
deployment "kagent-ui" successfully rolled out
forwards up: controller 18083, ui 14000
TASK_STATE_COMPLETED	01a12e65-5e5a-79e7-9bb3-a13d08ffb1af	three workers
```

`--reuse-values` keeps everything earlier steps set, including the OIDC issuer; without it, Helm
would reset them to the chart's defaults. Make resource changes the same way: add a worker first, so
the rollout's missing worker is one you can spare, then change the resources, then remove the extra
worker.

**What you now have:** a measured picture of what conversations cost on this platform: memory per
turn in flight, storage per conversation waiting, a CPU limit per node, and a pool you can grow
without a gap in service.

## VALIDATE

Everything above was proved one control at a time. This section sends one conversation through all
of them and checks each result against the step that set it up. If something breaks later, this is
the section to run first.

**What you are going to do:** sign in, run one conversation that calls a model and an MCP tool, then
check the conversation from every side: its sandbox, its credentials, its egress, the gateway, the
MCP server, the fences, and another user's access.

**What you will have that you did not have before:** one pass that tells you whether the whole
platform still does what each step said it would, and which step to go back to when it does not.

**Verified on:** certification run on kind cluster `agents` (kind 0.32.0, `kindest/node:v1.35.0`), created fresh for it, 2026-10-12 04:27 to 04:36 UTC. Every `run` block from Step 1 to Step 31 was executed verbatim, in document order, in one uninterrupted pass of `auto-build/run.sh`, on the versions in Version support; every output block in this guide comes from that pass.

### Step 30: Drive one conversation through every control

*Runtime: kagent (agent `deployment-helper`, which calls the model and the MCP tool). One model call.*

`record` prints one check: the step that set the control up, what was checked, what was observed, and
whether that matches what the step said. It also keeps the line for Step 31:

```bash run id=step-30-helpers
# record <step> <what was checked> <observed> <expected: an extended regular expression>
record() {
  local status=FAIL
  printf '%s' "$3" | grep -qE -- "$4" && status=PASS
  VALIDATE_RESULTS="${VALIDATE_RESULTS:-}${status}|$1|$2|$3"$'\n'
  printf '%-4s  %-12s  %s: %s\n' "$status" "$1" "$2" "$3"
}
```

**Who is calling.** The forwards come up first, because anything that restarted the controller since
you last used them has taken them down. Keycloak issues the token, and the controller refuses a call
without one:

```bash run id=step-30-identity
forwards >/dev/null
VALIDATE_RESULTS=""
TOKEN=$(kagent_token)
record "Step 23" "Keycloak token for writer" "$([ -n "$TOKEN" ] && [ "$TOKEN" != null ] && echo issued || echo none)" '^issued$'
record "Step 23" "API call with no token" "HTTP $(curl -sS -o /dev/null -w '%{http_code}' -X POST \
  "http://127.0.0.1:${KAGENT_API_PORT}/agents/kagent/deployment-helper" -H 'Content-Type: application/json' -d '{}')" '^HTTP 401$'
```

**Verified on 2026-10-12:**

```text
PASS  Step 23       Keycloak token for writer: issued
PASS  Step 23       API call with no token: HTTP 401
```

**The conversation.** One turn that needs both the model and the tool:

```bash run id=step-30-conversation
TURN=$(kagent_send deployment-helper "What is the deployment code for the service billing? Use the tool.")
export VALIDATE_CONV=$(echo "$TURN" | cut -f2)
record "Steps 8, 20" "Turn using the model and the MCP tool" "$(echo "$TURN" | cut -f1,3 | tr '\t\n' '  ')" 'TASK_STATE_COMPLETED.*K7-teal-otter-0429'
wait_suspended "$VALIDATE_CONV" >/dev/null
record "Steps 10, 11" "First restore of the conversation's actor" "$(actor_events "$VALIDATE_CONV" | head -1 | cut -f2,3 | tr '\t' ' ')" '^Restore timing breakdown golden/full$'
record "Step 11" "Actor state after the turn" "$(kubectl-ate get actor "session-${VALIDATE_CONV}" -a kagent -o json | jq -r .status.state)" '^ACTOR_STATE_SUSPENDED$'
```

**Verified on 2026-10-12:**

```text
PASS  Steps 8, 20   Turn using the model and the MCP tool: TASK_STATE_COMPLETED The deployment code for the billing service is **K7-teal-otter-0429**. 
PASS  Steps 10, 11  First restore of the conversation's actor: Restore timing breakdown golden/full
PASS  Step 11       Actor state after the turn: ACTOR_STATE_SUSPENDED
```

**Inside the sandbox.** Resume the actor and look:

```bash run id=step-30-sandbox
kubectl-ate resume actor "session-${VALIDATE_CONV}" -a kagent >/dev/null
record "Step 16" "Kernel the agent sees" "$(sandbox_exec "$VALIDATE_CONV" uname -r)" 'gvisor'
record "Step 18" "Model credential the agent holds" "$(sandbox_exec "$VALIDATE_CONV" cat /proc/1/environ | tr '\0' '\n' | grep '^ANTHROPIC_API_KEY=')" '^ANTHROPIC_API_KEY=kagent-credential-injected$'
record "Step 18" "Consumer key in the sandbox's filesystem" "$(sandbox_exec "$VALIDATE_CONV" tar -cf - --exclude=./proc --exclude=./sys -C / . \
  | LC_ALL=C grep -a -c -F "$AGENT_CONSUMER_KEY" || true) occurrences" '^0 occurrences$'
record "Step 19" "A destination outside the egress policy" "$(sandbox_exec "$VALIDATE_CONV" wget -T 10 -O /dev/null https://example.com/ | grep -o 'HTTP/1.1 [0-9]* [A-Za-z]*' | head -1)" '403 Forbidden'
kubectl-ate suspend actor "session-${VALIDATE_CONV}" -a kagent >/dev/null
```

**Verified on 2026-10-12:**

```text
PASS  Step 16       Kernel the agent sees: 4.19.0-gvisor
PASS  Step 18       Model credential the agent holds: ANTHROPIC_API_KEY=kagent-credential-injected
PASS  Step 18       Consumer key in the sandbox's filesystem: 0 occurrences
PASS  Step 19       A destination outside the egress policy: HTTP/1.1 403 Forbidden
```

**Where the calls went.** The gateway's record of the model call, its metrics, its budget policy, and
the MCP server's record of the tool call:

```bash run id=step-30-gateway
EGRESS_IP=$(kubectl get pod -n ate-system -l app=atenet-egress -o jsonpath='{.items[0].status.podIP}')
GATEWAY_IP=$(kubectl get pod -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy -o jsonpath='{.items[0].status.podIP}')
record "Steps 6, 7, 9" "Model call at the gateway, from Substrate egress" "$(kubectl logs -n agentgateway-system deployment/agentgateway-proxy --since=10m \
  | grep 'route=agentgateway-system/anthropic-messages' | grep "src.addr=${EGRESS_IP}:" | tail -1 | grep -oE 'http.status=[0-9]+')" '^http.status=200$'
record "Step 20" "Tool call at the MCP server: source, credential" "$(kubectl logs -n mcp-tools deployment/deployment-codes \
  | jq -r 'select(.rpc == "tools/call") | "\(.src) \(.auth)"' | tail -1)" "^${GATEWAY_IP} bearer-match$"
kubectl port-forward --address 127.0.0.1 -n agentgateway-system deployment/agentgateway-proxy 18082:15020 >/dev/null 2>&1 &
PF=$!; sleep 3
if kill -0 $PF 2>/dev/null; then
  ATTRIBUTED=$(curl -sS http://127.0.0.1:18082/metrics | grep '^agentgateway_gen_ai_client_token_usage_sum' | grep -c 'team="team-agents"' || true)
  kill $PF; wait $PF 2>/dev/null || true
else
  ATTRIBUTED="port-forward on 18082 did not start"
fi
record "Step 21" "Token metric series attributed to team-agents" "${ATTRIBUTED}" '^[1-9][0-9]*$'
record "Step 21" "Budget enforcement policy" "$(kubectl get enterpriseagentgatewaypolicy llm-budget-enforcement -n agentgateway-system \
  -o jsonpath='{range .status.ancestors[*].conditions[*]}{.type}={.status} {end}')" 'Accepted=True.*Attached=True'
```

**Verified on 2026-10-12:**

```text
PASS  Steps 6, 7, 9  Model call at the gateway, from Substrate egress: http.status=200
PASS  Step 20       Tool call at the MCP server: source, credential: 10.244.0.27 bearer-match
PASS  Step 21       Token metric series attributed to team-agents: 4
PASS  Step 21       Budget enforcement policy: Accepted=True Attached=True
```

**The fences and the other user.** A pod that is not supposed to reach the gateway or the snapshot
store, and a reader trying to continue the writer's conversation:

```bash run id=step-30-fences
record "Step 7" "Another pod reaching the gateway" "$(kubectl run validate-fence -n default --rm -i --restart=Never --image=busybox:1.36 --quiet -- \
  sh -c 'wget -T 8 -O /dev/null http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/messages 2>&1 | tail -1' < /dev/null)" 'timed out'
record "Step 22" "Another pod reaching the snapshot store" "$(snapshot_ls "kagent/" | tail -1)" '[Tt]imeout'
record "Step 24" "Reader continuing the writer's conversation" "$(KAGENT_USER=reader kagent_send deployment-helper "hello" "$VALIDATE_CONV" | tr '\t' ' ')" '^REFUSED'
```

**Verified on 2026-10-12:**

```text
PASS  Step 7        Another pod reaching the gateway: wget: download timed out
PASS  Step 22       Another pod reaching the snapshot store: Connect timeout on endpoint URL: "http://rustfs.ate-system.svc:9000/ate-snapshots?list-type=2&prefix=kagent%2F&encoding-type=url"
PASS  Step 24       Reader continuing the writer's conversation: REFUSED permission denied
```

### Step 31: Map each result to the step that set it

```bash run id=step-31-summary
printf '%s' "$VALIDATE_RESULTS" | awk -F'|' 'NF >= 3 {printf "%-4s  set in %-12s  %s\n", $1, $2, $3}'
FAILED=$(printf '%s' "$VALIDATE_RESULTS" | grep -c '^FAIL' || true)
echo "checks: $(printf '%s' "$VALIDATE_RESULTS" | grep -c '|' || true), failed: ${FAILED}"
```

**Verified on 2026-10-12:**

```text
PASS  set in Step 23       Keycloak token for writer
PASS  set in Step 23       API call with no token
PASS  set in Steps 8, 20   Turn using the model and the MCP tool
PASS  set in Steps 10, 11  First restore of the conversation's actor
PASS  set in Step 11       Actor state after the turn
PASS  set in Step 16       Kernel the agent sees
PASS  set in Step 18       Model credential the agent holds
PASS  set in Step 18       Consumer key in the sandbox's filesystem
PASS  set in Step 19       A destination outside the egress policy
PASS  set in Steps 6, 7, 9  Model call at the gateway, from Substrate egress
PASS  set in Step 20       Tool call at the MCP server: source, credential
PASS  set in Step 21       Token metric series attributed to team-agents
PASS  set in Step 21       Budget enforcement policy
PASS  set in Step 7        Another pod reaching the gateway
PASS  set in Step 22       Another pod reaching the snapshot store
PASS  set in Step 24       Reader continuing the writer's conversation
checks: 16, failed: 0
```

Every check names the step that set it up, so a `FAIL` sends you back to one place. Read them in the
order a turn passes through the platform:

| Order | Control | Set in | Checked by |
|---|---|---|---|
| 1 | The caller signs in to Keycloak and the controller verifies the token | Step 23 | Keycloak token, API call with no token |
| 2 | The caller's role allows the conversation | Step 24 | Reader continuing the writer's conversation |
| 3 | Substrate restores the conversation's actor from the agent's golden image | Steps 10, 11 | First restore |
| 4 | The agent runs in its own gVisor sandbox | Step 16 | Kernel the agent sees |
| 5 | The agent holds a placeholder, not a key | Step 18 | Model credential, consumer key in the filesystem |
| 6 | Substrate's egress gateway allows only the destinations in the policy | Step 19 | A destination outside the policy |
| 7 | Substrate's egress gateway injects the consumer key and sends the call to the enterprise gateway, which nothing else can reach | Steps 6, 7, 9 | Model call at the gateway, another pod reaching the gateway |
| 8 | The enterprise gateway attributes the tokens and enforces the team's budget | Step 21 | Token metrics, budget policy |
| 9 | Tool calls reach the MCP server through the gateway, with the server's credential added there | Step 20 | Tool call at the MCP server |
| 10 | When the turn ends, the conversation is checkpointed to the fenced snapshot store and suspended | Steps 11, 22 | Actor state after the turn, another pod reaching the store |

### What you built

A platform that runs agents the way a cluster runs any shared service, with the per-conversation
isolation an agent needs:

- **kagent** declares agents as Kubernetes resources and turns each conversation into a Substrate
  actor. Two runtimes, the kagent ADK and Claude Code, behind the same declaration.
- **Agent Substrate** runs each conversation in its own gVisor sandbox on a shared pool of workers,
  restores it from a warm snapshot when a message arrives, and suspends it when the turn ends, so a
  waiting conversation holds no memory.
- **Every credential stays outside the agent.** Substrate's egress gateway injects the consumer key
  on the way out, and the actor can reach only the destinations kagent compiled into its policy.
- **Solo Enterprise for agentgateway** is the one path to the model and to MCP tools: it holds the
  provider key and the tool server's credential, authenticates each team's consumer key, attributes
  every token and enforces budgets, and nothing else in the cluster can reach it.
- **Conversation data** sits in a snapshot store only atelet and ate-api can reach, under credentials
  you generated.
- **Keycloak** authenticates every caller of the UI and API, and its groups decide who can chat and
  who can only read.

What it does not do yet is in Before production.

## Before production

Each item is a limit of this release that you can plan for, with the step that shows it.

- **Disable or delete the `kagent-cli` client.** It issues tokens by password without a browser, for
  scripts. Disable it once scripting is done (Step 23 has the command), and give production scripts
  a confidential client with the client credentials grant.
- **Treat the snapshot store as holding every conversation in readable form.** It is compressed, not
  encrypted. Keep the NetworkPolicy from Step 22, keep the credentials out of anything you commit,
  and if you use an external store, turn on the bucket's default encryption. An external store can be
  wired for atelet but not for ate-api through the chart (Steps 13 and 22).
- **Rotate the CA pools before they expire.** They are valid for one year from Step 4 and nothing
  rotates them; when they expire, nothing issued from them validates. Rotation replaces the pools and
  every trust root issued from them, and restarts every Substrate component, the workers and the
  controller; the order matters (Attachment C.10). Verified on this release: new conversations and
  conversations suspended before the rotation both work after it, with their context.
- **Restart the worker pool after a node restarts.** Turns on a restarted node are refused until its
  workers are restarted and registered again (Attachment C.23).
- **Plan node disk and inodes for actor directories.** Every conversation ever placed on a node
  leaves a directory there, about 40 KB, and nothing removes them (Steps 14 and 27).
- **Keep CPU headroom for worker rollouts.** A worker pool rollout removes a worker before starting
  its replacement; add a worker before changing worker resources (Step 29).
- **Restrict access to the `kagent` namespace.** The kagent controller holds the model key and MCP
  header values in its process (Step 18), and the gateway NetworkPolicy admits the controller by
  label, so anyone who can create pods there with its labels can reach the gateway (Step 7).
- **Keep the hop from Substrate's egress to the enterprise gateway inside the cluster.** It is plain
  HTTP: an `https://` base URL to a private certificate fails, because Substrate's egress trusts only
  public CAs (Step 8).
- **Budget and attribute per key.** Spend is attributed to the consumer key's user and group, not to
  the person in the conversation, so issue keys per team or per agent (Step 21).
- **Expect a blocked budget to look like a failed turn.** The runtime retries a `429` three times,
  each counted as a request, then fails the turn with the gateway's error (Step 21).
- **Treat who-talks-to-which-agent as visible to every signed-in user.** Any role, reader included,
  can list every user's conversation IDs for an agent; contents stay private (Step 24).
- **Delete an agent's conversations when you retire it.** Deleting the `Agent` leaves its template
  and golden image in place while any conversation exists (Step 14).
- **Use gVisor.** It is the sandbox verified here; Firecracker was not tested on this release.
