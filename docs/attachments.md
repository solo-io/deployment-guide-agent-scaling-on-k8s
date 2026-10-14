# Deployment Guide Attachments

Attachments to the Deployment Guide for Operating, Isolating, and Scaling Agent Workloads on
Kubernetes. Each assumes the guide's Environment setup block has been run in your shell.

## Attachment A: Keycloak for kagent

Step 23 deploys Keycloak as the reference identity provider. This attachment explains what it
deploys and why each setting is the way it is, so you can reproduce it with your own identity
provider.

### A.0 The issuer

kagent validates every token's `iss` claim against `enterprise.oidc.issuer`, byte for byte. Keycloak
writes its own configured hostname (`KC_HOSTNAME`) into `iss`. So the issuer has to be one URL that
works in two places: in your browser, which signs in, and inside the cluster, where the kagent
controller fetches the issuer's keys.

The guide uses `http://keycloak.localhost:${KEYCLOAK_PORT}/realms/kagent`:

| Where | How the name resolves | What answers |
|---|---|---|
| Your machine | Browsers and curl resolve any `*.localhost` name to 127.0.0.1 themselves | The port-forward from Step 23 |
| Inside the cluster | A CoreDNS rewrite: `keycloak.localhost` → `keycloak.keycloak.svc.cluster.local` | The Keycloak Service, which listens on the same port |

Both sides must return the same `issuer` from the discovery document. Step 23's `keycloak-forward`
block checks it. With a real identity provider on a public hostname none of this is needed: the
browser and the cluster already reach the same URL.

### A.1 What Step 23 deploys

| Resource | Purpose |
|---|---|
| Secret `keycloak/keycloak-admin` | The bootstrap admin password, generated in your shell |
| Secret `keycloak/keycloak-realm` | The realm, rendered from `infra/keycloak/kagent-realm.template.json` with generated secrets and passwords |
| Deployment and Service `keycloak/keycloak` | Keycloak in dev mode, importing the realm at start; the Service port equals the issuer's port |
| CoreDNS rewrite | Makes `keycloak.localhost` resolve inside the cluster |
| Secret `kagent/kagent-enterprise-oidc-secret` | The `kagent-backend` client secret, for the controller |
| kagent values `enterprise.oidc.*` | Issuer, client ID and secret reference; setting the issuer removes the bundled login |

Keycloak runs in dev mode with an in-memory database. **Every restart re-imports the realm from the
Secret**, so a change made through the admin console or API, such as enabling `kagent-cli` in Step
23, is lost when the pod restarts. Re-run the enabling block after a restart, or put the change in
the template.

### A.2 The realm

Three clients, all with a `Groups` mapper that puts the user's group names in a `Groups` claim:

| Client | Type | Flows | Used by |
|---|---|---|---|
| `kagent-backend` | Confidential, with a secret | Authorization code | The kagent controller |
| `kagent-ui` | Public, PKCE (S256) | Authorization code; redirect `http://localhost:14000/callback`; post-logout redirect `http://localhost:14000` | The browser |
| `kagent-cli` | Public | Password grant only. **Ships disabled** | Scripts in this guide, after Step 23 enables it |

The UI's port is substituted from `KAGENT_UI_PORT` when the realm is rendered. The post-logout
redirect has no trailing slash because the UI sends none; with one, Keycloak refuses sign-out with
"Invalid redirect uri".

Groups `admins`, `writers` and `readers`, and four users:

| User | Group | kagent role |
|---|---|---|
| `admin` | `admins` | Admin |
| `writer` | `writers` | Writer |
| `reader` | `readers` | Reader |
| `norole` | none | none: refused as unauthenticated |

### A.3 How groups become roles

The chart maps the `Groups` claim to kagent roles with a CEL expression and a map, both chart values:

| Value | Default |
|---|---|
| `enterprise.rbac.groupsClaim` | `Groups` |
| `enterprise.rbac.roleMapper` | `claims.Groups.transformList(i, v, v in rolesMap, rolesMap[v])` |
| `enterprise.rbac.roleMappings` | `admins: global.Admin`, `writers: global.Writer`, `readers: global.Reader` |

To use your own groups, change `roleMappings`; to read a different claim, change `groupsClaim` and
`roleMapper` together. A user whose groups map to no role gets `401`, not `403`.

Look at what a token actually carries:

```bash run id=a-token-claims when=manual
for user in writer norole; do
  printf '%-7s ' "$user"
  KAGENT_USER=$user kagent_token | cut -d. -f2 | tr '_-' '/+' | awk '{l=length($0)%4; if (l) $0=$0 substr("===", 1, 4-l); print}' \
    | base64 --decode 2>/dev/null | jq -c '{iss, azp, preferred_username, Groups}'
done
```

**Verified on 2026-10-12:**

```text
writer  {"iss":"http://keycloak.localhost:18080/realms/kagent","azp":"kagent-cli","preferred_username":"writer","Groups":["writers"]}
norole  {"iss":"http://keycloak.localhost:18080/realms/kagent","azp":"kagent-cli","preferred_username":"norole","Groups":null}
```

### A.4 Using your own identity provider

Register two clients with your provider, a confidential one for the controller and a public PKCE
one for the UI, with the redirect URIs from A.2 adjusted to your UI's address. Emit the user's groups
in a claim, set `enterprise.oidc.issuer`, `clientId` and the client secret's Secret, and map your
groups with `enterprise.rbac.roleMappings`. Only Keycloak was verified with this release.

### A.5 Why this is lab-only

- Dev mode, an in-memory database, and HTTP.
- Generated passwords that live only in your shell and the realm Secret.
- `kagent-cli`, a public client with the password grant, once Step 23 enables it. Disable or delete
  it when you are done (Step 23 has the command).

## Attachment B: Clusters without the beta certificates API

The guide's main path runs on a cluster where `certificates.k8s.io/v1beta1` and the
`ClusterTrustBundle`, `ClusterTrustBundleProjection` and `PodCertificateRequest` feature gates are
on. Substrate also has a compatibility mode for clusters where they are not: an issuer called
`ate-ca`, run by the pod certificate controller, replaces the native certificate APIs, and a sidecar
in each Substrate, worker and controller pod fetches and renews certificates from it.

**PostgreSQL logs in by password here, not by certificate.** The kagent chart mounts the controller's
database certificate only through a Pod Certificate projection, which this cluster cannot serve, so
Step 4's certificate-only database cannot be used. B.4 runs the same database with password logins
over TLS. The passwords are generated in your shell and stored only in the connection Secrets, and
the clients encrypt but do not verify the server's certificate (`sslmode=require`).

**What this attachment claims, and what it does not.** It was verified on kind 1.35.0 with the beta
API and the gates off. It says nothing about any managed Kubernetes service: admission, networking,
node images and identity all differ there, and none of that was tested.

Follow Up and Running with the blocks below in place of the ones they name. Everything else in Up
and Running is unchanged.

**Verified on:** a throwaway kind cluster `compat10` (kind 0.32.0, `kindest/node:v1.35.0`), beside
one other cluster on the same Docker host, 2026-10-14 16:09 to 16:20 UTC. Up and Running was run
verbatim through Step 9 with these blocks substituted (`auto-build/run.sh --attachment
docs/attachments.md --to step-9-gateway-log`), on the guide's versions; the run stopped at
`step-9-egress-policy`, which B.8 replaces, and B.8 and the gateway log check were run after it was
written.

> [!NOTE]
> **Running this beside another kind cluster** on the same Docker host can leave the new cluster's `kube-proxy` crashing with `too many open files`, and every pod then times out reaching the API server. On Colima, raise the inotify limit first. It resets when the VM restarts.

```bash run id=b-inotify when=manual
colima ssh -- sudo sysctl -w fs.inotify.max_user_instances=512
```

### B.1 The cluster (in place of `kind-cluster` and `step-1-certificates-api`)

The same node image, with the gates and the beta API left at their defaults, which are off on 1.35:

```bash run id=b-kind-cluster replaces=kind-cluster
kind create cluster --name "${KIND_CLUSTER_NAME}" --config - <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
runtimeConfig:
  "api/alpha": "false"
nodes:
  - role: control-plane
    image: ${KIND_NODE_IMAGE}
EOF
```

```bash run id=b-certificates-api replaces=step-1-certificates-api
kubectl api-resources --api-group=certificates.k8s.io
kubectl get --raw /metrics | grep -E 'kubernetes_feature_enabled\{name="(ClusterTrustBundle|ClusterTrustBundleProjection|PodCertificateRequest)"'
```

**Verified on 2026-10-12:**

```text
NAME                         SHORTNAMES   APIVERSION               NAMESPACED   KIND
certificatesigningrequests   csr          certificates.k8s.io/v1   false        CertificateSigningRequest
kubernetes_feature_enabled{name="ClusterTrustBundle",stage="BETA"} 0
kubernetes_feature_enabled{name="ClusterTrustBundleProjection",stage="BETA"} 0
kubernetes_feature_enabled{name="PodCertificateRequest",stage="BETA"} 0
```

Only `certificatesigningrequests` at `v1`, and all three gates at 0.

### B.2 The issuer's certificate and the trust ConfigMaps (after `substrate-ate-api-authentication`)

The compatibility issuer needs a TLS certificate for its own Service, and every consumer needs the
public roots it trusts, as ConfigMaps in its own namespace: Kubernetes cannot mount a ConfigMap from
another namespace. Create the issuer's certificate from a private CA whose key never leaves a
temporary directory, and copy the public roots of the two CA pools from Step 3:

```bash run id=b-ate-ca-trust after=substrate-ate-api-authentication
WORK=$(mktemp -d)
PCC=podcertificate-controller-system
SVC=ate-ca.${PCC}.svc
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
  -subj "/CN=ate-ca issuer CA" -keyout "$WORK/ca.key" -out "$WORK/ca.crt" 2>/dev/null
openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj "/CN=${SVC}" \
  -keyout "$WORK/tls.key" -out "$WORK/tls.csr" 2>/dev/null
printf 'subjectAltName=DNS:%s,DNS:%s.cluster.local\nextendedKeyUsage=serverAuth\n' "$SVC" "$SVC" > "$WORK/ext"
openssl x509 -req -in "$WORK/tls.csr" -CA "$WORK/ca.crt" -CAkey "$WORK/ca.key" -CAcreateserial \
  -days 365 -extfile "$WORK/ext" -out "$WORK/tls.crt" 2>/dev/null
kubectl create secret tls ate-ca-server-tls -n ${PCC} --cert="$WORK/tls.crt" --key="$WORK/tls.key"
for pool in pod-identity service-dns; do
  kubectl get secret ${pool}-ca-pool -n ${PCC} -o jsonpath='{.data.pool}' | base64 --decode \
    | jq -r '.CAs[].RootCertificateDER' | while read -r der; do
        printf '%s' "$der" | base64 --decode | openssl x509 -inform der -outform pem; done > "$WORK/${pool}.pem"
done
for ns in ate-system ${PCC} kagent; do
  kubectl create configmap ate-ca-server-ca -n ${ns} --from-file=ca.crt="$WORK/ca.crt"
  kubectl create configmap ate-ca-podidentity-trust -n ${ns} --from-file=trust-bundle.pem="$WORK/pod-identity.pem"
  kubectl create configmap ate-ca-servicedns-trust -n ${ns} --from-file=trust-bundle.pem="$WORK/service-dns.pem"
done
openssl x509 -in "$WORK/tls.crt" -noout -subject -enddate
rm -rf "$WORK"
```

**Verified on 2026-10-14:**

```text
secret/ate-ca-server-tls created
configmap/ate-ca-server-ca created
configmap/ate-ca-podidentity-trust created
configmap/ate-ca-servicedns-trust created
configmap/ate-ca-server-ca created
configmap/ate-ca-podidentity-trust created
configmap/ate-ca-servicedns-trust created
configmap/ate-ca-server-ca created
configmap/ate-ca-podidentity-trust created
configmap/ate-ca-servicedns-trust created
subject=CN=ate-ca.podcertificate-controller-system.svc
notAfter=Oct 14 16:09:13 2027 GMT
```

These ConfigMaps are not kept in step by anything. When you rotate the CA pools, publish the old and
new roots together in every consumer namespace, restart the consumers, and remove the old roots only
after every certificate issued from them has been replaced. The issuer certificate expires in a year
here; renew it the same way.

### B.3 The pod certificate controller (in place of `helm-substrate-podcert`)

`ateCa.enabled` runs the compatibility issuer beside the controller. No PostgreSQL clients are
mapped, because no client logs in by certificate here:

```bash run id=b-helm-substrate-podcert replaces=helm-substrate-podcert
helm upgrade -i substrate-podcert \
  oci://us-docker.pkg.dev/solo-public/enterprise-substrate-helm/substrate-podcert \
  --version ${SUBSTRATE_VERSION} \
  --namespace podcertificate-controller-system \
  --set ateCa.enabled=true
kubectl rollout status deployment -n podcertificate-controller-system --timeout=300s
kubectl get pods -n podcertificate-controller-system
```

**Verified on 2026-10-14:**

```text
Release "substrate-podcert" does not exist. Installing it now.
NAME: substrate-podcert
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
Waiting for deployment "podcertificate-controller" rollout to finish: 0 of 1 updated replicas are available...
deployment "podcertificate-controller" successfully rolled out
NAME                                         READY   STATUS    RESTARTS   AGE
podcertificate-controller-6c7d64cb84-dvxqx   1/1     Running   0          16s
```

### B.4 PostgreSQL with password logins (in place of `postgres-install` and `step-4-postgres-check`)

The same image, roles and schemas as Step 4. The server certificate is self-signed in a temporary
directory, and only its Secret is kept. `pg_hba.conf` refuses `postgres` over the network and admits
the three product users only over TLS, by password:

```bash run id=b-postgres-install replaces=postgres-install
PG_SETUP=$(mktemp -d)
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 365 \
  -subj "/CN=kagent-postgresql.kagent.svc" -addext "subjectAltName=DNS:kagent-postgresql.kagent.svc" \
  -keyout "$PG_SETUP/tls.key" -out "$PG_SETUP/tls.crt" 2>/dev/null
kubectl create secret tls kagent-postgresql-tls -n kagent --cert="$PG_SETUP/tls.crt" --key="$PG_SETUP/tls.key"
kubectl apply -f- <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: kagent-postgresql
  namespace: kagent
data:
  postgresql.conf: |
    listen_addresses = '*'
    ssl = on
    ssl_cert_file = '/run/postgresql-tls/tls.crt'
    ssl_key_file = '/run/postgresql-tls/tls.key'
    password_encryption = scram-sha-256
    hba_file = '/etc/postgresql/pg_hba.conf'
  pg_hba.conf: |
    local all all trust
    hostssl all postgres all reject
    hostssl kagent kagent_user,substrate_owner_user,substrate_readwrite_user all scram-sha-256
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: kagent-postgresql
  namespace: kagent
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 500Mi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kagent-postgresql
  namespace: kagent
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {app.kubernetes.io/name: kagent, app.kubernetes.io/component: database}
  template:
    metadata:
      labels: {app.kubernetes.io/name: kagent, app.kubernetes.io/component: database}
    spec:
      securityContext:
        fsGroup: 70
      containers:
      - name: postgresql
        image: ${POSTGRES_IMAGE}
        env:
        - {name: POSTGRES_DB, value: kagent}
        - {name: POSTGRES_USER, value: postgres}
        - {name: POSTGRES_HOST_AUTH_METHOD, value: trust}
        - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
        args: ["-c", "config_file=/etc/postgresql/postgresql.conf"]
        ports:
        - {name: postgresql, containerPort: 5432}
        readinessProbe:
          exec:
            command: [sh, -c, 'pg_isready -U postgres -d kagent']
          periodSeconds: 5
        volumeMounts:
        - {name: data, mountPath: /var/lib/postgresql/data}
        - {name: config, mountPath: /etc/postgresql}
        - {name: tls, mountPath: /run/postgresql-tls, readOnly: true}
      volumes:
      - name: data
        persistentVolumeClaim: {claimName: kagent-postgresql}
      - name: config
        configMap: {name: kagent-postgresql}
      - name: tls
        secret: {secretName: kagent-postgresql-tls, defaultMode: 0640}
---
apiVersion: v1
kind: Service
metadata:
  name: kagent-postgresql
  namespace: kagent
spec:
  selector: {app.kubernetes.io/name: kagent, app.kubernetes.io/component: database}
  ports:
  - {name: postgresql, port: 5432, targetPort: postgresql}
EOF
kubectl rollout status deployment/kagent-postgresql -n kagent --timeout=300s
KAGENT_SRC=https://raw.githubusercontent.com/kagent-dev/kagent/v1.0.0-alpha13/go/core/cli/internal/commands
SUBSTRATE_SRC=https://raw.githubusercontent.com/kagent-dev/substrate/v0.5.0-alpha2/pkg/postgressetup
curl -sSLf -o "$PG_SETUP/kagent.sql" "$KAGENT_SRC/bundled_postgres.sql"
curl -sSLf -o "$PG_SETUP/substrate.sql" "$SUBSTRATE_SRC/setup.sql"
( cd "$PG_SETUP" && shasum -a 256 -c - ) <<EOF
7ce064fd4e5f5f55a470e86f45db979247bacd887a09d881112051a9695f46be  kagent.sql
137264dea1a39db1a0692da8c24bd49d5272dae6123bab3cec1d667fdb8ee37e  substrate.sql
EOF
PW_KAGENT=$(openssl rand -hex 24); PW_OWNER=$(openssl rand -hex 24); PW_RW=$(openssl rand -hex 24)
{ echo "BEGIN;"
  echo "\\set substrate_owner_password '${PW_OWNER}'"
  echo "\\set substrate_readwrite_password '${PW_RW}'"
  cat "$PG_SETUP/kagent.sql" "$PG_SETUP/substrate.sql"
  echo "ALTER ROLE kagent_user PASSWORD '${PW_KAGENT}';"
  echo "CREATE SCHEMA IF NOT EXISTS enterprise AUTHORIZATION kagent_owner;"
  echo "REVOKE ALL ON SCHEMA enterprise FROM PUBLIC;"
  echo "COMMIT;"
} | kubectl exec -i -n kagent deployment/kagent-postgresql -c postgresql -- \
    psql --no-psqlrc --set=ON_ERROR_STOP=1 --quiet -U postgres -d kagent \
      --set=substrate_schema=substrate \
      --set=substrate_owner_role=substrate_owner --set=substrate_owner_user=substrate_owner_user \
      --set=substrate_readwrite_role=substrate_readwrite --set=substrate_readwrite_user=substrate_readwrite_user
DB=kagent-postgresql.kagent.svc:5432/kagent?sslmode=require
printf 'postgresql://kagent_user:%s@%s' "$PW_KAGENT" "$DB" \
  | kubectl create secret generic kagent-postgres -n kagent --from-file=connectionString=/dev/stdin
printf 'postgresql://substrate_owner_user:%s@%s' "$PW_OWNER" "$DB" \
  | kubectl create secret generic substrate-postgres-owner -n ate-system --from-file=ownerConnectionString=/dev/stdin
printf 'postgresql://substrate_readwrite_user:%s@%s' "$PW_RW" "$DB" \
  | kubectl create secret generic substrate-postgres-readwrite -n ate-system --from-file=readWriteConnectionString=/dev/stdin
unset PW_KAGENT PW_OWNER PW_RW
rm -rf "$PG_SETUP"
```

**Verified on 2026-10-14:**

```text
secret/kagent-postgresql-tls created
configmap/kagent-postgresql created
persistentvolumeclaim/kagent-postgresql created
deployment.apps/kagent-postgresql created
service/kagent-postgresql created
Waiting for deployment "kagent-postgresql" rollout to finish: 0 of 1 updated replicas are available...
deployment "kagent-postgresql" successfully rolled out
kagent.sql: OK
substrate.sql: OK
secret/kagent-postgres created
secret/substrate-postgres-owner created
secret/substrate-postgres-readwrite created
```

The passwords go into psql over stdin and into the Secrets over stdin, so they appear in no command
line. Anyone who can read those three Secrets can log in as that user.

```bash run id=b-postgres-check replaces=step-4-postgres-check
kubectl exec -n kagent deployment/kagent-postgresql -c postgresql -- psql -U postgres -d kagent -At -c \
  "select nspname || ' owned by ' || pg_get_userbyid(nspowner) from pg_namespace where nspname in ('kagent','substrate','enterprise') order by 1"
kubectl get configmap kagent-postgresql -n kagent -o jsonpath='{.data.pg_hba\.conf}'
```

**Verified on 2026-10-14:**

```text
enterprise owned by kagent_owner
kagent owned by kagent_owner
substrate owned by substrate_owner
local all all trust
hostssl all postgres all reject
hostssl kagent kagent_user,substrate_owner_user,substrate_readwrite_user all scram-sha-256
```

### B.5 Substrate (in place of `helm-substrate`)

`usePodCertificateAPI: false` selects the compatibility issuer. `postgres.clientCertificates` stays
off, because ate-api logs in with the password in its connection Secrets:

```bash run id=b-helm-substrate replaces=helm-substrate
helm upgrade -i substrate \
  oci://us-docker.pkg.dev/solo-public/enterprise-substrate-helm/substrate \
  --version ${SUBSTRATE_VERSION} \
  --namespace ate-system \
  -f - <<EOF
global:
  licensing:
    createSecret: false
    secretName: enterprise-agentgateway-license
usePodCertificateAPI: false
rustfs:
  storageSize: ${SNAPSHOT_STORE_SIZE}
credentialProvider:
  namespacePolicies:
    - atespace: kagent
      allowedNamespaces: [kagent]
EOF
```

### B.6 Waiting for Substrate (in place of `substrate-ready`)

```bash run id=b-substrate-ready replaces=substrate-ready
kubectl wait --for=condition=Available deployment --all -n ate-system --timeout=600s
kubectl rollout status daemonset/atelet -n ate-system --timeout=300s
kubectl get pods -n ate-system
kubectl logs -n podcertificate-controller-system deployment/podcertificate-controller --all-containers | grep -m1 'not served'
echo "-- kubectl-ate:"
kubectl-ate get actors -A 2>&1 | tail -1 || true
```

**Verified on 2026-10-14:**

```text
Release "substrate" does not exist. Installing it now.
NAME: substrate
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
(Helm's release notes omitted)
```

The pod certificate controller found no ClusterTrustBundle API, disabled its native signers, and
publishes `EnterpriseSubstrateClusterTrustBundles` instead. Substrate runs.

**kubectl-ate does not.** On this release every kubectl-ate command first looks for the
ClusterTrustBundle API and fails without it, and it has no option to supply the trust another way.
In this mode you have no CLI to list, inspect, resume or suspend actors: every kubectl-ate step in
the guide (Steps 9 to 30) fails with the error above. Agents are unaffected, because the kagent
controller does not use kubectl-ate.

### B.7 kagent (in place of `helm-kagent`)

The controller takes its Substrate client certificate from `ate-ca` too, through an `ate-ca-agent`
sidecar from the same Substrate release, and its database password from the `kagent-postgres` Secret
B.4 created:

```bash run id=b-helm-kagent replaces=helm-kagent
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
    usePodCertificateAPI: false
    ateCAAgentImage: us-docker.pkg.dev/solo-public/substrate-enterprise/atecaagent:v${SUBSTRATE_VERSION}@sha256:1d25cf59cd8d0828dfe66c863481d921278fb1af47a60b60f674c6dfe5a8ee65
kmcp:
  licensing:
    createSecret: false
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
kubectl get deployment kagent-controller -n kagent -o jsonpath='{range .spec.template.spec.initContainers[*]}{.name}{" "}{end}{range .spec.template.spec.containers[*]}{.name}{" "}{end}{"\n"}'
kubectl get workerpool -n kagent
```

**Verified on 2026-10-14:**

```text
Release "kagent" does not exist. Installing it now.
NAME: kagent
STATUS: deployed
REVISION: 1
DESCRIPTION: Install complete
(Helm's release notes omitted)
ate-ca-agent controller idp 
NAME             DESIRED   REPLICAS   READY   AGE
kagent-default   2         2          2       61s
```

The sidecar image is pinned by digest to the same Substrate release as `WORKER_IMAGE`.

### B.8 Checking the first turn (in place of `step-9-egress-policy`)

Steps 6 to 9 are unchanged and the first turn works. Step 9's egress policy check uses kubectl-ate,
so it cannot run here; the gateway's log, the next block in Step 9, proves the call went through the
enterprise gateway either way.

```bash run id=b-egress-policy replaces=step-9-egress-policy
kubectl-ate get egress-policy "session-${FIRST_CONTEXT}" --atespace kagent 2>&1 | tail -1 || true
```

**Verified on 2026-10-14:**

```text
Error: failed to connect to ate-api-server: failed to discover ClusterTrustBundle API: neither v1 nor v1beta1 ClusterTrustBundle is served
```

## Attachment C: Troubleshooting

Each entry gives the symptom, the cause and the fix. **Reproduced** means the symptom was produced
again on purpose, or met while verifying this guide; **observed during discovery** means it was seen
while building this guide and not reproduced since. Entries marked **[Dn]** exist because of an open
product defect and go away when it is fixed.

The fix commands are written to be run as they are, in your guide shell. Each was run on the
verification cluster `guide10` on 2026-10-14 (`auto-build/run.sh --attachment docs/attachments.md
--only ...`), after Validate had passed there; C.23's on cluster `alpha10` after its node was
restarted.

### Install

**C.1 PostgreSQL or Substrate pods sit in `ContainerCreating`.** *Observed during discovery.*
Cause: the CA and JWT pools do not exist yet; PostgreSQL and Substrate mount certificates issued from
them, and nothing but Step 3 creates them. Fix: check which exist, then run Step 3's
`substrate-pools` block, which skips those that do.

```bash run id=c-pools-check when=manual
for s in podcertificate-controller-system/service-dns-ca-pool podcertificate-controller-system/pod-identity-ca-pool \
         podcertificate-controller-system/postgres-ca-pool \
         ate-system/actor-id-jwt-pool ate-system/actor-id-ca-pool ate-system/egress-mitm-ca-pool; do
  kubectl get secret "${s#*/}" -n "${s%%/*}" >/dev/null 2>&1 && echo "present: $s" || echo "MISSING: $s"
done
```

**C.2 kubectl-ate fails with `token issuer "…" not trusted` while agents work.** *Observed during
discovery.* Cause: ate-api's authentication ConfigMap names an issuer that is not your cluster's;
agents are unaffected because kagent authenticates with a pod certificate. Fix: rewrite the
ConfigMap from the cluster's own issuer and restart ate-api.

```bash run id=c-issuer-fix when=manual
ISSUER=$(kubectl get --raw /.well-known/openid-configuration | jq -r .issuer)
echo "cluster issuer: ${ISSUER}"
kubectl create configmap ate-api-authentication -n ate-system --from-literal=authentication.yaml="actorIdentityJWTProvider: kubernetes
jwtProviders:
- name: kubernetes
  issuer: ${ISSUER}
  audiences: [api.ate-system.svc]
  certificateAuthorityFile: /var/run/secrets/kubernetes.io/serviceaccount/ca.crt
  discoveryTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
" --dry-run=client -o yaml | kubectl replace -f -
kubectl rollout restart deployment/ate-api-server -n ate-system
kubectl rollout status deployment/ate-api-server -n ate-system --timeout=180s
kubectl-ate get actors -A >/dev/null && echo "kubectl-ate: authenticated"
```

**C.3 The kagent controller restarts once during install with `unable to configure the enterprise
extensions`.** *Reproduced (three installs in four).* Its log, `kubectl logs ... --previous`, shows ten
attempts to reach the bundled login at `http://localhost:5556`, then `connection refused`. Cause: the
controller waits 20 seconds for its bundled login container to answer, and exits if it has not.
Fix: none; it recovers. Confirm it has:

```bash run id=c-controller-settled when=manual
kubectl rollout status deployment/kagent-controller -n kagent --timeout=180s
kubectl get pods -n kagent -l app.kubernetes.io/component=controller
```

**C.4 [D6] A licensed controller logs `kagent enterprise license missing or invalid`.** *Reproduced
(every start).* Cause: the controller also tracks a trial license and labels its state as the
kagent license. Fix: read the state, not the message. One `Licensed` line means licensed:

```bash run id=c-license-state when=manual
kubectl logs -n kagent deployment/kagent-controller -c controller | grep -o '"state":"[A-Za-z]*"' | sort | uniq -c
```

**C.5 A pasted block seems to do nothing, and the blocks pasted after it never run.** *Reproduced.*
Cause: `kubectl run -i` reads standard input, and takes everything pasted after it. Fix: blocks in
this guide that use it end with `< /dev/null`; keep it if you adapt them.

### Agents and Substrate

**C.6 [D10] Agent `Ready=False`, `GoldenActorCrashed: golden actor crashed before its snapshot was
taken`.** *Reproduced (a Harness naming `s3://no-such-bucket/`).* Cause: the bucket in the Harness's
`snapshotPolicy.location` does not exist; only atelet's log says so. Fix: find the storage error,
then point the Harness at the bucket the store has (`ate-snapshots` with the bundled store):

```bash run id=c-snapshot-bucket when=manual
kubectl logs -n ate-system daemonset/atelet --since=1h | grep -m3 -E 'NoSuchBucket|PutObject' || echo "no storage errors in the last hour"
kubectl patch harness kagent-adk -n kagent --type merge -p '{"spec":{"substrate":{"snapshotPolicy":{"location":"gs://ate-snapshots/kagent/"}}}}'
```

**C.7 [D11] atelet logs snapshot uploads "to GCS" on an S3 store.** *Reproduced (with C.6).*
Cause: a label in atelet's messages; the `gs://` and `s3://` schemes are handled the same way, and
the bundled store is S3. Fix: none. Check which backend atelet uses:

```bash run id=c-storage-backend when=manual
kubectl get daemonset atelet -n ate-system -o json | jq -r '.spec.template.spec.containers[].env[]? | select(.name == "ATE_STORAGE_BACKEND" or .name == "AWS_ENDPOINT_URL") | "\(.name)=\(.value)"'
```

**C.8 An agent goes `Ready`, and its first turn fails with `503 Service Unavailable credential
provider returned an unusable secret`.** *Reproduced.* Cause: the agent's credential Secret is empty,
usually because the value was exported in another shell. Fix: read the consumer key back from the
gateway's Secret and recreate the agent's copy:

```bash run id=c-consumer-key-recreate when=manual
export AGENT_CONSUMER_KEY=$(kubectl get secret llm-virtual-keys -n agentgateway-system \
  -o jsonpath='{.data.team-agents}' | base64 --decode | jq -r .key)
: "${AGENT_CONSUMER_KEY:?still empty}"
kubectl delete secret kagent-gateway-consumer-key -n kagent --ignore-not-found
printf '%s' "$AGENT_CONSUMER_KEY" | kubectl create secret generic kagent-gateway-consumer-key -n kagent --from-file=api-key=/dev/stdin
echo "length: $(kubectl get secret kagent-gateway-consumer-key -n kagent -o jsonpath='{.data.api-key}' | base64 --decode | wc -c | tr -d ' ')"
```

**C.9 [D3] The worker pool is a worker short after a change.** *Observed during discovery.* Cause:
the worker rollout removes a worker before starting its replacement, and the replacement cannot
schedule; only the Pending pod's event says why. Fix: find the reason, then remove the resource change
or add a worker first (Step 29):

```bash run id=c-worker-pending when=manual
kubectl get pods -n kagent -l ate.dev/worker-pool=kagent-default -o wide 2>/dev/null || kubectl get pods -n kagent | grep kagent-default
kubectl get events -n kagent --field-selector reason=FailedScheduling --sort-by=.lastTimestamp | tail -3
kubectl get workerpool -n kagent
```

**C.10 Nothing that Substrate issued validates, a year after Step 3.** *Not observed: follows from the
pools' one-year validity.* Cause: the CA pools expired, and nothing rotates them. Fix: replace the
pools and every root derived from them, then restart everything that holds a certificate. This
rotates every trust root, so expect PostgreSQL, every Substrate component, the workers and the
kagent controller to restart, in that order.

Nothing may restart before the pod certificate controller has published the new roots: every
component reads its trust bundle once, at start, and one that starts early keeps the old roots
(atenet-router then fails every resume with `invalid peer certificate: UnknownIssuer`, and kagent
refuses new turns with `input was not accepted; retry after the session becomes available`).
PostgreSQL goes next: it presents a service-DNS certificate and trusts only PostgreSQL login
certificates from the new pool, so a client restarted before it either distrusts its certificate or
presents one it refuses. Wait on each rollout, not on availability: the old pods keep a Deployment
available, so an availability wait passes while the new pods are failing:

```bash run id=c-rotate-pools when=manual
for s in podcertificate-controller-system/service-dns-ca-pool podcertificate-controller-system/pod-identity-ca-pool \
         podcertificate-controller-system/postgres-ca-pool \
         ate-system/actor-id-jwt-pool ate-system/actor-id-ca-pool ate-system/egress-mitm-ca-pool ate-system/actor-id-ca-certs; do
  kubectl delete secret "${s#*/}" -n "${s%%/*}"
done
ca_pool() {
  local name="$1" ns="$2"; shift 2
  kubectl-ate admin make-ca-pool --ca-id=1 --name="$name" --secret-namespace="$ns" "$@"
}
ca_pool service-dns-ca-pool podcertificate-controller-system
ca_pool pod-identity-ca-pool podcertificate-controller-system
ca_pool postgres-ca-pool podcertificate-controller-system
kubectl-ate admin make-jwt-pool --key-id=1 --name=actor-id-jwt-pool --secret-namespace=ate-system
ca_pool actor-id-ca-pool ate-system
ca_pool egress-mitm-ca-pool ate-system --key-type=ECDSAP256
kubectl get secret actor-id-ca-pool -n ate-system -o jsonpath='{.data.pool}' \
  | base64 --decode | jq -r '.CAs[0].RootCertificateDER' | base64 --decode \
  | openssl x509 -inform der -outform pem \
  | kubectl create secret generic actor-id-ca-certs -n ate-system --from-file=ca.crt=/dev/stdin
kubectl rollout restart deployment -n podcertificate-controller-system
kubectl rollout status deployment -n podcertificate-controller-system --timeout=300s
# Wait until the published trust bundles carry the new roots: components read them once, at start.
fp() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; }
for pool in service-dns pod-identity postgres; do
  want=$(kubectl get secret ${pool}-ca-pool -n podcertificate-controller-system -o jsonpath='{.data.tls\.crt}' | base64 --decode | fp)
  bundle=$(echo "$pool" | tr -d '-')
  for i in $(seq 1 60); do
    got=$(kubectl get clustertrustbundles -o json \
      | jq -r --arg b "$bundle" '.items[] | select(.metadata.name | startswith($b + ".podcert")) | .spec.trustBundle' | fp)
    [ "$got" = "$want" ] && { echo "trust bundle ${bundle}: new root published"; break; }
    sleep 5
  done
  [ "$got" = "$want" ] || { echo "trust bundle ${bundle}: still the old root after 300s" >&2; false; }
done
kubectl rollout restart deployment/kagent-postgresql -n kagent
kubectl rollout status deployment/kagent-postgresql -n kagent --timeout=300s
kubectl rollout restart deployment -n ate-system
kubectl rollout restart daemonset/atelet -n ate-system
for d in $(kubectl get deployment -n ate-system -o name); do kubectl rollout status "$d" -n ate-system --timeout=300s; done
kubectl rollout status daemonset/atelet -n ate-system --timeout=300s
kubectl rollout restart deployment/kagent-default deployment/kagent-controller -n kagent
kubectl rollout status deployment/kagent-controller -n kagent --timeout=300s
kubectl rollout status deployment/kagent-default -n kagent --timeout=300s
# New workers take a few seconds to register, and the old workers stay listed for a while after
# their pods are gone. Wait until every current worker pod is registered with capacity; until then a
# turn's resume times out.
for i in $(seq 1 60); do
  want=$(kubectl get pods -n kagent -o name | grep -c '/kagent-default-')
  have=$(kubectl-ate get workers | awk 'NR > 1 && $4 != "0/0" {print $(NF-1)}' | while read -r pod; do
    kubectl get pod -n kagent "${pod#kagent/}" >/dev/null 2>&1 && echo registered; done | grep -c registered || true)
  [ "$have" -ge "$want" ] && break
  sleep 5
done
kubectl-ate get workers
kubectl get secret actor-id-ca-pool -n ate-system -o jsonpath='{.data.tls\.crt}' | base64 --decode | openssl x509 -noout -enddate
```

Verified on this release by running the block and then the guide's Validate section, which passed:
a new session, restored from a golden image taken before the rotation, worked end to end. A session
suspended before the rotation also resumed after it with its context: its first turn set a fact,
the rotation ran, and its next turn answered from that fact, on the same actor, with a 103 ms
restore, and no `UnknownIssuer` in the router's log.

On a cluster without the beta certificates API (Attachment B), also republish the trust ConfigMaps
from the new pools; that path was not tested.

### Gateway and tools

**C.11 A check through a port-forward reads something else, or nothing.** *Reproduced.* Cause:
another process already holds the local port, so the new port-forward failed in the background and
`curl` reached whatever holds it. A port-forward also dies with the pod it was attached to. Fix: see
what holds the port, then use a free one, or close the stale forward and run `forwards`:

```bash run id=c-port-check when=manual
for port in "${KAGENT_API_PORT}" "${KAGENT_UI_PORT}" "${KEYCLOAK_PORT}" 18081 18082; do
  holder=$(lsof -nP -iTCP:"${port}" -sTCP:LISTEN 2>/dev/null | awk 'NR == 2 {print $1 " pid " $2}' || true)
  echo "${port}: ${holder:-free}"
done
forwards
```

**C.12 `RemoteMCPServer` reports `DiscoveryFailed … context deadline exceeded`, and the agent is
still `Ready` and works.** *Observed during discovery.* Cause: the MCP server is behind the gateway
and the gateway NetworkPolicy does not admit the kagent controller, which discovers tools by calling
the server itself. Fix: apply Step 7's policy with both rules (`networkpolicy-agentgateway-proxy`),
then make kagent discover again:

```bash run id=c-mcp-rediscover when=manual
kubectl annotate remotemcpserver deployment-codes -n kagent rediscover="$(date +%s)" --overwrite
sleep 10
kubectl get remotemcpserver deployment-codes -n kagent -o jsonpath='{.status.conditions[0].reason}: {.status.conditions[0].message}{"\n"}'
```

**C.13 The first request on a newly created gateway route fails with `Internal Server Error`.**
*Observed during discovery.* Cause: the route was used before the gateway had its configuration
(inferred: the next request a second later succeeded). Fix: retry after a few seconds; for MCP
discovery, `c-mcp-rediscover` above.

**C.14 [D7] The chart's `kagent-api` `RemoteMCPServer` reports `Unauthorized` from install.**
*Reproduced (every install).* Cause: it points at the controller's own MCP endpoint, which requires a
token, and the built-in client sends none. Fix: none on this release; do not give agents tools from
it. Check its state:

```bash run id=c-kagent-api-state when=manual
kubectl get remotemcpserver kagent-api -n kagent -o jsonpath='{.status.conditions[0].status} {.status.conditions[0].reason}: {.status.conditions[0].message}{"\n"}' 2>/dev/null || echo "no kagent-api RemoteMCPServer"
```

**C.15 [D14] A turn fails with `503 … invalid peer certificate: UnknownIssuer`.** *Observed during
discovery.* Cause: the ModelConfig's `baseUrl` is `https://` to a certificate from a private CA, and
Substrate's egress gateway trusts only public CAs. Fix: use `http://` for the in-cluster gateway:

```bash run id=c-baseurl-http when=manual
kubectl patch modelconfig anthropic-via-gateway -n kagent --type merge \
  -p '{"spec":{"anthropic":{"baseUrl":"http://agentgateway-proxy.agentgateway-system.svc.cluster.local"}}}'
kubectl get modelconfig anthropic-via-gateway -n kagent -o jsonpath='{.spec.anthropic.baseUrl}{"\n"}'
```

### Keycloak and sign-in

**C.16 Every caller gets `401` right after switching to OIDC, admin included.** *Observed during
discovery.* Cause: the port-forward was still attached to the controller pod from before the
upgrade, which still expected the bundled login's tokens (inferred). Fix: run `forwards`.

**C.17 Keycloak never becomes ready.** *Observed during discovery.* Cause: the realm Secret is empty
or still has placeholders, because the render produced nothing. Fix: check it, then recreate it with
Step 23's `keycloak-realm` block (delete the `keycloak` namespace first):

```bash run id=c-realm-check when=manual
REALM=$(kubectl get secret keycloak-realm -n keycloak -o jsonpath='{.data.realm\.json}' | base64 --decode)
echo "size: $(printf '%s' "$REALM" | wc -c | tr -d ' ') bytes, placeholders left: $(printf '%s' "$REALM" | grep -c '\${' || true), clients: $(printf '%s' "$REALM" | jq -r '[.clients[].clientId] | join(", ")')"
```

**C.18 Browser sign-in fails, or the controller rejects every token.** *Observed during discovery.*
Cause: the issuer name does not resolve to the same Keycloak from your browser and from inside the
cluster, so the two disagree on `iss` (A.0). Fix: re-run Step 23's `coredns-keycloak-rewrite` and
`keycloak-forward` blocks; the second prints the issuer from both sides, and the two lines must be
identical.

**C.19 Sign-out fails with Keycloak's "Invalid redirect uri".** *Observed during discovery.* Cause:
the `kagent-ui` client's post-logout redirect URI does not match what the UI sends, character for
character; a trailing slash is enough. Fix: set it to the UI's origin with no trailing slash:

```bash run id=c-logout-uri when=manual
KC="http://keycloak.localhost:${KEYCLOAK_PORT}"
ADMIN_TOKEN=$(curl -sS -X POST "${KC}/realms/master/protocol/openid-connect/token" -d grant_type=password \
  -d client_id=admin-cli -d username=admin --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" | jq -r .access_token)
UI_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/clients?clientId=kagent-ui" | jq -r '.[0].id')
curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/clients/${UI_ID}" \
  | jq --arg u "http://localhost:${KAGENT_UI_PORT}" '.attributes["post.logout.redirect.uris"] = $u' \
  | curl -sS -o /dev/null -w 'kagent-ui post-logout redirect: HTTP %{http_code}\n' -X PUT -H "Authorization: Bearer ${ADMIN_TOKEN}" \
      -H 'Content-Type: application/json' --data-binary @- "${KC}/admin/realms/kagent/clients/${UI_ID}"
```

**C.20 A user gets `401`, not `403`.** *Reproduced.* Cause: none of the user's groups maps to a
kagent role, and a user without a role is treated as unauthenticated. Fix: check the token's
`Groups` claim with `a-token-claims` (Attachment A), then add the user to a mapped group:

```bash run id=c-add-to-group when=manual
KC_USER=${KC_USER:-norole} KC_GROUP=${KC_GROUP:-readers}
KC="http://keycloak.localhost:${KEYCLOAK_PORT}"
ADMIN_TOKEN=$(curl -sS -X POST "${KC}/realms/master/protocol/openid-connect/token" -d grant_type=password \
  -d client_id=admin-cli -d username=admin --data-urlencode "password=${KEYCLOAK_ADMIN_PASSWORD}" | jq -r .access_token)
USER_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/users?username=${KC_USER}&exact=true" | jq -r '.[0].id')
GROUP_ID=$(curl -sS -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/groups?search=${KC_GROUP}" | jq -r --arg g "$KC_GROUP" '.[] | select(.name == $g) | .id')
curl -sS -o /dev/null -w "add ${KC_USER} to ${KC_GROUP}: HTTP %{http_code}\n" -X PUT \
  -H "Authorization: Bearer ${ADMIN_TOKEN}" "${KC}/admin/realms/kagent/users/${USER_ID}/groups/${GROUP_ID}"
```

**C.21 The kagent upgrade in Step 23 fails with `Progress deadline exceeded`, and the new
controller pod crash-loops with `OIDC client secret must not be empty`.** *Reproduced.* Cause: the
client secret was exported in another shell, so its Secret was created empty. Fix: read the secrets
back from the realm (Step 23's `step-23-read-back-secrets` block), recreate the Secret, and let the
controller restart:

```bash run id=c-oidc-secret-recreate when=manual
export KAGENT_OIDC_CLIENT_SECRET=$(kubectl get secret keycloak-realm -n keycloak -o jsonpath='{.data.realm\.json}' \
  | base64 --decode | jq -r '.clients[] | select(.clientId == "kagent-backend") | .secret')
: "${KAGENT_OIDC_CLIENT_SECRET:?still empty}"
kubectl delete secret kagent-enterprise-oidc-secret -n kagent --ignore-not-found
printf '%s' "$KAGENT_OIDC_CLIENT_SECRET" | kubectl create secret generic kagent-enterprise-oidc-secret \
  -n kagent --from-file=clientSecret=/dev/stdin
kubectl rollout restart deployment/kagent-controller -n kagent
kubectl rollout status deployment/kagent-controller -n kagent --timeout=300s
forwards
```

Re-running Step 23's `helm-kagent-oidc` block afterwards brings Helm's record of the release back to
`deployed`.

**C.22 The Keycloak pod stays in `ContainerCreating`, pulling its image, long after the timeout.**
*Observed while verifying this guide, after the host slept mid-pull.* Cause: the image pull stalled
and did not resume. Fix: delete the pod so the pull starts again, and forward to the new pod: the
old port-forward died with the old pod. Keycloak re-imports the realm when it starts (A.1), so re-run
Step 23's `keycloak-enable-kagent-cli` block afterwards:

```bash run id=c-keycloak-repull when=manual
kubectl delete pod -n keycloak -l app=keycloak
kubectl rollout status deployment/keycloak -n keycloak --timeout=600s
pkill -f "kubectl port-forward.*-n keycloak" 2>/dev/null || true
kubectl port-forward --address 127.0.0.1 -n keycloak service/keycloak ${KEYCLOAK_PORT}:${KEYCLOAK_PORT} >/dev/null 2>&1 &
sleep 3
curl -sS http://keycloak.localhost:${KEYCLOAK_PORT}/realms/kagent/.well-known/openid-configuration | jq -r .issuer
```

**C.23 [D18] After a node restarts, every turn on it is refused with `input was not accepted; retry after
the session becomes available`.** *Reproduced (a kind node stopped and started).* The actor is
restored, and then atenet-router cannot reach it: its log shows `upstream call failed: Connect:
deadline has elapsed`. Cause: the worker pods keep their names while their containers restart, and
Substrate's registrations of them are from before the restart (their age in `kubectl-ate get
workers` is older than the pods' restart); restarting the workers clears it (the mechanism is
inferred). Fix: restart the worker pool and wait for every worker to register:

```bash run id=c-restart-workers when=manual
kubectl rollout restart deployment/kagent-default -n kagent
kubectl rollout status deployment/kagent-default -n kagent --timeout=300s
for i in $(seq 1 60); do
  want=$(kubectl get pods -n kagent -o name | grep -c '/kagent-default-')
  have=$(kubectl-ate get workers | awk 'NR > 1 && $4 != "0/0" {print $(NF-1)}' | while read -r pod; do
    kubectl get pod -n kagent "${pod#kagent/}" >/dev/null 2>&1 && echo registered; done | grep -c registered || true)
  [ "$have" -ge "$want" ] && break
  sleep 5
done
kubectl-ate get workers
```

