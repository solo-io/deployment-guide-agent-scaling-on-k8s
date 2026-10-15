# Deployment Guide for Operating, Isolating, and Scaling Agent Workloads on Kubernetes

**Updated:** October 14th, 2026

**Certified against:** kagent-enterprise 1.0.0-alpha10, Agent Substrate (substrate-enterprise) 0.5.0-alpha3-e492046, Solo Enterprise for agentgateway v2026.7.1

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
  and a pod holds its memory reservation and CPU request the whole time. A session is a conversation
  tied to a directory, with its own independent context window. A pod per open session with the
  same isolation holds about 60 MiB whether anything is happening or not. SCALE measures it against
  Substrate, where memory follows the turns actually running and an idle session costs storage
  instead.
- **The model key lives in the agent.** The usual setup puts the provider key in the agent's
  environment, where anything that can read the process can read the key.
- **Every agent calls the provider directly.** There is no single place to authenticate agents,
  enforce a budget, or see which team spent what.
- **Agents share a kernel.** Containers on one node share the host kernel, so packing agents from
  different teams onto a node means trusting every one of them with it.
- **The UI and API are open by default.** On this release the bundled login issues an admin token
  to anyone who asks.

## What you will build

- kagent and Agent Substrate on a kind cluster: each session is its own actor, restored from
  a warm snapshot when a message arrives and suspended when the turn ends
- A gVisor sandbox per session, on a shared pool of worker pods
- Model credentials injected on the way out, so the agent only ever holds a placeholder
- Solo Enterprise for agentgateway in front of every model call: one consumer key per team,
  budgets and cost attribution, and nothing else in the cluster able to reach it
- MCP tools reached through the same gateway
- The UI and API behind Keycloak, with roles that decide who can chat and who can only read
- A measured answer to what a session costs, idle and running

## How this guide is organized

**Up and Running** installs everything and ends with one agent answering, its model call verified
as having passed through the enterprise gateway. Nothing else works until this does.

**Operate** follows one session through its life: how an agent becomes actors, where context
is kept between turns, how to inspect and act on actors, and what deleting one leaves behind.

**Isolate** covers what keeps sessions, credentials and users apart: the sandbox, credential
injection, the egress allowlist, MCP tools through the gateway, budgets, the snapshot store, and
Keycloak in front of the UI and API.

**Scale** compares a pod per session with Substrate and sizes the worker pool from the numbers.

**Validate** sends one session through every control and maps each result to the step that
set it.

**The order matters.** Isolate closes things Up and Running leaves open, in particular the bundled
login, so do not expose this cluster to anyone until Isolate is done.

## Version support

kagent-enterprise and Agent Substrate are pre-release. This guide is pinned to one tested set, and
every version, chart and image below is part of that set:

| Component | Version |
|---|---|
| kagent-enterprise (CRD and controller charts) | 1.0.0-alpha10, built from kagent v1.0.0-alpha13 |
| Agent Substrate (`substrate-crds`, `substrate-podcert` and `substrate` charts, worker image) | 0.5.0-alpha3-e492046 |
| kubectl-ate | v0.5.0-alpha2 |
| kagent runtime images (`golang-adk`, `claude-harness`) | 1.0.0-alpha13, pinned by digest |
| PostgreSQL | 18.6 (`postgres:18.6-alpine3.23`), pinned by digest |
| Solo Enterprise for agentgateway | v2026.7.1 |
| Kubernetes | 1.35.0 on kind 0.32.0 |

Do not mix versions across this set. The three Substrate charts and the worker image come from one
Substrate release, kubectl-ate from the open-source Substrate release it is built on, and the runtime
images are the ones this kagent release pins.

**Fresh install only.** This guide installs this set on a new cluster. It does not cover upgrading
an earlier release in place: the 1.0.0-alpha8 charts deployed PostgreSQL and carried Substrate's
CRDs, and the 1.0.0-alpha10 charts do neither. An in-place upgrade was not tested.

## Environment setup

Run this first, in every new shell you paste this guide's blocks into:

```bash run id=shell-setup
if [ -n "${ZSH_VERSION:-}" ]; then setopt interactive_comments nobanghist; fi
if [ -n "${BASH_VERSION:-}" ]; then set +H; fi
```

- `interactive_comments`: an interactive zsh does not treat `#` as a comment unless this is set, so
  every comment line in a pasted block fails, and one containing `<` or `>` is a parse error.
- `nobanghist` (zsh) and `set +H` (bash): an interactive shell expands `!` inside double quotes as a
  history reference, which rewrites or rejects any line that contains one.

Then set these. Every command below uses them.

```bash run id=environment-setup-env
# Pinned versions
export KAGENT_VERSION=1.0.0-alpha10
export SUBSTRATE_VERSION=0.5.0-alpha3-e492046
export KUBECTL_ATE_VERSION=v0.5.0-alpha2
export AGENT_GATEWAY_VERSION=v2026.7.1
export GATEWAY_API_VERSION=v1.6.1

# The cluster. The node image is pinned by digest.
export KIND_CLUSTER_NAME=${KIND_CLUSTER_NAME:-agents}
export KIND_NODE_IMAGE=kindest/node:v1.35.0@sha256:4613778f3cfcd10e615029370f5786704559103cf27bef934597ba562b269661

# The worker image Substrate runs sandboxes on, and the agent runtime images.
# Substrate refuses an image that is not pinned: a changed image invalidates snapshots.
export WORKER_IMAGE=us-docker.pkg.dev/solo-public/substrate-enterprise/ateom-gvisor:v0.5.0-alpha3-e492046@sha256:b06f73fa23541d05f866ec250fa9144bfa8ff6753cad7b0c15d6ac4af71cac50
export RUNTIME_IMAGE=ghcr.io/kagent-dev/kagent/golang-adk:1.0.0-alpha13@sha256:ae01c3a6d7e0ed2e044253a26abbfb1a9426f3176363842ca9a954762c274d36
# The Claude Code runtime, used in Step 15. Same kagent release as RUNTIME_IMAGE.
export CLAUDE_HARNESS_IMAGE=ghcr.io/kagent-dev/kagent/claude-harness:1.0.0-alpha13@sha256:ceaf7caa7366b96c11cb85ad0bad435a35fcd2704c657b895ee3e73978045db8

# The database kagent and Substrate share, Step 4.
export POSTGRES_IMAGE=postgres:18.6-alpine3.23@sha256:885cf05d376c7cf27afef02073e6bdac3841252537f16e244fd1c1e6a7c99fb1

# The snapshot store's volume, Step 5. Sized there; it cannot grow later on kind.
export SNAPSHOT_STORE_SIZE=2Gi

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

# Where kubectl-ate is installed in Step 3. Must be on your PATH.
export ATE_BIN_DIR=${ATE_BIN_DIR:-$HOME/.local/bin}

# Where Step 23 saves the passwords of the UI users it generates (admin, writer, reader).
export KAGENT_UI_CREDENTIALS_FILE=${KAGENT_UI_CREDENTIALS_FILE:-$HOME/.kagent-ui-credentials}

# Local ports for the port-forwards in Step 9.
export KAGENT_API_PORT=${KAGENT_API_PORT:-18083}
export KAGENT_UI_PORT=${KAGENT_UI_PORT:-14000}
```

### What you need before you start

| **Requirement** | **Needed for** | **Notes** |
|---|---|---|
| Docker on a machine with 6 CPU and 12 GiB for it | Everything | The reference environment is Colima on macOS (`colima start --cpu 6 --memory 12`). The full stack settles at about 5 GiB on the node. |
| `kind` 0.32.0, `kubectl`, `helm`, `jq`, `curl`, `openssl` | Everything | |
| `zstd` | Step 17 | Decompresses a snapshot to search it |
| kagent-enterprise license key | Step 5 | |
| Solo Enterprise for agentgateway license key | Steps 3 and 6 | Substrate's chart requires one too |
| Anthropic API key | Step 6 | It is stored once, in the gateway. Nothing else holds it. |
| Egress from the cluster to `ghcr.io`, `us-docker.pkg.dev`, `docker.io` and `api.anthropic.com` | Everything | Images, and the model calls |
| Access from your machine to `github.com` and `raw.githubusercontent.com` | Steps 2, 3 and 4 | The Gateway API CRDs and kubectl-ate from GitHub releases, and PostgreSQL's manifest and setup SQL from the public kagent and Substrate repositories, each at a pinned version; kubectl-ate and the PostgreSQL files are checked against a sha256 |
| `kubectl-ate` | Step 3 | Downloaded in Step 3 |

> [!WARNING]
> Use `curl -sS` rather than `curl -s` **throughout this guide.** The checks in Step 9 go through a port-forward, and a port-forward that has died prints nothing and exits 7. An empty result then looks like a pass. `-S` keeps curl quiet on success and makes it say so on failure.
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
  pkill -f "kubectl --context kind-${KIND_CLUSTER_NAME} port-forward .*-n kagent " 2>/dev/null || true
  kubectl --context "kind-${KIND_CLUSTER_NAME}" rollout status deployment/kagent-controller -n kagent --timeout=120s
  kubectl --context "kind-${KIND_CLUSTER_NAME}" rollout status deployment/kagent-ui -n kagent --timeout=120s
  kubectl --context "kind-${KIND_CLUSTER_NAME}" port-forward --address 127.0.0.1 -n kagent deployment/kagent-controller ${KAGENT_API_PORT}:8083 >/dev/null 2>&1 &
  kubectl --context "kind-${KIND_CLUSTER_NAME}" port-forward --address 127.0.0.1 -n kagent service/kagent-ui ${KAGENT_UI_PORT}:8080 >/dev/null 2>&1 &
  sleep 2
  echo "forwards up: controller ${KAGENT_API_PORT}, ui ${KAGENT_UI_PORT}"
}

# stop_forwards: close every port-forward this guide opened to this cluster, and say which ports it freed.
stop_forwards() {
  local pat="kubectl --context kind-${KIND_CLUSTER_NAME} port-forward " ports
  ports=$(pgrep -f "$pat" | while read -r p; do ps -o command= -p "$p"; done \
    | grep -oE ' [0-9]+:[0-9]+' | cut -d: -f1 | tr -d ' ' | sort -n | tr '\n' ' ')
  if pkill -f "$pat"; then
    echo "closed the port-forwards to kind-${KIND_CLUSTER_NAME}; ports freed: ${ports}"
  else
    echo "no port-forwards open to kind-${KIND_CLUSTER_NAME}"
  fi
}
```

Every port-forward in this guide names this cluster's context (`kind-${KIND_CLUSTER_NAME}`), and
`forwards` closes only the ones to its `kagent` namespace, so a forward you have open to another
cluster is never touched. The `|| true` matters on a first run: `pkill` exits non-zero when nothing
matched. `stop_forwards` closes all of them, Keycloak's and any gateway forward left running
included, when you are done with this cluster or switching to another.

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
sessions each run in their own sandbox, and whose every model call is authenticated and
recorded by one gateway.

**Verified on:** two certification runs, each on a kind cluster created fresh for it (kind 0.32.0, `kindest/node:v1.35.0`), beside one other cluster on the same Docker host, 2026-10-15: `certz` under zsh, 16:25 to 16:34 UTC, and `certb` under bash, 16:34 to 16:43 UTC. In each, every `run` block from Step 1 to Step 31 was executed verbatim, in document order, in one uninterrupted pass of `auto-build/run.sh`, from an empty directory outside the repository, on the versions in Version support. Every output block in this guide comes from the bash pass.

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

**Verified on 2026-10-15:**

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
at 0 or a missing resource here means nothing from Step 4 on finishes: PostgreSQL and every
Substrate pod wait for a certificate that nothing can issue.

### Step 2: Install the CRDs

Substrate's CRDs (`WorkerPool`, `SandboxConfig`, `EnterpriseSubstrateClusterTrustBundle`) come
from their own chart, `substrate-crds`, released in `ate-system` beside the rest of Substrate. The
kagent-enterprise CRD chart carries only kagent's. The Gateway API CRDs are for the enterprise
gateway in Step 6.

```bash run id=helm-substrate-crds
helm upgrade -i substrate-crds \
  oci://us-docker.pkg.dev/solo-public/enterprise-substrate-helm/substrate-crds \
  --version ${SUBSTRATE_VERSION} \
  --namespace ate-system --create-namespace
```

```bash run id=helm-kagent-crds
helm upgrade -i kagent-crds \
  oci://us-docker.pkg.dev/solo-public/kagent-enterprise-helm/charts/kagent-enterprise-crds \
  --version ${KAGENT_VERSION} \
  --namespace kagent --create-namespace
```

The kagent CRD chart no longer has a `substrate.enabled` value. Setting it is accepted and changes
nothing, so an install that relies on it gets no Substrate CRDs and fails at Step 5.

```bash run id=gateway-api-crds
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml
```

Check what arrived:

```bash run id=step-2-crds
kubectl get crd -o name | grep -E 'kagent\.dev|ate\.dev|ate\.solo\.io' | sort
```

**Verified on 2026-10-15:**

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
(ate-api), not as Kubernetes objects, which is why Step 3 installs a CLI to see them.

The CRD chart version must equal the controller chart version in Step 5. Both come from
`KAGENT_VERSION`.

### Step 3: Create Substrate's certificate authorities and its certificate controller

Substrate signs every certificate it issues from six pools: three for its pod certificate
controller (service DNS names, pod identities, and PostgreSQL logins), and three in `ate-system`
(actor identity certificates, actor identity tokens, and the egress gateway's interception CA).
Helm creates none of them. `kubectl-ate` does.

Install kubectl-ate and check it against the release's published digest:

```bash run id=kubectl-ate-install
ATE_OS=$(uname -s | tr '[:upper:]' '[:lower:]')
ATE_ARCH=$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/')
mkdir -p "$ATE_BIN_DIR"
curl -sSLf -o "$ATE_BIN_DIR/kubectl-ate" \
  "https://github.com/kagent-dev/substrate/releases/download/${KUBECTL_ATE_VERSION}/kubectl-ate-${ATE_OS}-${ATE_ARCH}"
chmod +x "$ATE_BIN_DIR/kubectl-ate"
case "${ATE_OS}-${ATE_ARCH}" in
  darwin-arm64) ATE_SHA=b560783f15e11dff1c70bc28097f818e65f21fb230cd91b7b83c24a3bd7376c5 ;;
  darwin-amd64) ATE_SHA=1dd5fbcda94a67916938d5e8eb782d1c2131f435f4541dff4b84e7bcdfef7ea4 ;;
  linux-arm64)  ATE_SHA=ad22475c766af0b19db2d73bfab308495d8fb910bfa5daa5a91365fc53716616 ;;
  linux-amd64)  ATE_SHA=149d1dadc31dfe28a2d042bb66abd4f8e3faf6e784e4f15d7019f5a9b01548de ;;
esac
echo "${ATE_SHA}  $ATE_BIN_DIR/kubectl-ate" | shasum -a 256 -c -
```

`shasum` prints the binary's path followed by `OK`. Anything else, stop: the download is not the release this guide was tested with.

The binary has no `version` command, so the URL and the digest are the only record of which
release you have.

Create the pools. `make-ca-pool` and `make-jwt-pool` fail if the Secret already exists, so each is
skipped when it is already there and the block is safe to re-run:

```bash run id=substrate-pools
kubectl get namespace podcertificate-controller-system >/dev/null 2>&1 \
  || kubectl create namespace podcertificate-controller-system
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
ca_pool  postgres-ca-pool     podcertificate-controller-system
jwt_pool actor-id-jwt-pool    ate-system
ca_pool  actor-id-ca-pool     ate-system
ca_pool  egress-mitm-ca-pool  ate-system --key-type=ECDSAP256
```

**Verified on 2026-10-15:**

```text
namespace/podcertificate-controller-system created
Successfully created CA pool secret podcertificate-controller-system/service-dns-ca-pool
Successfully created CA pool secret podcertificate-controller-system/pod-identity-ca-pool
Successfully created CA pool secret podcertificate-controller-system/postgres-ca-pool
Successfully created JWT authority pool secret ate-system/actor-id-jwt-pool with ES256 key 1
Successfully created CA pool secret ate-system/actor-id-ca-pool
Successfully created CA pool secret ate-system/egress-mitm-ca-pool
```

ate-api verifies actor identity certificates against the actor identity root, which it reads as
plain PEM from its own Secret:

```bash run id=substrate-actor-id-ca-certs
kubectl delete secret actor-id-ca-certs -n ate-system --ignore-not-found
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
kubectl delete configmap ate-api-authentication -n ate-system --ignore-not-found
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

Install the pod certificate controller. It issues every Substrate pod's certificate from the pools
above, and it also issues database logins: `postgresClients` maps a ServiceAccount to a PostgreSQL
user, so a pod running as `kagent/kagent-controller` gets a certificate that PostgreSQL in Step 4
accepts as `kagent_user`. Substrate's own logins (ate-api, as `substrate_owner_user` and
`substrate_readwrite_user`) are mapped by the chart's defaults.

```bash run id=helm-substrate-podcert
helm upgrade -i substrate-podcert \
  oci://us-docker.pkg.dev/solo-public/enterprise-substrate-helm/substrate-podcert \
  --version ${SUBSTRATE_VERSION} \
  --namespace podcertificate-controller-system \
  -f - <<EOF
postgresClients:
  - kagent/kagent-controller=kagent_user
EOF
kubectl rollout status deployment/podcertificate-controller -n podcertificate-controller-system --timeout=300s
```

**Verified on 2026-10-15:**

```text
Release "substrate-podcert" does not exist. Installing it now.
NAME: substrate-podcert
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
Waiting for deployment "podcertificate-controller" rollout to finish: 0 of 1 updated replicas are available...
deployment "podcertificate-controller" successfully rolled out
```

The pools are valid for one year from now. Nothing rotates them, and when they expire nothing that
was issued from them validates. Before production covers rotation.

### Step 4: Install PostgreSQL

kagent and Substrate keep their state in PostgreSQL, and neither chart deploys it. This step runs
the database kagent's own CLI installs for development: one PostgreSQL, with a schema for each
product, that accepts logins only by certificate. There are no database passwords. Each client
presents a certificate from Step 3's controller, signed from `postgres-ca-pool`; PostgreSQL checks
it against that pool's trust bundle and maps it to a user, and its own serving certificate comes
from the service DNS pool.

The manifest and the role scripts are upstream's, fetched at the versions this guide pins and
checked against their digests. kagent-enterprise also keeps tables in a schema of its own,
`enterprise`, owned by the same role as kagent's; the last two statements create it.

```bash run id=postgres-install
PG_SETUP=$(mktemp -d)
KAGENT_SRC=https://raw.githubusercontent.com/kagent-dev/kagent/v1.0.0-alpha13/go/core/cli/internal/commands
SUBSTRATE_SRC=https://raw.githubusercontent.com/kagent-dev/substrate/v0.5.0-alpha2/pkg/postgressetup
curl -sSLf -o "$PG_SETUP/postgres.yaml" "$KAGENT_SRC/bundled_postgres.yaml"
curl -sSLf -o "$PG_SETUP/kagent.sql" "$KAGENT_SRC/bundled_postgres.sql"
curl -sSLf -o "$PG_SETUP/substrate.sql" "$SUBSTRATE_SRC/setup.sql"
( cd "$PG_SETUP" && shasum -a 256 -c - ) <<EOF
dc02456aa1fb370a9dd0ab468087f5b5105420bfce7360a0ae358383a3bc2b39  postgres.yaml
7ce064fd4e5f5f55a470e86f45db979247bacd887a09d881112051a9695f46be  kagent.sql
137264dea1a39db1a0692da8c24bd49d5272dae6123bab3cec1d667fdb8ee37e  substrate.sql
EOF
sed -e 's|${NAMESPACE}|kagent|g' -e 's|${SUBSTRATE_NAMESPACE}|ate-system|g' \
    -e "s|\${POSTGRES_IMAGE}|${POSTGRES_IMAGE}|g" "$PG_SETUP/postgres.yaml" \
  | kubectl apply --server-side -f -
kubectl rollout status deployment/kagent-postgresql -n kagent --timeout=300s
{ echo "BEGIN;"; cat "$PG_SETUP/kagent.sql" "$PG_SETUP/substrate.sql"
  echo "CREATE SCHEMA IF NOT EXISTS enterprise AUTHORIZATION kagent_owner;"
  echo "REVOKE ALL ON SCHEMA enterprise FROM PUBLIC;"
  echo "COMMIT;"
} | kubectl exec -i -n kagent deployment/kagent-postgresql -c postgresql -- \
    psql --no-psqlrc --set=ON_ERROR_STOP=1 --quiet -U postgres -d kagent \
      --set=substrate_schema=substrate \
      --set=substrate_owner_role=substrate_owner --set=substrate_owner_user=substrate_owner_user \
      --set=substrate_owner_password= \
      --set=substrate_readwrite_role=substrate_readwrite --set=substrate_readwrite_user=substrate_readwrite_user \
      --set=substrate_readwrite_password=
rm -rf "$PG_SETUP"
```

**Verified on 2026-10-15:**

```text
postgres.yaml: OK
kagent.sql: OK
substrate.sql: OK
configmap/kagent-postgresql serverside-applied
persistentvolumeclaim/kagent-postgresql serverside-applied
deployment.apps/kagent-postgresql serverside-applied
service/kagent-postgresql serverside-applied
secret/kagent-postgres serverside-applied
secret/substrate-postgres-readwrite serverside-applied
secret/substrate-postgres-owner serverside-applied
Waiting for deployment "kagent-postgresql" rollout to finish: 0 of 1 updated replicas are available...
deployment "kagent-postgresql" successfully rolled out
```

`shasum` prints `OK` for each file. Anything else, stop. The manifest also creates the three
Secrets the charts read their connection strings from: `kagent-postgres` in `kagent`, and
`substrate-postgres-readwrite` and `substrate-postgres-owner` in `ate-system`. They hold no
password, only the user, the address and where the certificate is mounted. Every script tolerates
an existing database, so the block is safe to re-run.

Check who owns what, and how PostgreSQL authenticates:

```bash run id=step-4-postgres-check
kubectl exec -n kagent deployment/kagent-postgresql -c postgresql -- psql -U postgres -d kagent -At -c \
  "select nspname || ' owned by ' || pg_get_userbyid(nspowner) from pg_namespace where nspname in ('kagent','substrate','enterprise') order by 1"
kubectl get configmap kagent-postgresql -n kagent -o jsonpath='{.data.pg_hba\.conf}'
```

**Verified on 2026-10-15:**

```text
enterprise owned by kagent_owner
kagent owned by kagent_owner
substrate owned by substrate_owner
local all all trust
hostssl all postgres all reject
hostssl kagent kagent_user,substrate_owner_user,substrate_readwrite_user all cert
```

Inside the pod, over its socket, `postgres` is trusted; that is how the block above ran its
scripts. Over the network, `postgres` is refused and the three product users are accepted only
with a certificate (`cert`). Anyone who can `kubectl exec` into this pod is a database superuser,
so restrict `pods/exec` in `kagent`.

### Step 5: Install Substrate and kagent

Substrate is its own Helm release, named `substrate`, in namespace `ate-system`. The kagent chart
addresses Substrate's API at `api.ate-system.svc`, so keep both names.

The chart requires an enterprise license Secret before it will render. Create it from your
agentgateway license, over stdin so the key never appears in a command line or in your shell
history:

```bash run id=substrate-license
kubectl delete secret enterprise-agentgateway-license -n ate-system --ignore-not-found
printf '%s' "$AGENTGATEWAY_LICENSE_KEY" | kubectl create secret generic enterprise-agentgateway-license \
  -n ate-system --from-file=enterprise-agentgateway-license-key=/dev/stdin
```

The chart also deploys the snapshot store, RustFS, where every suspended session is kept. Size its
volume now. On kind's storage class a volume cannot grow after install: an upgrade that changes
the size fails with `only dynamically provisioned pvc can be resized and the storageclass that
provisions the pvc must support resize`, and leaves the release `failed`.

On this release the store holds, per suspended session, 1.4 MB after one turn and 2.2 MB after 20
(Step 27), and 1.06 MB of golden snapshot per agent. For 500 suspended sessions of up to 20 turns
across 10 agents: 500 × 2.2 MB + 10 × 1.06 MB = 1.11 GB, more than the chart's 1Gi default.
`SNAPSHOT_STORE_SIZE` sets 2Gi.

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
postgres:
  clientCertificates:
    enabled: true
rustfs:
  storageSize: ${SNAPSHOT_STORE_SIZE}
credentialProvider:
  namespacePolicies:
    - atespace: kagent
      allowedNamespaces: [kagent]
EOF
```

`postgres.clientCertificates.enabled` gives ate-api its database login certificates; the
connection strings in Step 4's Secrets point at them. `credentialProvider.namespacePolicies` is how
a model key gets from a Kubernetes Secret into an outbound request without passing through the
agent. The credential provider reads Secrets only for the grants listed here, and the default is
none. This one lets actors in the `kagent` atespace, which is where kagent places every session,
use Secrets in the `kagent` namespace.

RustFS starts with fixed default credentials. Step 22 replaces them. Until then, treat anything
stored in it as readable by anyone in the cluster.

Wait for Substrate to come up, check the store's volume, and prove kubectl-ate can talk to it:

```bash run id=substrate-ready
kubectl wait --for=condition=Available deployment --all -n ate-system --timeout=600s
kubectl rollout status daemonset/atelet -n ate-system --timeout=300s
kubectl get pods -n ate-system
kubectl get pvc rustfs-data -n ate-system -o jsonpath='snapshot store volume: {.spec.resources.requests.storage} requested, {.status.capacity.storage} bound{"\n"}'
kubectl-ate get actors -A
```

**Verified on 2026-10-15:**

```text
deployment.apps/ate-api-server condition met
deployment.apps/ate-controller condition met
deployment.apps/atenet-egress condition met
deployment.apps/atenet-router condition met
deployment.apps/k8s-credential-provider condition met
deployment.apps/rustfs condition met
daemon set "atelet" successfully rolled out
NAME                                       READY   STATUS      RESTARTS   AGE
ate-api-server-97cfff689-bkxrg             1/1     Running     0          41s
ate-api-server-97cfff689-fk6fj             1/1     Running     0          41s
ate-controller-65dd9d7749-fvwsw            1/1     Running     0          41s
atelet-rmz5t                               1/1     Running     0          41s
atenet-egress-68b8df7b94-62fsg             1/1     Running     0          41s
atenet-router-8f46bdc9d-xqxhx              1/1     Running     0          41s
k8s-credential-provider-847cdc86fc-7q7cw   1/1     Running     0          41s
rustfs-7b5d94bc9b-sdn2v                    1/1     Running     0          41s
rustfs-bucket-init-9s98b                   0/1     Completed   0          41s
snapshot store volume: 2Gi requested, 2Gi bound
ATESPACE   NAME   TEMPLATE   STATE   WORKER POD   WORKER IPS   VERSION   AGE
```

No actors yet, and no error. An error here, rather than an empty list, is the issuer warning in
Step 3. The volume line shows the size you set, not the chart's 1Gi.

kagent is the control plane for agents: you declare agents as Kubernetes resources, and it turns
each session into a Substrate actor. The release also deploys the UI, ClickHouse for traces, and a
`WorkerPool`: the worker pods every sandbox runs in.

```bash run id=kagent-license
kubectl delete secret enterprise-kagent-license -n kagent --ignore-not-found
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
database:
  postgres:
    clientCertificate:
      enabled: true
controller:
  substrate:
    enabled: true
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

`database.postgres.clientCertificate.enabled` mounts the controller's login certificate. The
connection string comes from the `kagent-postgres` Secret Step 4 created, which is the chart's
default name. Substrate's address is the chart's default too, `api.ate-system.svc`, which is why
the release name and namespace above matter. The controller's settings live under the chart's
`config:` key on this release; the `controller.substrate.ateApiEndpoint` and `atenetRouterURL`
keys earlier releases used are ignored without an error.

`global.cluster` names this installation. The UI sends it on every request and the controller
rejects a name it does not recognise, so set it on any real install.

Two worker replicas, because every agent keeps a golden snapshot resident on a worker, and the pool
needs room for sessions beside it. The workers run as their own ServiceAccount, `kagent-default`,
which the chart creates. SCALE sizes the pool.

Check the release:

```bash run id=step-5-kagent-ready
kubectl get pods -n kagent
kubectl get workerpool -n kagent
kubectl logs -n kagent deployment/kagent-controller -c controller | grep -o '"state":"[A-Za-z]*"' | sort | uniq -c
```

**Verified on 2026-10-15:**

```text
NAME                                                  READY   STATUS    RESTARTS      AGE
kagent-clickhouse-shard0-0                            1/1     Running   0             60s
kagent-controller-6db6867b89-jcqq4                    2/2     Running   1 (21s ago)   60s
kagent-default-5d55b7f7c9-fsrrb                       1/1     Running   0             60s
kagent-default-5d55b7f7c9-mch2s                       1/1     Running   0             60s
kagent-postgresql-5fb9d7f7d7-crzd2                    2/2     Running   0             2m12s
kagent-ui-6566778cc8-bc2wx                            1/1     Running   0             60s
kmcp-enterprise-controller-manager-56c598d9d7-khz4d   1/1     Running   0             60s
NAME             DESIRED   REPLICAS   READY   AGE
kagent-default   2         2          2       60s
   1 "state":"Licensed"
   1 "state":"Warning"
```

> [!NOTE]
> **The controller may restart once during the install.** It waits 20 seconds for its bundled login to answer, logs `unable to configure the enterprise extensions … localhost:5556 … connection refused` if it has not, and recovers on its own. `--wait` covers it.
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
kubectl delete secret enterprise-agentgateway-license -n agentgateway-system --ignore-not-found
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

**Verified on 2026-10-15:**

```text
gateway.gateway.networking.k8s.io/agentgateway-proxy condition met
Waiting for deployment "agentgateway-proxy" rollout to finish: 0 of 1 updated replicas are available...
deployment "agentgateway-proxy" successfully rolled out
```

Store the provider key in the gateway's namespace. This is the only copy of it in the cluster:

```bash run id=secret-anthropic-api-key
kubectl delete secret anthropic-api-key -n agentgateway-system --ignore-not-found
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
: "${AGENT_CONSUMER_KEY:=agw_team_agents_$(openssl rand -hex 32)}"; export AGENT_CONSUMER_KEY
kubectl delete secret llm-virtual-keys -n agentgateway-system --ignore-not-found
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
kubectl --context "kind-${KIND_CLUSTER_NAME}" port-forward --address 127.0.0.1 -n agentgateway-system deployment/agentgateway-proxy 18081:80 >/dev/null 2>&1 &
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

**Verified on 2026-10-15:**

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

**Verified on 2026-10-15:**

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
: "${AGENT_CONSUMER_KEY:?is empty: Step 6 exported it in another shell. Read it back first (below).}" && {
kubectl delete secret kagent-gateway-consumer-key -n kagent --ignore-not-found
printf '%s' "$AGENT_CONSUMER_KEY" | kubectl create secret generic kagent-gateway-consumer-key \
  -n kagent --from-file=api-key=/dev/stdin
}
```

> [!WARNING]
> **An empty consumer key fails nothing until the first turn.** `AGENT_CONSUMER_KEY` exists only in the shell that ran Step 6. In a new shell it is empty, and without the guard above an empty Secret is created without complaint, the agent still goes `Ready`, and the first turn fails with `503 Service Unavailable credential provider returned an unusable secret`. If the guard stops you, read the key back from the gateway's Secret, then run the block above again.

**Only if the guard above stopped you.** This reads the key only when your shell has none, so it changes nothing otherwise:

```bash run id=step-8-read-back-consumer-key when=manual
if [ -z "${AGENT_CONSUMER_KEY:-}" ]; then
  export AGENT_CONSUMER_KEY=$(kubectl get secret llm-virtual-keys -n agentgateway-system \
    -o jsonpath='{.data.team-agents}' | base64 --decode | jq -r .key)
  echo "AGENT_CONSUMER_KEY read back; run secret-kagent-gateway-consumer-key again"
fi
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
  template:
    ref:
      name: assistant
  harnessRef:
    name: kagent-adk
EOF
```

`template.ref` names an AgentTemplate; `template.inline` would carry one inside the Agent instead.
The `templateRef` field earlier releases used no longer exists, and an Agent that sets it is
rejected.

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

**Verified on 2026-10-15:**

```text
agent.api.kagent.dev/assistant condition met
Accepted=True Agent explicitly selects its template and harness
ResolvedRefs=True All runtime references resolved
Compatible=True Resolved configuration is compatible with the Harness
Ready=True ActorTemplate golden snapshot is ready
```

`Ready` means Substrate started the agent once, let it initialize, and saved that state as a
golden snapshot. Every session from now on starts from a copy of it instead of booting.

### Step 9: Verify the first turn through the enterprise gateway

Bring the forwards up:

```bash run id=step-9-forwards
forwards
```

Two helpers. `kagent_token` gets a token from the bundled login, which is exactly the open endpoint
Step 5 warned about; Step 23 replaces it. `kagent_send` sends one message to an agent over A2A and
prints the reply and the session's ID:

```bash run id=step-9-helpers
kagent_token() {
  local resp
  resp=$(curl -sS --max-time 10 -X POST "http://127.0.0.1:${KAGENT_UI_PORT}/autoauth/token" \
    -H 'Content-Type: application/json' -d '{"user_type":"admin"}')
  printf '%s' "$resp" | jq -er '.access_token // empty' 2>/dev/null && return 0
  echo "kagent_token: no token from the bundled login: $(printf '%s' "$resp" | head -c 200)" >&2
  return 1
}

# kagent_send <agent> <message> [contextId]
kagent_send() {
  local ctx=""
  [ -n "${3:-}" ] && ctx="\"contextId\":\"$3\","
  curl -sS --max-time 300 -X POST "http://127.0.0.1:${KAGENT_API_PORT}/agents/kagent/$1" \
    -H "Authorization: Bearer $(kagent_token)" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"SendMessage\",\"params\":{\"message\":{\"messageId\":\"$(openssl rand -hex 8)\",${ctx}\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"$2\"}]}}}" \
    | jq -r 'if .result.task then (.result.task | "\(.status.state)\t\(.contextId)\t\(((.artifacts[-1].parts // .status.message.parts // []) | map(.text // "") | join("")) | gsub("\\s*\n\\s*"; " "))")
             else "NO_TASK\t\t\(.error.message // ("no task in the response: " + (tostring | .[0:200])))" end'
}
```

It prints the reply, or for a failed turn the error the agent got, or `NO_TASK` and the JSON-RPC
error when the controller returned no task at all, so a failure is never a blank line, and always on one line, so `cut -f2` gets the session ID even when the model answers in
paragraphs. It joins every part of the reply: the Claude Code runtime returns its answer in several
parts (`claude`, ` code harness`), and reading only the first would cut it off mid-word. `--max-time 300` because a turn includes a model call. A dead port-forward otherwise leaves `curl`
waiting rather than failing.

Send the first message:

```bash run id=step-9-first-turn
TURN=$(kagent_send assistant "Reply with exactly: up and running")
echo "$TURN"
export FIRST_CONTEXT=$(echo "$TURN" | cut -f2)
```

**Verified on 2026-10-15:**

```text
TASK_STATE_COMPLETED	01a1406d-c370-75c7-9185-598857b5ea1a	up and running
```

`TASK_STATE_COMPLETED`, the session's ID, and the reply. An answer alone does not prove the
call went through the enterprise gateway, so check both ends.

The session's actor is named after its ID. Its egress policy is what kagent told Substrate's
egress gateway to allow:

```bash run id=step-9-egress-policy
kubectl-ate get egress-policy "session-${FIRST_CONTEXT}" --atespace kagent -o json \
  | jq -r '.rules[] | to_entries[0] | "\(.key)\t\(.value.hostnames[0]):\(.value.ports.numbers[0])\t\([.value.effects.replaceHeaders[]? | "\(.header) <- \(.credentialUri)"] | join(", "))"'
```

**Verified on 2026-10-15:**

```text
http	agentgateway-proxy.agentgateway-system.svc.cluster.local:80	x-api-key <- ate-secret://k8s.io/default/kagent/kagent-gateway-consumer-key/api-key
http	kagent-controller.kagent.svc:8083	
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

**Verified on 2026-10-15:**

```text
atenet-egress: 10.244.0.17
route=agentgateway-system/anthropic-messages
endpoint=api.anthropic.com:443
src.addr=10.244.0.17:59332
http.status=200
gen_ai.usage.input_tokens=702
gen_ai.usage.output_tokens=6
```

The call arrived from `atenet-egress`'s address, on the `anthropic-messages` route, and went on to
Anthropic. The log does not name the key, but that route refuses any request without a valid
consumer key (Step 6), so a 200 there means the consumer key was presented and accepted. The
token counts are the gateway's own, which is what budgets and attribution in Isolate are built on.

**What you now have:** an agent that never holds a model key, sessions that each run in their
own sandbox and stop costing memory when a turn ends, and a gateway that every model call passes
through and nothing else in the cluster can reach. What you do not have yet is anything protecting
the UI and API, or the snapshot store, from the rest of the cluster. Isolate closes both.

## OPERATE

Up and Running proved one turn works. This section follows a session through its whole life,
so that when something misbehaves you know which part to look at.

**What you are going to do:** see what kagent created in Substrate for the agent, follow one
session through two turns and a suspension, inspect and act on its actor directly, find where
its context is stored, delete it and check what is left, and run the same agent on a second
runtime.

**What you will have that you did not have before:** a working model of the agent lifecycle on this
platform, and the commands to see each stage of it on your own cluster.

**Verified on:** two certification runs, each on a kind cluster created fresh for it (kind 0.32.0, `kindest/node:v1.35.0`), beside one other cluster on the same Docker host, 2026-10-15: `certz` under zsh, 16:25 to 16:34 UTC, and `certb` under bash, 16:34 to 16:43 UTC. In each, every `run` block from Step 1 to Step 31 was executed verbatim, in document order, in one uninterrupted pass of `auto-build/run.sh`, from an empty directory outside the repository, on the versions in Version support. Every output block in this guide comes from the bash pass.

### Step 10: How an agent becomes actors

Applying the `Agent` in Step 8 did not start a pod. kagent asked Substrate for an **actor template**:
the image, the sandbox class and the egress policy every session with this agent will get.
Substrate started one actor from it, let it initialize, and saved its memory as a **golden
snapshot**. That snapshot is what `Ready` meant.

```bash run id=step-10-template
kubectl-ate get actor-template -a kagent
kubectl-ate get tags -a ate-golden
```

**Verified on 2026-10-15:**

```text
ATESPACE   NAME                     SANDBOX CLASS          GOLDEN TAG                             ERROR   AGE
kagent     assistant-e1af965cdabf   SANDBOX_CLASS_GVISOR   32629163-82db-48e0-b6a9-54394807ef33           7s
ATESPACE     NAME                                   SCOPE                 STATE   SNAPSHOT                                                                                   CONTENT SCOPE                 AGE
ate-golden   32629163-82db-48e0-b6a9-54394807ef33   TAG_SCOPE_PUBLISHED   Ready   gs://ate-snapshots/kagent/atespaces/ate-golden/tags/dae9f408-a364-4588-871f-4a1afd4ba87c   SNAPSHOT_CONTENT_SCOPE_FULL   4s
```

The template's `GOLDEN TAG` is the tag in the `ate-golden` atespace, and the tag's snapshot is a
full memory image in the snapshot store. Every agent you declare gets one of each.

Then each session becomes its own **actor**, named `session-<session id>`, in the `kagent`
atespace:

```bash run id=step-10-actors
kubectl-ate get actors -a kagent
kubectl-ate get workers
```

**Verified on 2026-10-15:**

```text
ATESPACE   NAME                                           TEMPLATE                        STATE                   WORKER POD   WORKER IPS   VERSION   AGE
kagent     session-01a1406d-c370-75c7-9185-598857b5ea1a   kagent/assistant-e1af965cdabf   ACTOR_STATE_SUSPENDED   <none>                    5         1s
NAME                                   POOL             STATE                 ACTORS   CPU   MEMORY         POD                                      AGE
fee35b75-049f-4da0-b552-1aa457e8f7a1   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-5d55b7f7c9-fsrrb   82s
816101c3-696b-4e33-b040-8280c0e50fe3   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-5d55b7f7c9-mch2s   79s
```

Step 9's session is `SUSPENDED`, with no worker pod and no IP. It holds nothing on a worker
until its next message. The workers report the actors placed on them right now, which is none.

There is no long-lived actor per agent. Ten sessions with one agent are ten actors, each
started from the same golden snapshot, which is why Scale counts sessions rather than agents.

### Step 11: Follow one session

Two helpers. `actor_events` reads atelet's log, where Substrate records every restore and
checkpoint with its timing. `wait_suspended` polls the actor until it is suspended:

```bash run id=step-11-helpers
# actor_events <session id>: restores and checkpoints for that session's actor.
actor_events() {
  kubectl logs -n ate-system daemonset/atelet --since=30m \
    | jq -r --arg a "session-$1" 'select(."ate.actor.name" == $a and (.msg | test("timing breakdown")))
        | [.time[11:23], .msg, ."ate.snapshot.kind" + "/" + ."ate.snapshot.scope",
           (((."ate.actor.restore.duration.total" // ."ate.actor.checkpoint.duration.total") * 1000 | floor | tostring) + " ms")]
        | @tsv'
}

# wait_suspended <session id>: block until the actor is suspended, at most 60s.
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

Send the first turn of a new session, then watch its actor:

```bash run id=step-11-turn-1
TURN=$(kagent_send assistant "My project is called Larkspur. Reply with OK.")
echo "$TURN"
export CONV=$(echo "$TURN" | cut -f2)
wait_suspended "$CONV"
kubectl-ate get actor "session-${CONV}" -a kagent
```

**Verified on 2026-10-15:**

```text
TASK_STATE_COMPLETED	01a1406d-c82d-7e73-af9f-770e6f9dca84	OK
suspended (polled 1s after the reply)
ATESPACE   NAME                                           TEMPLATE                        STATE                   WORKER POD   WORKER IPS   VERSION   AGE
kagent     session-01a1406d-c82d-7e73-af9f-770e6f9dca84   kagent/assistant-e1af965cdabf   ACTOR_STATE_SUSPENDED   <none>                    5         1s
```

The actor was suspended as soon as the turn ended. **There is no idle timeout to configure.** kagent
suspends a session's actor when its last turn finishes, so idle lasts about a second. A turn
that ends waiting for input (approval, authentication) pauses the actor on its worker instead of
suspending it.

Send the second turn in the same session:

```bash run id=step-11-turn-2
kagent_send assistant "What is my project called?" "$CONV"
wait_suspended "$CONV"
actor_events "$CONV"
```

**Verified on 2026-10-15:**

```text
TASK_STATE_COMPLETED	01a1406d-c82d-7e73-af9f-770e6f9dca84	Your project is called Larkspur.
suspended (polled 1s after the reply)
16:38:19.085	Restore timing breakdown	golden/full	81 ms
16:38:19.602	Checkpoint timing breakdown	latest/full	64 ms
16:38:20.964	Restore timing breakdown	latest/full	103 ms
16:38:21.534	Checkpoint timing breakdown	latest/full	72 ms
```

The agent remembered, and atelet's log shows how:

| Event | Snapshot | What it means |
|---|---|---|
| First restore | `golden/full` | The new actor started from the agent's golden memory image |
| Checkpoint | `latest/full` | At the end of the turn, the session's whole memory and its data directory were saved |
| Second restore | `latest/full` | The session's own memory image, as it was when the turn ended |
| Checkpoint | `latest/full` | Saved again, replacing the previous one |

Every checkpoint saves the actor's memory, not only its data directory (`full`, not `data`). That
is why a suspended session takes megabytes in the snapshot store (Step
27), and why the store holds everything the runtime had in memory, not only what it wrote to disk
(Step 17).

A suspended session can resume on a different worker from the one it last ran on, because
everything it needs is in the snapshot store.

### Step 12: Inspect and act on an actor

kagent drives actors for you. kubectl-ate lets you look at one and act on it directly, which is
what you need when a session is stuck:

```bash run id=step-12-inspect
kubectl-ate get actor "session-${CONV}" -a kagent -o json \
  | jq '{name: .metadata.name, uid: .metadata.uid, version: .metadata.version, state: .status.state, snapshot: .status.externalSnapshot}'
```

**Verified on 2026-10-15:**

```text
{
  "name": "session-01a1406d-c82d-7e73-af9f-770e6f9dca84",
  "uid": "958c3a3c-d41b-487b-a144-f4e671a70b35",
  "version": "9",
  "state": "ACTOR_STATE_SUSPENDED",
  "snapshot": {
    "actorTemplateUid": "32629163-82db-48e0-b6a9-54394807ef33",
    "contentScope": "SNAPSHOT_CONTENT_SCOPE_FULL",
    "snapshotUri": "gs://ate-snapshots/kagent/atespaces/kagent/actors/958c3a3c-d41b-487b-a144-f4e671a70b35/snapshots/b4344888-678a-4ca8-9585-08996b985b4f"
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

**Verified on 2026-10-15:**

```text
ATESPACE   NAME                                           TEMPLATE                        STATE                 WORKER POD                               WORKER IPS    VERSION   AGE
kagent     session-01a1406d-c82d-7e73-af9f-770e6f9dca84   kagent/assistant-e1af965cdabf   ACTOR_STATE_RUNNING   kagent/kagent-default-5d55b7f7c9-mch2s   10.244.0.23   11        3s
NAME                                   POOL             STATE                 ACTORS   CPU   MEMORY         POD                                      AGE
fee35b75-049f-4da0-b552-1aa457e8f7a1   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-5d55b7f7c9-fsrrb   86s
816101c3-696b-4e33-b040-8280c0e50fe3   kagent-default   WORKER_STATE_ACTIVE   1/1000   0/6   0/12220312Ki   kagent/kagent-default-5d55b7f7c9-mch2s   83s
ATESPACE   NAME                                           TEMPLATE                        STATE                   WORKER POD   WORKER IPS   VERSION   AGE
kagent     session-01a1406d-c82d-7e73-af9f-770e6f9dca84   kagent/assistant-e1af965cdabf   ACTOR_STATE_SUSPENDED   <none>                    13        3s
```

> [!WARNING]
> **A hand-resumed actor stays running until a turn ends or you suspend it.** kagent suspends an actor when a turn finishes, and a resume with no turn never finishes one, so the actor holds its place on a worker indefinitely. Suspend what you resume.

### Step 13: Where a session's context is kept

The session survived suspension because atelet wrote it to the snapshot store. With the
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

List this session's snapshot, and the agent's golden image:

```bash run id=step-13-snapshot-objects
export CONV_ACTOR_UID=$(kubectl-ate get actor "session-${CONV}" -a kagent -o json | jq -r .metadata.uid)
echo "-- session ${CONV} (actor ${CONV_ACTOR_UID})"
snapshot_ls "kagent/atespaces/kagent/actors/${CONV_ACTOR_UID}/"
echo "-- golden images"
snapshot_ls "kagent/atespaces/ate-golden/"
```

**Verified on 2026-10-15:**

```text
-- session 01a1406d-c82d-7e73-af9f-770e6f9dca84 (actor 958c3a3c-d41b-487b-a144-f4e671a70b35)
2026-10-15 16:38:22      79225 kagent/atespaces/kagent/actors/958c3a3c-d41b-487b-a144-f4e671a70b35/snapshots/37f76bec-0785-409b-a57b-3cba573d9d60/checkpoint.img.zstd
2026-10-15 16:38:22       1614 kagent/atespaces/kagent/actors/958c3a3c-d41b-487b-a144-f4e671a70b35/snapshots/37f76bec-0785-409b-a57b-3cba573d9d60/durable-dir-data.tar.zstd
2026-10-15 16:38:22        665 kagent/atespaces/kagent/actors/958c3a3c-d41b-487b-a144-f4e671a70b35/snapshots/37f76bec-0785-409b-a57b-3cba573d9d60/manifest.json
2026-10-15 16:38:22    1377555 kagent/atespaces/kagent/actors/958c3a3c-d41b-487b-a144-f4e671a70b35/snapshots/37f76bec-0785-409b-a57b-3cba573d9d60/pages.img.zstd
2026-10-15 16:38:22       2364 kagent/atespaces/kagent/actors/958c3a3c-d41b-487b-a144-f4e671a70b35/snapshots/37f76bec-0785-409b-a57b-3cba573d9d60/pages_meta.img.zstd
-- golden images
2026-10-15 16:38:14      77411 kagent/atespaces/ate-golden/tags/dae9f408-a364-4588-871f-4a1afd4ba87c/checkpoint.img.zstd
2026-10-15 16:38:14        901 kagent/atespaces/ate-golden/tags/dae9f408-a364-4588-871f-4a1afd4ba87c/durable-dir-data.tar.zstd
2026-10-15 16:38:14        661 kagent/atespaces/ate-golden/tags/dae9f408-a364-4588-871f-4a1afd4ba87c/manifest.json
2026-10-15 16:38:14    1017453 kagent/atespaces/ate-golden/tags/dae9f408-a364-4588-871f-4a1afd4ba87c/pages.img.zstd
2026-10-15 16:38:14       2078 kagent/atespaces/ate-golden/tags/dae9f408-a364-4588-871f-4a1afd4ba87c/pages_meta.img.zstd
```

Each session keeps one snapshot, which each checkpoint replaces: its memory image
(`pages.img`, the largest object) with the process state beside it, and its data directory
(`durable-dir-data.tar`). The data directory holds the runtime's database (`sessions.db`), and the memory
image holds whatever the runtime had in memory, the session's text included. That **is the
session, in readable text**: compressed with zstd, not encrypted. The golden image is the
agent's memory at start-up, shared by every session with that agent. kagent's tables in
PostgreSQL hold a second copy of each session's events.

> [!WARNING]
> **Anyone who can read the atelet DaemonSet has the store's credentials, and with the chart's defaults anyone who can reach the store can read every session.** The helper above works for exactly that reason. Step 22 replaces the credentials and fences the store so that only atelet and ate-api can reach it. Until then, treat every session on this cluster as readable by anything in it.

### Step 14: Delete a session, and what stays behind

**In the UI.** Open the agent, open the session's menu in the chat list (the three dots beside
it), choose **Delete chat**, and confirm with **Delete**. The UI asks kagent to delete the session,
and kagent deletes its actor. Verified on this release with Keycloak sign-in (Step 23), as a writer
deleting a session they had started in the browser.

The chat list shows every session with the agent, including ones other users and scripts started.
Only your own open: anyone else's answers "Session not found" when you open or delete it, because
the controller treats a session as visible only to its creator (Step 24).

**From a script.** kagent offers no supported CLI or API for this: the session API is gRPC and
gRPC-Web only, with no JSON form and no server reflection, and the open-source `kagent` CLI sends no
token, so it cannot authenticate to this controller. Deleting a session is one string field, so
this helper frames the gRPC-Web request by hand, the same request the UI sends: five bytes of frame
header, then the field (tag `0x0a`, length 36, the session ID):

```bash run id=step-14-helpers
# kagent_delete_session <session id>: SessionService/DeleteSession; prints grpc-status.
kagent_delete_session() {
  printf '\000\000\000\000\046\012\044%s' "$1" \
    | curl -sS --max-time 30 -X POST "http://127.0.0.1:${KAGENT_API_PORT}/kagent.api.v1alpha1.SessionService/DeleteSession" \
        -H "Authorization: Bearer $(kagent_token)" \
        -H 'Content-Type: application/grpc-web+proto' -H 'X-Grpc-Web: 1' --data-binary @- \
    | LC_ALL=C tr -c '[:print:]' '\n' | grep -E '^grpc-(status|message)'
}
```

`grpc-status: 0` is success. Anything else comes with a `grpc-message` saying why.

Delete the session from Step 11, by script:

```bash run id=step-14-delete-script
kagent_delete_session "$CONV"
```

**Verified on 2026-10-15:**

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

**Verified on 2026-10-15:**

```text
Error: failed to get actor "session-01a1406d-c82d-7e73-af9f-770e6f9dca84": rpc error: code = NotFound desc = Actor kagent/session-01a1406d-c82d-7e73-af9f-770e6f9dca84 not found
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
not.** Every session ever placed on a node leaves `/var/lib/ate/actors/<actor uid>/` behind,
about 40 KiB of empty subdirectories and one small file, and nothing removes them. Plan
node disk and inodes for it; Before production covers it. On a cluster other than kind, read the
directory through a node shell rather than `docker exec`.

Deleting an `Agent` does not delete its sessions. Its actor template and golden image stay
in Substrate for as long as any of its sessions exist, and went about half a minute after the
last one was deleted (observed once, on 1.0.0-alpha8). Delete an agent's sessions as well as
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
  template:
    ref:
      name: assistant
  harnessRef:
    name: claude-code
EOF
kubectl wait agent/assistant-claude-code -n kagent --for=condition=Ready --timeout=300s
```

**Verified on 2026-10-15:**

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

**Verified on 2026-10-15:**

```text
TASK_STATE_COMPLETED	01a1406e-5e96-7cc6-a31d-3aa1201c7430	claude code harness
http	agentgateway-proxy.agentgateway-system.svc.cluster.local:80	x-api-key <- ate-secret://k8s.io/default/kagent/kagent-gateway-consumer-key/api-key
http	kagent-controller.kagent.svc:8083
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

**What you now have:** the lifecycle of a session, end to end, and the commands to see each
stage: the template and golden image behind an agent, an actor per session that holds nothing
on a worker while suspended, context in the snapshot store, and what deletion leaves behind. You have also seen
how exposed that context is. Isolate starts there.

## ISOLATE

Operate showed how a session lives. This section shows what keeps sessions, credentials
and users apart, proves each control from the inside, and closes the two things Up and Running left
open: the snapshot store and the bundled login.

**What you are going to do:** look inside a sandbox, see what is left of a suspended session,
prove the agent never holds a key, test the egress allowlist from inside two runtimes, give an
agent an MCP tool through the gateway, put a budget on the team, replace the snapshot store's
credentials and fence it, and move the UI and API to Keycloak with roles.

**What you will have that you did not have before:** every outbound credential held outside the
agent, every session's data reachable only by the components that need it, and every caller
of the UI and API authenticated, with roles deciding who can chat.

Each step says which runtime it shows: the kagent Go ADK runtime (agent `assistant`) or Claude Code
(agent `assistant-claude-code`, from Step 15).

**Verified on:** two certification runs, each on a kind cluster created fresh for it (kind 0.32.0, `kindest/node:v1.35.0`), beside one other cluster on the same Docker host, 2026-10-15: `certz` under zsh, 16:25 to 16:34 UTC, and `certb` under bash, 16:34 to 16:43 UTC. In each, every `run` block from Step 1 to Step 31 was executed verbatim, in document order, in one uninterrupted pass of `auto-build/run.sh`, from an empty directory outside the repository, on the versions in Version support. Every output block in this guide comes from the bash pass.

### Step 16: One gVisor sandbox per session

*Runtime: kagent.*

Every actor runs in its own gVisor sandbox on a worker pod. gVisor puts a user-space kernel between
the agent and the node's kernel, so actors from different teams packed onto one worker never share a
kernel with each other or make system calls into the host's.

This helper runs a command inside a session's sandbox, through `runsc`, the gVisor runtime
Substrate unpacks onto each node:

```bash run id=step-16-helpers
# sandbox_exec <session id> <command...>: run a command inside that session's sandbox.
# The actor must be running (kubectl-ate resume actor ...).
sandbox_exec() {
  local conv=$1 uid; shift
  uid=$(kubectl-ate get actor "session-${conv}" -a kagent -o json | jq -r .metadata.uid)
  docker exec "${KIND_CLUSTER_NAME}-control-plane" sh -c '
    R=$(find /var/lib/ate/static-files -name runsc -type f | head -1)
    "$R" --root=/var/lib/ate/actors/'"$uid"'/runsc-state exec kagent "$@" 2>&1 | grep -a -v "sandbox is not running" || true' sh "$@"
}

# sandbox_procs <session id>: gVisor processes on the node for that session's actor.
sandbox_procs() {
  local uid
  uid=$(kubectl-ate get actor "session-$1" -a kagent -o json | jq -r .metadata.uid)
  docker exec "${KIND_CLUSTER_NAME}-control-plane" sh -c "ps -eo args | grep -c '^runsc-sandbox --root=/var/lib/ate/actors/${uid}/' || true"
}
```

On this release `runsc exec` prints `sandbox is not running` and exits non-zero after every command,
including ones that ran. The helper drops that line and ignores the status, so read the output, not
the exit code. On a cluster other than kind, run the same `runsc` command from a node shell.

Resume Step 9's session and look inside its sandbox:

```bash run id=step-16-inside
kubectl-ate resume actor "session-${FIRST_CONTEXT}" -a kagent >/dev/null
echo "-- kernel inside the sandbox:"
sandbox_exec "$FIRST_CONTEXT" uname -a
echo "-- kernel on the node:"
docker exec "${KIND_CLUSTER_NAME}-control-plane" uname -r
echo "-- gVisor sandboxes on the node for this actor: $(sandbox_procs "$FIRST_CONTEXT")"
```

**Verified on 2026-10-15:**

```text
-- kernel inside the sandbox:
Linux actor 4.19.0-gvisor #1 SMP Sun Jan 10 15:06:54 PST 2016 aarch64 Linux
-- kernel on the node:
6.8.0-117-generic
-- gVisor sandboxes on the node for this actor: 1
```

The agent sees gVisor's kernel, not the node's. Its processes are not in the node's process table
at all; what the node runs is the gVisor sandbox around them.

### Step 17: What is left of a suspended session

*Runtime: kagent.*

Suspend the same session and look again:

```bash run id=step-17-suspended
kubectl-ate suspend actor "session-${FIRST_CONTEXT}" -a kagent
echo "-- gVisor sandboxes on the node for this actor: $(sandbox_procs "$FIRST_CONTEXT")"
echo "-- its snapshot:"
snapshot_ls "kagent/atespaces/kagent/actors/$(kubectl-ate get actor "session-${FIRST_CONTEXT}" -a kagent -o json | jq -r .metadata.uid)/"
```

**Verified on 2026-10-15:**

```text
ATESPACE   NAME                                           TEMPLATE                        STATE                   WORKER POD   WORKER IPS   VERSION   AGE
kagent     session-01a1406d-c370-75c7-9185-598857b5ea1a   kagent/assistant-e1af965cdabf   ACTOR_STATE_SUSPENDED   <none>                    9         41s
-- gVisor sandboxes on the node for this actor: 0
-- its snapshot:
2026-10-15 16:38:59      79593 kagent/atespaces/kagent/actors/4b5c810b-f1a9-42ca-b35d-e28c1acc73bb/snapshots/9682da92-6cb2-4d38-bffd-991fd48a5184/checkpoint.img.zstd
2026-10-15 16:38:59       1403 kagent/atespaces/kagent/actors/4b5c810b-f1a9-42ca-b35d-e28c1acc73bb/snapshots/9682da92-6cb2-4d38-bffd-991fd48a5184/durable-dir-data.tar.zstd
2026-10-15 16:38:59        665 kagent/atespaces/kagent/actors/4b5c810b-f1a9-42ca-b35d-e28c1acc73bb/snapshots/9682da92-6cb2-4d38-bffd-991fd48a5184/manifest.json
2026-10-15 16:38:59    1280812 kagent/atespaces/kagent/actors/4b5c810b-f1a9-42ca-b35d-e28c1acc73bb/snapshots/9682da92-6cb2-4d38-bffd-991fd48a5184/pages.img.zstd
2026-10-15 16:38:59       2389 kagent/atespaces/kagent/actors/4b5c810b-f1a9-42ca-b35d-e28c1acc73bb/snapshots/9682da92-6cb2-4d38-bffd-991fd48a5184/pages_meta.img.zstd
```

| | Running | Suspended |
|---|---|---|
| Process and sandbox | gVisor sandbox on a worker | **None** |
| Network | An IP on the worker | **None** |
| Identity certificate | Mounted in the sandbox | **None**: a new one is issued on resume |
| Session data | In the sandbox | Its memory and data, one snapshot in the store (Step 13) |
| Record in Substrate | The actor | The actor, `SUSPENDED` |
| On the node | Its actor directory | The directory's empty shell (Step 14) |

A suspended session cannot be reached, because there is nothing running to reach. What it
leaves is data: on this release, the actor's whole memory as it was when the turn ended. Anything
the runtime held in memory is in the store, so check what that includes.

This helper streams a session's latest snapshot out of the store and decompresses it, writing
nothing to disk. Each snapshot object is 12 bytes of Substrate header (`ATESPRSE` and a format
version) in front of one zstd stream, so the helper drops those bytes and pipes the rest to your
`zstd`:

```bash run id=step-17-helpers
# snapshot_cat <session id>: the decompressed contents of that session's latest snapshot.
# Uses the store's credentials from the atelet DaemonSet, unless S3_ACCESS_KEY and S3_SECRET_KEY are set.
snapshot_cat() {
  local prefix ak sk
  prefix=$(kubectl-ate get actor "session-$1" -a kagent -o json \
    | jq -r '.status.externalSnapshot.snapshotUri | sub("^[a-z0-9]+://ate-snapshots/"; "")')
  ak=${S3_ACCESS_KEY:-$(kubectl get daemonset atelet -n ate-system -o json | jq -r '[.spec.template.spec.containers[].env[]? | select(.name=="AWS_ACCESS_KEY_ID")][0].value')}
  sk=${S3_SECRET_KEY:-$(kubectl get daemonset atelet -n ate-system -o json | jq -r '[.spec.template.spec.containers[].env[]? | select(.name=="AWS_SECRET_ACCESS_KEY")][0].value')}
  kubectl delete pod snapshot-reader -n ate-system --ignore-not-found >/dev/null
  kubectl create -f- >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: snapshot-reader
  namespace: ate-system
  labels: {app: snapshot-ls}
spec:
  restartPolicy: Never
  containers:
    - name: aws
      image: ${AWS_CLI_IMAGE}
      command: ["sleep", "300"]
      env:
        - {name: AWS_ACCESS_KEY_ID, value: "${ak}"}
        - {name: AWS_SECRET_ACCESS_KEY, value: "${sk}"}
        - {name: AWS_DEFAULT_REGION, value: us-east-1}
EOF
  kubectl wait --for=condition=Ready pod/snapshot-reader -n ate-system --timeout=120s >/dev/null
  kubectl exec -n ate-system snapshot-reader -- sh -c '
    E=http://rustfs.ate-system.svc:9000
    for o in $(aws --endpoint-url $E s3 ls "s3://ate-snapshots/$0/" | awk "/zstd\$/ {print \$4}"); do
      aws --endpoint-url $E s3 cp "s3://ate-snapshots/$0/$o" - | tail -c +13
    done' "$prefix" | zstd -dc
  kubectl delete pod snapshot-reader -n ate-system --wait=false >/dev/null
}
```

Start a new session that carries a marker, a random code word the agent is asked to remember,
and let it suspend. The marker is the control: it is in the session, so a search that cannot
find it proves nothing. Then search the snapshot once for the marker, the consumer key and the
Anthropic key. The search reports which string matched, never the match itself:

```bash run id=step-17-snapshot-search
: "${AGENT_CONSUMER_KEY:?is empty: read it back first (Step 8)}" "${ANTHROPIC_API_KEY:?is empty}" && {
SNAP_MARKER="snapshot-control-$(openssl rand -hex 6)"
TURN=$(kagent_send assistant "Remember this code word, and reply only with OK: ${SNAP_MARKER}")
export SNAP_CONV=$(echo "$TURN" | cut -f2)
echo "$TURN" | cut -f1,3
wait_suspended "$SNAP_CONV"
kubectl-ate get actor "session-${SNAP_CONV}" -a kagent -o json | jq -r '"snapshot scope: " + .status.externalSnapshot.contentScope'
snapshot_cat "$SNAP_CONV" \
  | LC_ALL=C grep -a -o -F -e "$SNAP_MARKER" -e "$AGENT_CONSUMER_KEY" -e "$ANTHROPIC_API_KEY" \
  | while read -r hit; do
      case "$hit" in
        "$SNAP_MARKER") echo marker ;; "$AGENT_CONSUMER_KEY") echo consumer ;; "$ANTHROPIC_API_KEY") echo provider ;;
      esac
    done \
  | awk '{n[$1]++} END {printf "marker (control): %d, consumer key: %d, Anthropic key: %d\n", n["marker"], n["consumer"], n["provider"]}'
}
```

**Verified on 2026-10-15:**

```text
TASK_STATE_COMPLETED	OK
suspended (polled 1s after the reply)
snapshot scope: SNAPSHOT_CONTENT_SCOPE_FULL
marker (control): 88, consumer key: 0, Anthropic key: 0
```

The marker is there, many times over: the session is in the snapshot, in memory as well as in
its database. Neither key is. The agent never held the Anthropic key, and the consumer key
is added by Substrate's egress gateway after the request leaves the sandbox (Step 18), so neither
reaches the actor's memory. A marker count of 0 means the search failed, not that the snapshot is
clean: check that `zstd` is installed and that the snapshot scope is `FULL`.

What the store does hold is every session's text, and Step 22 is about who can read it.

### Step 18: The agent never holds a key

*Runtimes: kagent and Claude Code.*

Both agents authenticate to the gateway with the consumer key, and neither process ever sees it.
Resume one session from each runtime:

```bash run id=step-18-resume
kubectl-ate resume actor "session-${FIRST_CONTEXT}" -a kagent >/dev/null
kubectl-ate resume actor "session-${CLAUDE_CONTEXT}" -a kagent >/dev/null
kubectl-ate get actors -a kagent | grep -E "NAME|${FIRST_CONTEXT}|${CLAUDE_CONTEXT}"
```

**Verified on 2026-10-15:**

```text
ATESPACE   NAME                                           TEMPLATE                                    STATE                   WORKER POD                               WORKER IPS    VERSION   AGE
kagent     session-01a1406e-5e96-7cc6-a31d-3aa1201c7430   kagent/assistant-claude-code-653337c7bc90   ACTOR_STATE_RUNNING     kagent/kagent-default-5d55b7f7c9-mch2s   10.244.0.23   7         8s
kagent     session-01a1406d-c370-75c7-9185-598857b5ea1a   kagent/assistant-e1af965cdabf               ACTOR_STATE_RUNNING     kagent/kagent-default-5d55b7f7c9-fsrrb   10.244.0.22   11        48s
```

What each agent process has for a credential:

```bash run id=step-18-environment
for conv in "$FIRST_CONTEXT" "$CLAUDE_CONTEXT"; do
  echo "-- session-${conv}"
  sandbox_exec "$conv" cat /proc/1/environ | tr '\0' '\n' | grep -E '^(ANTHROPIC_API_KEY|KAGENT_CREDENTIAL_)' || true
done
```

**Verified on 2026-10-15:**

```text
-- session-01a1406d-c370-75c7-9185-598857b5ea1a
ANTHROPIC_API_KEY=kagent-credential-injected
-- session-01a1406e-5e96-7cc6-a31d-3aa1201c7430
ANTHROPIC_API_KEY=kagent-credential-injected
```

The placeholder, in both. Now look for the real consumer key anywhere in either sandbox's
filesystem. The session's own text is the control: it is in the runtime's database, so a search
that cannot find it proves nothing.

```bash run id=step-18-search
# count_in_sandbox <session id> <string>: lines of the sandbox's filesystem containing the string.
count_in_sandbox() {
  sandbox_exec "$1" tar -cf - --exclude=./proc --exclude=./sys -C / . | LC_ALL=C grep -a -c -F "$2" || true
}
for pair in "${FIRST_CONTEXT}:up and running" "${CLAUDE_CONTEXT}:claude code harness"; do
  conv=${pair%%:*}; control=${pair#*:}
  echo "-- session-${conv}: consumer key $(count_in_sandbox "$conv" "$AGENT_CONSUMER_KEY"), control \"${control}\" $(count_in_sandbox "$conv" "$control")"
done
```

**Verified on 2026-10-15:**

```text
-- session-01a1406d-c370-75c7-9185-598857b5ea1a: consumer key 0, control "up and running" 1
-- session-01a1406e-5e96-7cc6-a31d-3aa1201c7430: consumer key 0, control "claude code harness" 6
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

**Verified on 2026-10-15:**

```text
injected
```

The gateway answered a request whose key, as sent, was the placeholder. Substrate's egress gateway
replaced it with the consumer key on the way out, as the egress policy in Step 9 said it would. An
attacker who takes over the agent process gets the placeholder.

> [!NOTE]
> **The agent never holds the key; the kagent controller does.** The controller reads the Secrets it turns into egress bindings, and sends MCP header values itself during tool discovery (Step 20). Restrict who can read the `kagent` namespace's Secrets and exec into its pods.

### Step 19: Test the egress allowlist from inside

*Runtimes: kagent and Claude Code, which differ here.*

Each actor can reach only the destinations kagent put in its egress policy. Try three from
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

**Verified on 2026-10-15:**

```text
-- session-01a1406d-c370-75c7-9185-598857b5ea1a
  https://example.com/                                                             HTTP/1.1 403 Forbidden
  https://api.anthropic.com/v1/models                                              HTTP/1.1 401 Unauthorized
  http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/messages      HTTP/1.1 401 Unauthorized
-- session-01a1406e-5e96-7cc6-a31d-3aa1201c7430
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
kubectl get namespace mcp-tools >/dev/null 2>&1 || kubectl create namespace mcp-tools
: "${MCP_SERVER_TOKEN:=$(openssl rand -hex 24)}"; export MCP_SERVER_TOKEN
kubectl delete secret deployment-codes-token -n mcp-tools --ignore-not-found
printf '%s' "$MCP_SERVER_TOKEN" | kubectl create secret generic deployment-codes-token \
  -n mcp-tools --from-file=MCP_TOKEN=/dev/stdin
kubectl delete configmap deployment-codes-server -n mcp-tools --ignore-not-found
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

**Verified on 2026-10-15:**

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
kubectl delete secret deployment-codes-gw-auth -n agentgateway-system --ignore-not-found
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
  template:
    ref:
      name: deployment-helper
  harnessRef:
    name: kagent-adk
EOF
kubectl wait remotemcpserver/deployment-codes -n kagent --for=condition=Accepted --timeout=120s
kubectl get remotemcpserver deployment-codes -n kagent -o jsonpath='{.status.conditions[0].reason}: {.status.conditions[0].message}{"\n"}'
kubectl wait agent/deployment-helper -n kagent --for=condition=Ready --timeout=300s
```

**Verified on 2026-10-15:**

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

Ask for a code, then read the session's egress policy and the MCP server's log:

```bash run id=step-20-tool-call
TURN=$(kagent_send deployment-helper "What is the deployment code for the service payments? Use the tool.")
echo "$TURN"
echo "-- egress policy:"
kubectl-ate get egress-policy "session-$(echo "$TURN" | cut -f2)" --atespace kagent -o json \
  | jq -r '.rules[] | to_entries[0] | "\(.key)\t\(.value.hostnames[0]):\(.value.ports.numbers[0])\t\([.value.effects.replaceHeaders[]? | "\(.header) <- \(.credentialUri)"] | join(", "))"'
echo "-- MCP server log for the tool call (gateway pod: $(kubectl get pod -n agentgateway-system -l gateway.networking.k8s.io/gateway-name=agentgateway-proxy -o jsonpath='{.items[0].status.podIP}')):"
kubectl logs -n mcp-tools deployment/deployment-codes | jq -c 'select(.rpc == "tools/call") | {t, src, rpc, tool, auth}' | tail -1
```

**Verified on 2026-10-15:**

```text
TASK_STATE_COMPLETED	01a1406e-e73e-7e76-b470-c610e8e806fc	The deployment code for the **payments** service is **K7-teal-otter-0429**.
-- egress policy:
http	agentgateway-proxy.agentgateway-system.svc.cluster.local:80	x-api-key <- ate-secret://k8s.io/default/kagent/kagent-gateway-consumer-key/api-key
http	kagent-controller.kagent.svc:8083	
https	api.anthropic.com:443	
-- MCP server log for the tool call (gateway pod: 10.244.0.25):
{"t":"16:39:33","src":"10.244.0.25","rpc":"tools/call","tool":"lookup_code","auth":"bearer-match"}
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
kubectl --context "kind-${KIND_CLUSTER_NAME}" port-forward --address 127.0.0.1 -n agentgateway-system deployment/agentgateway-proxy 18082:15020 >/dev/null 2>&1 &
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

**Verified on 2026-10-15:**

```text
TASK_STATE_COMPLETED	01a1406f-031f-77e1-8983-6b70cec6bdbd	attributed
TASK_STATE_COMPLETED	01a1406f-05e8-7416-8901-90d427a10490	attributed
gen_ai_token_type="output" user_id="assistant-agent" team="team-agents"  65.0
gen_ai_token_type="input" user_id="assistant-agent" team="team-agents"  710.0
gen_ai_token_type="input_cache_read" user_id="assistant-agent" team="team-agents"  28778.0
gen_ai_token_type="input_cache_write" user_id="assistant-agent" team="team-agents"  2698.0
```

Every token is attributed to the key's `user` and `group`, so spend is per team or per agent key,
not per person: the kagent user behind a session is not passed to the gateway.

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

**Verified on 2026-10-15:**

```text
enterpriseagentgatewaybudget.enterpriseagentgateway.solo.io/team-budgets patched
TASK_STATE_FAILED	01a1406f-2c40-7c86-a9cb-940b5e3a5ca8	llm error response (code STREAM_ERROR): "POST \"http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/messages\": 429 Too Many Requests rate limit exceeded"
enterpriseagentgatewaybudget.enterpriseagentgateway.solo.io/team-budgets patched
TASK_STATE_COMPLETED	01a1406f-46a0-757c-a453-871a65fef15e	back under budget
```

The blocked turn fails in the agent with the gateway's `429`. The runtime retries a blocked call
three times before giving up, and each attempt counts as a request, though none consumes tokens.

### Step 22: Replace the snapshot store's credentials and fence it

*Runtime: kagent.*

Step 13 showed the problem: the store holds every session in readable form, and the chart runs
it with fixed default credentials that anyone in the cluster can use. Two changes close it.

**First, non-default credentials.** The chart cannot read them from a Secret: it writes
`rustfs.accessKey` and `rustfs.secretKey` as plain values into the RustFS, bucket-init, atelet and
ate-api pod specs. So generate them in your shell and pass them at upgrade time, never in a values
file you commit. `--reuse-values` keeps everything Step 5 set. The completed bucket-init Job goes
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
for r in $(kubectl get deployment,daemonset -n ate-system -o name); do
  kubectl rollout status "$r" -n ate-system --timeout=300s
done
kubectl wait --for=condition=complete job/rustfs-bucket-init -n ate-system --timeout=180s
# atelet restarted: wait until every worker has registered with it again before sending a turn.
for i in $(seq 1 60); do
  want=$(kubectl get pods -n kagent -o name | grep -c '/kagent-default-')
  have=$(kubectl-ate get workers | awk 'NR > 1 && $4 != "0/0" {print $(NF-1)}' | while read -r pod; do
    kubectl get pod -n kagent "${pod#kagent/}" >/dev/null 2>&1 && echo registered; done | grep -c registered || true)
  [ "$have" -ge "$want" ] && break
  sleep 5
done
echo "workers registered: ${have} of ${want}"
```

**Verified on 2026-10-15:**

```text
job.batch "rustfs-bucket-init" deleted from ate-system namespace
Release "substrate" has been upgraded. Happy Helming!
NAME: substrate
STATUS: deployed
REVISION: 2
DESCRIPTION: Upgrade complete
(Helm's release notes omitted)
Waiting for deployment "ate-api-server" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "ate-api-server" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "ate-api-server" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "ate-api-server" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "ate-api-server" rollout to finish: 1 old replicas are pending termination...
deployment "ate-api-server" successfully rolled out
deployment "ate-controller" successfully rolled out
deployment "atenet-egress" successfully rolled out
deployment "atenet-router" successfully rolled out
deployment "k8s-credential-provider" successfully rolled out
deployment "rustfs" successfully rolled out
daemon set "atelet" successfully rolled out
job.batch/rustfs-bucket-init condition met
workers registered: 2 of 2
```

The block waits for every rollout in `ate-system` and for the workers to register again before
going on: a turn sent while atelet is still restarting can come back with no task. The values go
through stdin, so they never appear in a command line, but Helm keeps them in its
release Secret and they are in the four pod specs. Anyone who can read those still has them, which
is why the second change matters more.

Prove the defaults no longer work, and that sessions suspended under the old credentials are
still readable under the new ones:

```bash run id=step-22-credentials-check
echo "-- default credentials:"
S3_ACCESS_KEY=rustfsadmin S3_SECRET_KEY=rustfsadmin snapshot_ls "kagent/" | tail -2
echo "-- Step 9's session, suspended before the change:"
kagent_send assistant "What exact phrase did I ask you to reply with in my first message? Answer with only that phrase." "$FIRST_CONTEXT"
```

**Verified on 2026-10-15:**

```text
-- default credentials:

An error occurred (InvalidAccessKeyId) when calling the ListObjectsV2 operation: The Access Key Id you provided does not exist in our records.
-- Step 9's session, suspended before the change:
TASK_STATE_COMPLETED	01a1406d-c370-75c7-9185-598857b5ea1a	up and running
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
echo "-- a session still resumes:"
kagent_send assistant "Reply with exactly: fenced" "$FIRST_CONTEXT"
```

**Verified on 2026-10-15:**

```text
-- snapshot_ls with the new credentials, from a pod that is not atelet or ate-api:

Connect timeout on endpoint URL: "http://rustfs.ate-system.svc:9000/ate-snapshots?list-type=2&prefix=kagent%2F&encoding-type=url"
-- a session still resumes:
TASK_STATE_COMPLETED	01a1406d-c370-75c7-9185-598857b5ea1a	fenced
```

Correct credentials, wrong pod, no connection. `snapshot_ls` and `snapshot_cat` no longer work on
this cluster; atelet and ate-api are unaffected.

> [!NOTE]
> **This fences the store; it does not encrypt it.** Substrate sends no server-side encryption parameters, and the bundled store has no encryption setting. On an external store, only the bucket's own default encryption would apply. An external store is also only half supported on this release: atelet can take its endpoint and credentials from a Secret, ate-api cannot through the chart. The chart can annotate ate-api's ServiceAccount (`ateApi.serviceAccountAnnotations`) for a cloud's workload identity, which removes the need for keys on a store that accepts it (read from the chart, not tested).

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
: "${KEYCLOAK_ADMIN_PASSWORD:=$(openssl rand -hex 16)}"; export KEYCLOAK_ADMIN_PASSWORD
: "${KAGENT_OIDC_CLIENT_SECRET:=$(openssl rand -hex 24)}"; export KAGENT_OIDC_CLIENT_SECRET
# ui_password NAME: keep NAME if it is set, otherwise generate it; save it either way, replacing any older line.
ui_password() {
  local how=reused
  if ! eval "[ -n \"\${$1:-}\" ]"; then eval "export $1=$(openssl rand -hex 12)"; how=generated; fi
  ( umask 077; touch "$KAGENT_UI_CREDENTIALS_FILE"
    { grep -v "^$1=" "$KAGENT_UI_CREDENTIALS_FILE" || true; eval "printf '%s=%s\n' $1 \"\$$1\""; } > "$KAGENT_UI_CREDENTIALS_FILE.new"
    mv "$KAGENT_UI_CREDENTIALS_FILE.new" "$KAGENT_UI_CREDENTIALS_FILE" )
  echo "$1: ${how}, saved"
}
ui_password KAGENT_ADMIN_PASSWORD
ui_password KAGENT_WRITER_PASSWORD
ui_password KAGENT_READER_PASSWORD
: "${KAGENT_NOROLE_PASSWORD:=$(openssl rand -hex 12)}"; export KAGENT_NOROLE_PASSWORD
echo "UI passwords are in: ${KAGENT_UI_CREDENTIALS_FILE}"
```

Each value already set in your shell is kept, so the block is safe to run again. The three users you
sign in to the UI as are saved either way to `KAGENT_UI_CREDENTIALS_FILE`, readable only by you:
`~/.kagent-ui-credentials`, or `auto-build/.env.local` when `auto-build/run.sh` runs the guide. The
last line prints the path; nothing prints a password. In a new shell, `set -a; .
~/.kagent-ui-credentials; set +a` brings them back. `norole` exists only for the scripted check in
Step 24 and is not saved.

The realm is below: three clients (`kagent-backend` for the controller, `kagent-ui` for the browser
with PKCE, and `kagent-cli` for scripts, with the password grant on and the client **disabled**),
groups `admins`, `writers` and `readers`, and four users. The block fills in its five values,
writes it to a file only you can read, and refuses to go on if any value is empty, the file is
empty, or a placeholder is left. Only then does it create the Secrets, replacing any from an
earlier attempt:

```bash run id=keycloak-realm
kubectl get namespace keycloak >/dev/null 2>&1 || kubectl create namespace keycloak
REALM_FILE=$(umask 077; mktemp)
cat > "$REALM_FILE" <<EOF
{
  "realm": "kagent",
  "enabled": true,
  "sslRequired": "none",
  "groups": [
    {
      "name": "admins"
    },
    {
      "name": "writers"
    },
    {
      "name": "readers"
    }
  ],
  "clients": [
    {
      "clientId": "kagent-backend",
      "name": "kagent controller (confidential)",
      "enabled": true,
      "publicClient": false,
      "secret": "${KAGENT_OIDC_CLIENT_SECRET}",
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "redirectUris": [
        "http://localhost:${KAGENT_UI_PORT}/callback"
      ],
      "webOrigins": [
        "http://localhost:${KAGENT_UI_PORT}"
      ],
      "attributes": {
        "post.logout.redirect.uris": "http://localhost:${KAGENT_UI_PORT}"
      },
      "protocolMappers": [
        {
          "name": "Groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "userinfo.token.claim": "true",
            "claim.name": "Groups"
          }
        }
      ]
    },
    {
      "clientId": "kagent-ui",
      "name": "kagent UI (public, PKCE)",
      "enabled": true,
      "publicClient": true,
      "standardFlowEnabled": true,
      "directAccessGrantsEnabled": false,
      "redirectUris": [
        "http://localhost:${KAGENT_UI_PORT}/callback"
      ],
      "webOrigins": [
        "http://localhost:${KAGENT_UI_PORT}"
      ],
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "http://localhost:${KAGENT_UI_PORT}"
      },
      "protocolMappers": [
        {
          "name": "Groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "userinfo.token.claim": "true",
            "claim.name": "Groups"
          }
        }
      ]
    },
    {
      "clientId": "kagent-cli",
      "name": "kagent scripts and CLI (public, password grant; lab only, disabled until Step 23 enables it)",
      "enabled": false,
      "publicClient": true,
      "standardFlowEnabled": false,
      "directAccessGrantsEnabled": true,
      "protocolMappers": [
        {
          "name": "Groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-group-membership-mapper",
          "config": {
            "full.path": "false",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "userinfo.token.claim": "true",
            "claim.name": "Groups"
          }
        }
      ]
    }
  ],
  "users": [
    {
      "username": "admin",
      "email": "admin@example.com",
      "emailVerified": true,
      "firstName": "Admin",
      "lastName": "User",
      "enabled": true,
      "groups": [
        "/admins"
      ],
      "credentials": [
        {
          "type": "password",
          "value": "${KAGENT_ADMIN_PASSWORD}",
          "temporary": false
        }
      ]
    },
    {
      "username": "writer",
      "email": "writer@example.com",
      "emailVerified": true,
      "firstName": "Writer",
      "lastName": "User",
      "enabled": true,
      "groups": [
        "/writers"
      ],
      "credentials": [
        {
          "type": "password",
          "value": "${KAGENT_WRITER_PASSWORD}",
          "temporary": false
        }
      ]
    },
    {
      "username": "reader",
      "email": "reader@example.com",
      "emailVerified": true,
      "firstName": "Reader",
      "lastName": "User",
      "enabled": true,
      "groups": [
        "/readers"
      ],
      "credentials": [
        {
          "type": "password",
          "value": "${KAGENT_READER_PASSWORD}",
          "temporary": false
        }
      ]
    },
    {
      "username": "norole",
      "email": "norole@example.com",
      "emailVerified": true,
      "firstName": "No",
      "lastName": "Role",
      "enabled": true,
      "groups": [],
      "credentials": [
        {
          "type": "password",
          "value": "${KAGENT_NOROLE_PASSWORD}",
          "temporary": false
        }
      ]
    }
  ]
}
EOF
MISSING=""
for v in KAGENT_OIDC_CLIENT_SECRET KAGENT_ADMIN_PASSWORD KAGENT_WRITER_PASSWORD KAGENT_READER_PASSWORD \
         KAGENT_NOROLE_PASSWORD KEYCLOAK_ADMIN_PASSWORD; do
  eval "[ -n \"\${$v:-}\" ]" || MISSING="$MISSING $v"
done
if [ -n "$MISSING" ] || [ ! -s "$REALM_FILE" ] || grep -q '\${' "$REALM_FILE"; then
  echo "realm not created: empty:${MISSING:- none}; placeholders left: $(grep -c '\${' "$REALM_FILE" || true). Run keycloak-secrets first." >&2
  false
else
  kubectl delete secret keycloak-admin keycloak-realm -n keycloak --ignore-not-found
  printf '%s' "$KEYCLOAK_ADMIN_PASSWORD" | kubectl create secret generic keycloak-admin \
    -n keycloak --from-file=password=/dev/stdin
  kubectl create secret generic keycloak-realm -n keycloak --from-file=realm.json="$REALM_FILE"
  echo "realm: $(jq -r '"\(.clients | length) clients, \(.users | length) users"' "$REALM_FILE"), $(wc -c < "$REALM_FILE" | tr -d ' ') bytes"
fi
rm -f "$REALM_FILE"
```

**Verified on 2026-10-15:**

```text
namespace/keycloak created
secret/keycloak-admin created
secret/keycloak-realm created
realm: 3 clients, 4 users, 4284 bytes
```

> [!WARNING]
> **An empty or half-filled realm would fail silently**: Keycloak never becomes ready, and nothing in kagent points at the cause. That is why the block checks before it creates anything. To start Step 23 over after a half-finished attempt, `kubectl delete namespace keycloak` and run it again from `keycloak-secrets`; Keycloak reads the realm only when it first starts.

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

**Verified on 2026-10-15:**

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
pkill -f "kubectl --context kind-${KIND_CLUSTER_NAME} port-forward .*-n keycloak " 2>/dev/null || true
kubectl --context "kind-${KIND_CLUSTER_NAME}" port-forward --address 127.0.0.1 -n keycloak service/keycloak ${KEYCLOAK_PORT}:${KEYCLOAK_PORT} >/dev/null 2>&1 &
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

**Verified on 2026-10-15:**

```text
workstation: http://keycloak.localhost:18080/realms/kagent
cluster:     http://keycloak.localhost:18080/realms/kagent
```

Two identical lines, or the controller will reject every token. The cluster side is retried until
the CoreDNS change has arrived; if it never resolves, check the rewrite with `kubectl get configmap
coredns -n kube-system -o yaml`. Then switch kagent to the issuer.
The client secret goes in a Secret; `--reuse-values` keeps everything Step 5 set:

```bash run id=helm-kagent-oidc
: "${KAGENT_OIDC_CLIENT_SECRET:?is empty: it was generated in another shell. Read it back first (below).}" && {
kubectl delete secret kagent-enterprise-oidc-secret -n kagent --ignore-not-found
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
}
```

**Verified on 2026-10-15:**

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
> **An empty client secret takes the controller down.** The secrets from the start of this step exist only in the shell that generated them. With an empty `KAGENT_OIDC_CLIENT_SECRET` the Secret is created empty, the upgrade rolls a controller that crash-loops with `OIDC client secret must not be empty`, and `--wait` fails with `Progress deadline exceeded`; the old controller keeps serving meanwhile. If the guard stops you, read the secrets back from the realm with the block below, then run the block above again; it replaces any Secret an earlier attempt created.

**Only if the guard above stopped you.** This reads back only the values your shell does not have, so it changes nothing otherwise:

```bash run id=step-23-read-back-secrets when=manual
if [ -z "${KAGENT_OIDC_CLIENT_SECRET:-}" ]; then
  export KEYCLOAK_ADMIN_PASSWORD=$(kubectl get secret keycloak-admin -n keycloak -o jsonpath='{.data.password}' | base64 --decode)
  REALM=$(kubectl get secret keycloak-realm -n keycloak -o jsonpath='{.data.realm\.json}' | base64 --decode)
  export KAGENT_OIDC_CLIENT_SECRET=$(printf '%s' "$REALM" | jq -r '.clients[] | select(.clientId == "kagent-backend") | .secret')
  for u in admin writer reader norole; do
    export "KAGENT_$(echo "$u" | tr '[:lower:]' '[:upper:]')_PASSWORD=$(printf '%s' "$REALM" | jq -r --arg u "$u" '.users[] | select(.username == $u) | .credentials[0].value')"
  done
  echo "Keycloak values read back; run helm-kagent-oidc again"
fi
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

**Verified on 2026-10-15:**

```text
token from kagent-cli while disabled: invalid_client
enable kagent-cli: HTTP 204
token from kagent-cli once enabled:  issued
```

Disabling it again is in Before production, for when you are done scripting against this cluster.

These helpers replace Step 9's: `kagent_token` uses the
`kagent-cli` client's password grant, as the user in `KAGENT_USER` (default `writer`), and
`kagent_send` also prints a refused request's error, whether it comes back as JSON or as a bare
HTTP status:

```bash run id=step-23-helpers
kagent_token() {
  local user=${KAGENT_USER:-writer} pw resp
  case "$user" in
    admin) pw=$KAGENT_ADMIN_PASSWORD ;; writer) pw=$KAGENT_WRITER_PASSWORD ;;
    reader) pw=$KAGENT_READER_PASSWORD ;; norole) pw=$KAGENT_NOROLE_PASSWORD ;;
  esac
  resp=$(curl -sS --max-time 10 -X POST "http://keycloak.localhost:${KEYCLOAK_PORT}/realms/kagent/protocol/openid-connect/token" \
    -d grant_type=password -d client_id=kagent-cli -d "username=${user}" --data-urlencode "password=${pw}")
  printf '%s' "$resp" | jq -er '.access_token // empty' 2>/dev/null && return 0
  echo "kagent_token: Keycloak refused ${user}: $(printf '%s' "$resp" | jq -r '(.error // "no response") + (if .error_description then ": " + .error_description else "" end)' 2>/dev/null || printf '%s' "$resp" | head -c 200)" >&2
  return 1
}

# kagent_send <agent> <message> [contextId]
kagent_send() {
  local ctx="" out code body
  [ -n "${3:-}" ] && ctx="\"contextId\":\"$3\","
  out=$(curl -sS --max-time 300 -w '\n%{http_code}' -X POST "http://127.0.0.1:${KAGENT_API_PORT}/agents/kagent/$1" \
    -H "Authorization: Bearer $(kagent_token)" -H 'Content-Type: application/json' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":\"1\",\"method\":\"SendMessage\",\"params\":{\"message\":{\"messageId\":\"$(openssl rand -hex 8)\",${ctx}\"role\":\"ROLE_USER\",\"parts\":[{\"text\":\"$2\"}]}}}")
  code=${out##*$'\n'}; body=${out%$'\n'*}
  printf '%s' "$body" | jq -r 'if .error then "REFUSED\t\(.error.message)" elif .result.task then (.result.task | "\(.status.state)\t\(.contextId)\t\(((.artifacts[-1].parts // .status.message.parts // []) | map(.text // "") | join("")) | gsub("\\s*\n\\s*"; " "))") else "NO_TASK\t\tno task in the response: \(tostring | .[0:200])" end' 2>/dev/null \
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

**Verified on 2026-10-15:**

```text
bundled login /autoauth/token: 405
API with no token:             401
writer turn:                   TASK_STATE_COMPLETED	01a14071-7a4a-743d-955a-2a242303a273	keycloak token accepted
```

**In the browser.** Open `http://localhost:14000` (or your `KAGENT_UI_PORT`). The UI redirects to
Keycloak at `keycloak.localhost`; sign in as `writer` with `KAGENT_WRITER_PASSWORD` from
`~/.kagent-ui-credentials` (`auto-build/.env.local` under auto-build). To copy it without displaying
it: `grep '^KAGENT_WRITER_PASSWORD=' ~/.kagent-ui-credentials | cut -d= -f2- | tr -d '\n' | pbcopy`.
The UI
returns signed in, with the agents listed. Sign out returns you to the UI. Verified on this release
in a browser, with the same realm and settings; the browser half is not part of the scripted run.

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

**Verified on 2026-10-15:**

```text
admin   TASK_STATE_COMPLETED	01a14071-7e98-7974-b244-1a22da4b8dae	hello admin
writer  TASK_STATE_COMPLETED	01a14071-81aa-7401-8f27-6194efce1c30	hello writer
reader  REFUSED	permission denied
norole  REFUSED	HTTP 401 Unauthorized
```

| User | Group | Result |
|---|---|---|
| `admin` | `admins` | Chats |
| `writer` | `writers` | Chats |
| `reader` | `readers` | Refused: can open the agent, cannot start or continue a session |
| `norole` | none | Refused as unauthenticated |

In the UI, `reader` sees the agent and its chat list, with every session listed and none of them
openable: the list carries a note that sessions started by somebody else cannot be opened, renamed
or deleted, and that a share link from the person who started one is the only other way in. A
session belongs to the user who started it: another user opening its address gets "Session not
found". (Observed on this release in a browser, as `reader` and as `writer`.)

> [!WARNING]
> **Every signed-in user can see every user's session list for an agent.** The UI's chat list asks for all creators' sessions, and every role, `reader` included, is allowed that (observed on this release in a browser): it lists other users' session IDs, who started them and when. Their contents are protected. Treat who-talks-to-which-agent as visible to everyone with access to the UI.

**Sign in.** With the forwards from Step 9 (`forwards`) and Step 23 (`keycloak-forward`) running,
open `http://localhost:${KAGENT_UI_PORT}` and sign in as `admin`, `writer` or `reader`. Their
passwords are in `~/.kagent-ui-credentials`, or `auto-build/.env.local` when `auto-build/run.sh`
built the cluster: load them into a new shell with `set -a; . ~/.kagent-ui-credentials; set +a`, or
copy one without displaying it with `grep '^KAGENT_READER_PASSWORD=' ~/.kagent-ui-credentials | cut
-d= -f2- | tr -d '\n' | pbcopy`. After a break or a node restart, `auto-build/demo-ui.sh` brings
the UI back. When you are done, or before switching to another cluster, `stop_forwards` closes this
cluster's forwards and frees their ports.

**What you now have:** the agent holds no key and can reach only what its policy names; MCP tools and
the model both sit behind one gateway that holds their credentials, attributes every token and
enforces a budget; session data is readable only by the two components that need it; and every
caller of the UI and API is authenticated, with roles. What you have not done is measure what any of
this costs to run. Scale does that.

## SCALE

Isolate made each session its own sandbox. This section is about what that costs: what a
session holds while it waits, what it holds while it runs, and how to size the worker pool from
that.

**What you are going to do:** compare Substrate with running agents as pods, watch memory follow
turns in flight on your own cluster, measure what suspended sessions leave behind, size the
worker pool, and change it safely.

**What you will have that you did not have before:** numbers to size a platform with, the method to
re-measure them on your own nodes, and a way to change the worker pool without losing capacity.

The steps you run here make five model calls in total and finish in a few minutes. The larger figures
are reference measurements from longer runs on the same reference environment, labelled as such.

**Verified on:** two certification runs, each on a kind cluster created fresh for it (kind 0.32.0, `kindest/node:v1.35.0`), beside one other cluster on the same Docker host, 2026-10-15: `certz` under zsh, 16:25 to 16:34 UTC, and `certb` under bash, 16:34 to 16:43 UTC. In each, every `run` block from Step 1 to Step 31 was executed verbatim, in document order, in one uninterrupted pass of `auto-build/run.sh`, from an empty directory outside the repository, on the versions in Version support. Every output block in this guide comes from the bash pass.

### Step 25: A pod per session, a pod per agent, or Substrate

*No runtime: reference measurements.*

There are two ways to run agents as ordinary pods, and they are not the same comparison:

- **A pod per agent**: one long-lived process serves every session with that agent. It is the
  cheapest thing you can run. **It uses less memory than Substrate at every load measured**, because
  it adds almost nothing per session. What it gives up is everything Isolate built: all of an
  agent's sessions, for every user, share one process, one memory space and one kernel, and the
  process holds the model key in its environment.
- **A pod per session**: the plain-Kubernetes way to get Substrate's isolation, one sandboxed
  pod for each open session. It holds its memory whether the session is active or waiting
  for someone to reply.

Substrate is the second model without its standing memory: a session holds memory only while a
turn is running. While it waits, it is a snapshot in the store, megabytes of storage instead of tens
of megabytes of memory.

**Reference measurements.** Measured on 2026-10-14 on the reference environment: one kind node,
Kubernetes 1.35.0, Colima on Apple silicon with 6 vCPU and 12 GiB, the versions in this guide, with no
other cluster running. Memory is the node's used memory before and after (from `/proc/meminfo`),
divided by the number of units. The pod-per-session comparator is one pod of the same kagent
runtime, run eight times under gVisor through a RuntimeClass with the same gVisor build Substrate
uses, on a separate throwaway kind cluster, because Substrate's nodes do not register gVisor as a
container runtime. The same pod under runc is included as the comparator most favourable to pods.

| | Memory per unit | Storage per unit | Unit |
|---|---|---|---|
| Substrate control plane (`ate-system`, pod certificate controller) | 346.7 MiB | | Fixed, once per cluster |
| Substrate, a turn in flight | about 50 MiB | | Per running turn, released when it ends |
| Substrate, a suspended session | 0 | 1.4 MB (1 turn) to 2.5 MB (20 turns) | Per session, while it waits (Step 27) |
| Substrate, an agent | | 1.06 MB | Golden snapshot, per agent |
| Pod per session, gVisor | 59.7 MiB | | Per open session, active or not |
| Pod per session, runc (weaker isolation) | 13.4 MiB (PSS) | | Per open session, active or not |
| Pod per agent, runc | 13.4 MiB (PSS) | | Per agent |

The runc figure is the pod's proportional share of memory (PSS), not the node's: at about 13 MiB a
pod, the node's own figure moved by more than that between samples. Under gVisor the node figure
is used, the same method as Substrate's.

None of the pod figures include a turn's own cost: the kagent runtime on this release will not serve
a turn outside Substrate, so that cost could not be measured, and it can only add to the pod side.
The kagent platform itself (controller, UI, PostgreSQL, ClickHouse) is needed either way and is left
out of every figure.

**Projected from those measured constants**, at 100 open sessions with one agent:

| Turns in flight | Substrate memory | Substrate storage | Pod per session, gVisor | Pod per session, runc | Pod per agent |
|---|---|---|---|---|---|
| 5 | 0.60 GiB | 142 to 247 MB | 5.8 GiB, plus turn cost | 1.3 GiB, plus turn cost | 13 to 60 MiB, plus turn cost |
| 10 | 0.85 GiB | 142 to 247 MB | 5.8 GiB, plus turn cost | 1.3 GiB, plus turn cost | 13 to 60 MiB, plus turn cost |
| 25 | 1.58 GiB | 142 to 247 MB | 5.8 GiB, plus turn cost | 1.3 GiB, plus turn cost | 13 to 60 MiB, plus turn cost |

Substrate memory is the control plane, two idle workers at about 10 MiB each, and 50 MiB per turn
in flight. Its storage is 100 suspended sessions of 1 to 20 turns plus one golden snapshot; the pods
need none of that, and hold their memory instead.

Against equal isolation, Substrate uses less memory at every load, and the gap grows with every
session held open, because a waiting session costs megabytes of storage rather than tens of
megabytes of memory. Against runc pods, the memory break-even is around 20 turns in flight per 100 open sessions. Against a pod per agent, Substrate always costs more, and buys
isolation per session with it.

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

Start four sessions at once, each asking for a long enough answer to stay in flight for a few
seconds, and sample while they run. The loop watches the four turns by process ID, kept in an
array so bash and zsh read it the same way: the port-forwards `forwards` started are background jobs
in the same shell, so waiting for "no background jobs" would never end. In an interactive zsh, lines
such as `[2] 48213` and `[2]  + done` are its job control reporting the four turns, not errors:

```bash run id=step-26-burst
BEFORE=$(worker_total); PEAK=$BEFORE; PEAK_RUNNING=0; TURNS=()
for i in 1 2 3 4; do
  kagent_send assistant "Write about 250 words on the history of the bicycle." >/dev/null &
  TURNS+=($!)
done
in_flight() { for p in "${TURNS[@]}"; do kill -0 "$p" 2>/dev/null && return 0; done; return 1; }
while in_flight; do
  M=$(worker_total); R=$(running_actors)
  [ "$M" -gt "$PEAK" ] && PEAK=$M
  [ "$R" -gt "$PEAK_RUNNING" ] && PEAK_RUNNING=$R
done
wait "${TURNS[@]}"
sleep 5
AFTER=$(worker_total)
echo "worker memory before:  ${BEFORE} MiB, 0 turns in flight"
echo "worker memory peak:    ${PEAK} MiB, up to ${PEAK_RUNNING} turns in flight"
echo "worker memory after:   ${AFTER} MiB, running actors now: $(running_actors)"
```

**Verified on 2026-10-15:**

```text
worker memory before:  119 MiB, 0 turns in flight
worker memory peak:    340 MiB, up to 4 turns in flight
worker memory after:   121 MiB, running actors now: 0
```

Memory rises with the turns in flight and falls back when they end. The four sessions are
still there, suspended, and hold no memory now. A sample can miss the very top of the curve, so treat
the peak as a lower bound. The reference run held actors running deliberately and measured about
50 MiB each: 47 to 55 MiB per actor from 2 to 64 running, on one worker, 2026-10-14.

Those turns also used CPU, which is what actually limits a node. In a reference run on 1.0.0-alpha8
(2026-10-11; not repeated on this release), with real model calls on one worker, the platform's own
share of a turn's latency stayed under twice its single-turn value up to **4 concurrent turns per
6-vCPU node**, and doubled beyond that. Model time stayed flat; the growth was restore time,
consistent with CPU contention (CPU was not sampled directly). No turn failed at any concurrency up
to 32.

### Step 27: What suspended sessions leave behind

*Runtime: kagent. No model calls.*

A suspended session holds no memory, but it is not free. It leaves data in three places:

```bash run id=step-27-storage
echo "sessions in Substrate: $(kubectl-ate get actors -a kagent -o json | jq '.actors | length')"
PV_PATH=$(kubectl get pv "$(kubectl get pvc rustfs-data -n ate-system -o jsonpath='{.spec.volumeName}')" \
  -o jsonpath='{.spec.hostPath.path}{.spec.local.path}')
echo "-- snapshot store, on disk: $(docker exec "${KIND_CLUSTER_NAME}-control-plane" du -sh "$PV_PATH" | cut -f1) of ${SNAPSHOT_STORE_SIZE}"
echo "-- session snapshots atelet uploaded in the last 15 minutes (uncompressed, MB per snapshot):"
kubectl logs -n ate-system daemonset/atelet --since=15m \
  | jq -r 'select(.msg == "Compressed zstd upload" and (.object | test("/atespaces/kagent/actors/")))
      | [(.object | split("/snapshots/")[1] | split("/")[0]), .logical_bytes] | @tsv' \
  | awk '{t[$1] += $2} END {for (k in t) printf "%.1f\n", t[k] / 1e6}' | sort -n | uniq -c
echo "-- PostgreSQL, by schema:"
kubectl exec -n kagent deployment/kagent-postgresql -c postgresql -- psql -U postgres -d kagent -At -c \
  "select schemaname || ': ' || pg_size_pretty(sum(pg_total_relation_size(relid))) from pg_statio_user_tables where schemaname in ('kagent','substrate','enterprise') group by schemaname order by 1"
echo "-- actor directories on the node: $(docker exec "${KIND_CLUSTER_NAME}-control-plane" sh -c 'ls /var/lib/ate/actors | wc -l') ($(docker exec "${KIND_CLUSTER_NAME}-control-plane" du -sh /var/lib/ate/actors | cut -f1))"
```

**Verified on 2026-10-15:**

```text
sessions in Substrate: 15
-- snapshot store, on disk: 28M of 2Gi
-- session snapshots atelet uploaded in the last 15 minutes (uncompressed, MB per snapshot):
   2 11.7
   1 11.9
   1 12.6
   1 13.5
   1 15.3
   1 15.5
   1 15.6
   1 15.9
-- PostgreSQL, by schema:
kagent: 2608 kB
substrate: 824 kB
-- actor directories on the node: 19 (764K)
```

The store's directory on the node is the actual compressed size, which the fence from Step 22 does
not affect. Each upload line is one checkpoint: a session's memory image is most of it, so even
a one-turn session's snapshot is megabytes uncompressed. There are more actor directories on the
node than sessions in Substrate: the difference is sessions deleted since Step 9, whose
directories stay.

| Where | What | Grows |
|---|---|---|
| Snapshot store | The session's memory image and session data, compressed | One snapshot per session, replaced at each turn; by far the largest |
| PostgreSQL | Every task event of every session (`kagent`), and Substrate's actor records (`substrate`) | With every turn |
| The worker node | One directory per actor ever placed there | One per session, never removed (Step 14) |

**Reference measurements** for short turns, three sessions at each length, 2026-10-14. The
store figure is the compressed objects of the session's one snapshot; the PostgreSQL figures are
the growth across the three, divided by three, in whole 8 KiB pages, so they are coarse:

| Turns in the session | Snapshot in the store | kagent's tables | Substrate's tables | Total, with the node directory |
|---|---|---|---|---|
| 1 | 1.36 to 1.40 MB | 2.7 KB | 2.7 KB | 1.41 to 1.45 MB |
| 5 | 1.77 to 1.82 MB | 65.5 KB | 5.5 KB | 1.88 to 1.93 MB |
| 20 | 2.18 to 2.21 MB | 163.8 KB | 43.7 KB | 2.43 to 2.46 MB |

Plus about 40 KiB of node directory per session, and 1.06 MB of golden snapshot per agent. A
session that was resumed once with no turn, as in Step 12, also stores a memory image: 1.07 MB.
Prompt content dominates real sizes, so treat these as floors.

**Projected from those measured constants:** 1,000 suspended sessions need 1.4 to 2.5 GB across
the store, PostgreSQL and node directories, and 10,000 need 14 to 25 GB, while needing no memory at
all until someone sends a message. Nearly all of it is the snapshot store, so size its volume from
this (Step 5).

### Step 28: Size the worker pool for concurrent turns

*No runtime: arithmetic, with one reading from your cluster.*

What a node can run at once is set by its CPU, not by how many sessions exist. Read what your
node and workers offer:

```bash run id=step-28-capacity
echo "node CPU: $(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.cpu}'), memory: $(kubectl get nodes -o jsonpath='{.items[0].status.allocatable.memory}')"
kubectl-ate get workers
```

**Verified on 2026-10-15:**

```text
node CPU: 6, memory: 12220312Ki
NAME                                   POOL             STATE                 ACTORS   CPU   MEMORY         POD                                      AGE
fee35b75-049f-4da0-b552-1aa457e8f7a1   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-5d55b7f7c9-fsrrb   5m38s
816101c3-696b-4e33-b040-8280c0e50fe3   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-5d55b7f7c9-mch2s   5m35s
```

Each worker advertises the whole node and room for 1,000 actors, and actors request no CPU or
memory, so Substrate will place far more running actors on a worker than its node can serve well.
Nothing in admission stops it; the node's CPU does. Size for turns in flight:

| Input | Reference value |
|---|---|
| Peak turns in flight | Yours to estimate: sessions active at the busiest moment, not sessions open |
| Turns per node before latency doubles | 4 per 6-vCPU node, measured on 1.0.0-alpha8; scale with vCPU as a starting point (**projected**) |
| Memory per turn in flight | about 50 MiB, measured |
| Fixed control plane | 346.7 MiB per cluster, measured |

For 10 turns in flight at the busiest moment: 10 ÷ 4 rounds up to 3 nodes of this size, and memory
is about 0.35 GiB plus 0.5 GiB for the turns, which every node here has many times over. Storage
is sized from sessions kept, not turns: see Step 27 and Step 5. **Projected,
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

**Verified on 2026-10-15:**

```text
Allocated resources:
  (Total limits may be over 100 percent, i.e., overcommitted.)
  Resource           Requests      Limits
  --------           --------      ------
  cpu                4530m (75%)   23100m (385%)
  memory             6338Mi (53%)  22406Mi (187%)
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

**Verified on 2026-10-15:**

```text
NAME             DESIRED   REPLICAS   READY   AGE
kagent-default   3         3          3       6m19s
NAME                                   POOL             STATE                 ACTORS   CPU   MEMORY         POD                                      AGE
fee35b75-049f-4da0-b552-1aa457e8f7a1   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-5d55b7f7c9-fsrrb   5m43s
aa8862d6-61e8-41d8-b919-55cdf6f4112b   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-5d55b7f7c9-g89rs   0s
816101c3-696b-4e33-b040-8280c0e50fe3   kagent-default   WORKER_STATE_ACTIVE   0/1000   0/6   0/12220312Ki   kagent/kagent-default-5d55b7f7c9-mch2s   5m40s
deployment "kagent-controller" successfully rolled out
deployment "kagent-ui" successfully rolled out
forwards up: controller 18083, ui 14000
TASK_STATE_COMPLETED	01a14071-cd47-7a08-a8b6-44eee557207d	three workers
```

`--reuse-values` keeps everything earlier steps set, including the OIDC issuer; without it, Helm
would reset them to the chart's defaults. Make resource changes the same way: add a worker first, so
the rollout's missing worker is one you can spare, then change the resources, then remove the extra
worker.

**What you now have:** a measured picture of what sessions cost on this platform: memory per
turn in flight, storage per session waiting, a CPU limit per node, and a pool you can grow
without a gap in service.

## VALIDATE

Everything above was proved one control at a time. This section sends one session through all
of them and checks each result against the step that set it up. If something breaks later, this is
the section to run first.

**What you are going to do:** sign in, run one session that calls a model and an MCP tool, then
check the session from every side: its sandbox, its credentials, its egress, the gateway, the
MCP server, the fences, and another user's access.

**What you will have that you did not have before:** one pass that tells you whether the whole
platform still does what each step said it would, and which step to go back to when it does not.

**Verified on:** two certification runs, each on a kind cluster created fresh for it (kind 0.32.0, `kindest/node:v1.35.0`), beside one other cluster on the same Docker host, 2026-10-15: `certz` under zsh, 16:25 to 16:34 UTC, and `certb` under bash, 16:34 to 16:43 UTC. In each, every `run` block from Step 1 to Step 31 was executed verbatim, in document order, in one uninterrupted pass of `auto-build/run.sh`, from an empty directory outside the repository, on the versions in Version support. Every output block in this guide comes from the bash pass.

### Step 30: Drive one session through every control

*Runtime: kagent (agent `deployment-helper`, which calls the model and the MCP tool). One model call.*

`record` prints one check: the step that set the control up, what was checked, what was observed, and
whether that matches what the step said. It also keeps the line for Step 31:

```bash run id=step-30-helpers
# record <step> <what was checked> <observed> <expected: an extended regular expression>
record() {
  local result=FAIL
  printf '%s' "$3" | grep -qE -- "$4" && result=PASS
  VALIDATE_RESULTS="${VALIDATE_RESULTS:-}${result}|$1|$2|$3"$'\n'
  printf '%-4s  %-12s  %s: %s\n' "$result" "$1" "$2" "$3"
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

**Verified on 2026-10-15:**

```text
PASS  Step 23       Keycloak token for writer: issued
PASS  Step 23       API call with no token: HTTP 401
```

**The session.** One turn that needs both the model and the tool:

```bash run id=step-30-session
TURN=$(kagent_send deployment-helper "What is the deployment code for the service billing? Use the tool.")
export VALIDATE_CONV=$(echo "$TURN" | cut -f2)
record "Steps 8, 20" "Turn using the model and the MCP tool" "$(echo "$TURN" | cut -f1,3 | tr '\t\n' '  ')" 'TASK_STATE_COMPLETED.*K7-teal-otter-0429'
wait_suspended "$VALIDATE_CONV" >/dev/null
record "Steps 10, 11" "First restore of the session's actor" "$(actor_events "$VALIDATE_CONV" | head -1 | cut -f2,3 | tr '\t' ' ')" '^Restore timing breakdown golden/full$'
record "Step 11" "Actor state after the turn" "$(kubectl-ate get actor "session-${VALIDATE_CONV}" -a kagent -o json | jq -r .status.state)" '^ACTOR_STATE_SUSPENDED$'
```

**Verified on 2026-10-15:**

```text
PASS  Steps 8, 20   Turn using the model and the MCP tool: TASK_STATE_COMPLETED The deployment code for the billing service is **K7-teal-otter-0429**. 
PASS  Steps 10, 11  First restore of the session's actor: Restore timing breakdown golden/full
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

**Verified on 2026-10-15:**

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
kubectl --context "kind-${KIND_CLUSTER_NAME}" port-forward --address 127.0.0.1 -n agentgateway-system deployment/agentgateway-proxy 18082:15020 >/dev/null 2>&1 &
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

**Verified on 2026-10-15:**

```text
PASS  Steps 6, 7, 9  Model call at the gateway, from Substrate egress: http.status=200
PASS  Step 20       Tool call at the MCP server: source, credential: 10.244.0.25 bearer-match
PASS  Step 21       Token metric series attributed to team-agents: 4
PASS  Step 21       Budget enforcement policy: Accepted=True Attached=True
```

**The fences and the other user.** A pod that is not supposed to reach the gateway or the snapshot
store, and a reader trying to continue the writer's session:

```bash run id=step-30-fences
record "Step 7" "Another pod reaching the gateway" "$(kubectl run validate-fence -n default --rm -i --restart=Never --image=busybox:1.36 --quiet -- \
  sh -c 'wget -T 8 -O /dev/null http://agentgateway-proxy.agentgateway-system.svc.cluster.local/v1/messages 2>&1 | tail -1' < /dev/null)" 'timed out'
record "Step 22" "Another pod reaching the snapshot store" "$(snapshot_ls "kagent/" | tail -1)" '[Tt]imeout'
record "Step 24" "Reader continuing the writer's session" "$(KAGENT_USER=reader kagent_send deployment-helper "hello" "$VALIDATE_CONV" | tr '\t' ' ')" '^REFUSED'
```

**Verified on 2026-10-15:**

```text
PASS  Step 7        Another pod reaching the gateway: wget: download timed out
PASS  Step 22       Another pod reaching the snapshot store: Connect timeout on endpoint URL: "http://rustfs.ate-system.svc:9000/ate-snapshots?list-type=2&prefix=kagent%2F&encoding-type=url"
PASS  Step 24       Reader continuing the writer's session: REFUSED permission denied
```

### Step 31: Map each result to the step that set it

```bash run id=step-31-summary
printf '%s' "$VALIDATE_RESULTS" | awk -F'|' 'NF >= 3 {printf "%-4s  set in %-12s  %s\n", $1, $2, $3}'
FAILED=$(printf '%s' "$VALIDATE_RESULTS" | grep -c '^FAIL' || true)
echo "checks: $(printf '%s' "$VALIDATE_RESULTS" | grep -c '|' || true), failed: ${FAILED}"
```

**Verified on 2026-10-15:**

```text
PASS  set in Step 23       Keycloak token for writer
PASS  set in Step 23       API call with no token
PASS  set in Steps 8, 20   Turn using the model and the MCP tool
PASS  set in Steps 10, 11  First restore of the session's actor
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
PASS  set in Step 24       Reader continuing the writer's session
checks: 16, failed: 0
```

Every check names the step that set it up, so a `FAIL` sends you back to one place. Read them in the
order a turn passes through the platform:

| Order | Control | Set in | Checked by |
|---|---|---|---|
| 1 | The caller signs in to Keycloak and the controller verifies the token | Step 23 | Keycloak token, API call with no token |
| 2 | The caller's role allows the session | Step 24 | Reader continuing the writer's session |
| 3 | Substrate restores the session's actor from the agent's golden image | Steps 10, 11 | First restore |
| 4 | The agent runs in its own gVisor sandbox | Step 16 | Kernel the agent sees |
| 5 | The agent holds a placeholder, not a key | Step 18 | Model credential, consumer key in the filesystem |
| 6 | Substrate's egress gateway allows only the destinations in the policy | Step 19 | A destination outside the policy |
| 7 | Substrate's egress gateway injects the consumer key and sends the call to the enterprise gateway, which nothing else can reach | Steps 6, 7, 9 | Model call at the gateway, another pod reaching the gateway |
| 8 | The enterprise gateway attributes the tokens and enforces the team's budget | Step 21 | Token metrics, budget policy |
| 9 | Tool calls reach the MCP server through the gateway, with the server's credential added there | Step 20 | Tool call at the MCP server |
| 10 | When the turn ends, the session is checkpointed to the fenced snapshot store and suspended | Steps 11, 22 | Actor state after the turn, another pod reaching the store |

### What you built

A platform that runs agents the way a cluster runs any shared service, with the per-session
isolation an agent needs:

- **kagent** declares agents as Kubernetes resources and turns each session into a Substrate
  actor. Two runtimes, the kagent ADK and Claude Code, behind the same declaration.
- **Agent Substrate** runs each session in its own gVisor sandbox on a shared pool of workers,
  restores it from a warm snapshot when a message arrives, and suspends it when the turn ends, so a
  waiting session holds no memory.
- **Every credential stays outside the agent.** Substrate's egress gateway injects the consumer key
  on the way out, and the actor can reach only the destinations kagent put in its policy.
- **Solo Enterprise for agentgateway** is the one path to the model and to MCP tools: it holds the
  provider key and the tool server's credential, authenticates each team's consumer key, attributes
  every token and enforces budgets, and nothing else in the cluster can reach it.
- **Session data** sits in a snapshot store only atelet and ate-api can reach, under credentials
  you generated, and in a PostgreSQL that accepts logins only by workload certificate.
- **Keycloak** authenticates every caller of the UI and API, and its groups decide who can chat and
  who can only read.

What it does not do yet is in Before production.

## Before production

Each item is a limit of this release that you can plan for, with the step that shows it.

- **Disable or delete the `kagent-cli` client.** It issues tokens by password without a browser, for
  scripts. Disable it once scripting is done, with the block below, and give production scripts
  a confidential client with the client credentials grant.

```bash run id=keycloak-disable-kagent-cli when=manual
KC="http://keycloak.localhost:${KEYCLOAK_PORT}"
ADMIN_TOKEN=$(curl -sS -X POST "${KC}/realms/master/protocol/openid-connect/token" -d grant_type=password \
  -d client_id=admin-cli -d username=admin --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" | jq -r .access_token)
CLI_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/clients?clientId=kagent-cli" | jq -r '.[0].id')
curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/clients/${CLI_ID}" | jq '.enabled = false' \
  | curl -sS -o /dev/null -w 'disable kagent-cli: HTTP %{http_code}\n' -X PUT -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H 'Content-Type: application/json' --data-binary @- "${KC}/admin/realms/kagent/clients/${CLI_ID}"
```

- **Treat the snapshot store as holding every session in readable form.** Each snapshot is the
  actor's memory as well as its data, compressed, not encrypted: anything the runtime held in memory
  is in it (Step 17). Keep the NetworkPolicy from Step 22, keep the credentials out of anything you
  commit, and if you use an external store, turn on the bucket's default encryption. An external
  store can be wired for atelet but not for ate-api through the chart (Steps 13 and 22).
- **Size the snapshot store for the sessions you keep.** Each suspended session takes 1.4
  to 2.5 MB of it on this release, and each agent 1.06 MB (Step 27); nothing removes a session
  that is never resumed or deleted. Set the size at install (`rustfs.storageSize`, Step 5): changing
  it later needs a storage class that supports volume expansion, and an upgrade on one that does not
  fails and leaves the release `failed`. What Substrate does when the store is full was not tested.
- **Run PostgreSQL as a production database.** Step 4's is one pod with a 500 MiB volume, no replica
  and no backup, and it holds every session's events and Substrate's actor records. Back it up
  and size it. Its logins are workload certificates from the pod certificate controller, so its
  trust bundle is one more thing CA rotation must reach (Attachment C.10).
- **Check that a managed PostgreSQL accepts certificate logins before choosing one.** kagent and
  Substrate log in with a client certificate and no password, mapped to a database user. Managed
  PostgreSQL services may not support client-certificate authentication; this was not tested against
  any of them.
- **Rotate the CA pools before they expire.** They are valid for one year from Step 3 and nothing
  rotates them; when they expire, nothing issued from them validates. Rotation replaces the pools and
  every trust root issued from them, and restarts PostgreSQL, every Substrate component, the workers
  and the controller; the order matters (Attachment C.10). Verified on this release: new sessions and
  sessions suspended before the rotation both work after it, with their context.
- **Restart the worker pool after a node restarts.** Turns on a restarted node are refused until its
  workers are restarted and registered again (Attachment C.23).
- **Plan node disk and inodes for actor directories.** Every session ever placed on a node
  leaves a directory there, about 40 KiB, and nothing removes them (Steps 14 and 27).
- **Keep CPU headroom for worker rollouts.** A worker pool rollout removes a worker before starting
  its replacement; add a worker before changing worker resources (Step 29).
- **Restrict access to the `kagent` namespace.** The kagent controller holds the model key and MCP
  header values in its process (Step 18), and the gateway NetworkPolicy admits the controller by
  label, so anyone who can create pods there with its labels can reach the gateway (Step 7).
- **Keep the hop from Substrate's egress to the enterprise gateway inside the cluster.** It is plain
  HTTP: an `https://` base URL to a private certificate fails, because Substrate's egress trusts only
  public CAs (Step 8).
- **Budget and attribute per key.** Spend is attributed to the consumer key's user and group, not to
  the person in the session, so issue keys per team or per agent (Step 21).
- **Expect a blocked budget to look like a failed turn.** The runtime retries a `429` three times,
  each counted as a request, then fails the turn with the gateway's error (Step 21).
- **Treat who-talks-to-which-agent as visible to every signed-in user.** Any role, reader included,
  can list every user's session IDs for an agent; contents stay private (Step 24).
- **Delete an agent's sessions when you retire it.** Deleting the `Agent` leaves its template
  and golden image in place while any session exists (Step 14).
- **Use gVisor.** It is the sandbox verified here; Firecracker was not tested on this release.

When you are done with this cluster, or before working on another, close its port-forwards. This
frees ports 18080 to 18083 and 14000 and leaves forwards to other clusters alone:

```bash run id=stop-forwards when=manual
stop_forwards
```
