# Operating, Isolating, and Scaling Agent Workloads on Kubernetes

A validated deployment guide for running agents on **Agent Substrate** under **kagent-enterprise**,
with every model and tool call they make going through **Solo Enterprise for agentgateway**.

---

## The problem this solves

Running one agent is a deployment. Running a platform of them is a different problem. Run as
ordinary pods, each agent carries its own copy of everything:
- an idle agent holds its pod's memory while it waits for the next message;
- the provider key sits in the agent's environment, readable by anything that can read the process;
- every agent calls the provider directly, so there is no single place to authenticate agents,
  enforce a budget or see which team spent what;
- agents from different teams share the node's kernel.

kagent-enterprise and Agent Substrate answer the first and last: each session is its own actor in a
gVisor sandbox, restored from a snapshot when a message arrives and suspended when the turn ends.
Solo Enterprise for agentgateway answers the rest: one place where agents authenticate, budgets
apply and every call is attributed and traced.

---

## What you get

Thirty-two steps, run in sequence, each verified on a live cluster:

| Section | Steps | What it establishes |
|---|---|---|
| **Up and Running** | 1 to 9 | Substrate, PostgreSQL with certificate logins, kagent, the enterprise gateway in front of the model, and a first turn proved to have gone through it |
| **Operate** | 10 to 16 | How an agent becomes actors, one session followed through suspension, its trace, inspecting actors, where context is kept, deleting a session, and a second runtime |
| **Isolate** | 17 to 25 | The gVisor sandbox, what a suspended session leaves, credential injection, the egress allowlist, MCP tools through the gateway, budgets, the snapshot store, and Keycloak with roles |
| **Scale** | 26 to 30 | Memory per turn in flight, storage per suspended session, sizing the worker pool and changing it without losing capacity |
| **Validate** | 31 to 32 | One session driven through every control, each result mapped to the step that set it |

Three attachments branch from it: Keycloak in detail, clusters without the beta certificates API,
and troubleshooting.

Every command, manifest and output in the guide was captured from a live cluster, not written from
documentation. The guide is certified by running it end to end on a fresh cluster, under bash and
under zsh, both as written and with every block pasted in document order. The product versions are
stated at the top of the guide.

**The guide states the limits it found.** A pod per agent uses less memory than Substrate at every
load measured; the guide says so, and says what it gives up. Before production lists each limit of
this release with the step that shows it, and the troubleshooting attachment marks every entry that
exists only because of an open product defect.

---

## Before you start

| Requirement | Notes |
|---|---|
| Docker with 6 CPU and 12 GiB | The reference environment is Colima on macOS |
| `kind` 0.32.0, `kubectl`, `helm`, `jq`, `curl`, `openssl`, `zstd` | Standard tooling |
| A kagent-enterprise licence key and a Solo Enterprise for agentgateway licence key | Contact your Solo account team |
| An Anthropic API key | Stored once, in the gateway; no agent holds it |
| Network access to `ghcr.io`, `us-docker.pkg.dev`, `docker.io`, `github.com`, `raw.githubusercontent.com` and `api.anthropic.com` | Images, pinned downloads and the model calls |

Keycloak, the reference identity provider, is deployed by the guide itself.

---

## Getting started

Read [`docs/deployment-guide-keycloak.md`](docs/deployment-guide-keycloak.md) from the top. It is
written to be run in order, and each step verifies before the next depends on it. Its first block
sets up the shell, bash or zsh, so the blocks after it paste cleanly. The guide needs nothing from
this repository: every file a step uses is in the guide or downloaded at a pinned version.

### Or build it automatically

The same guide can be executed end to end, verbatim, without working through it by hand. With the
three credentials exported, or in `auto-build/.env.local`:

```bash
auto-build/run.sh
```

`auto-build/run.sh --dry-run` prints the script it would run. `--shell zsh` runs it under zsh and
`--in-order` runs every block, manual ones included, as a reader pasting top to bottom would.
`auto-build/demo-ui.sh` brings the UI back up afterwards. See
[`auto-build/README.md`](auto-build/README.md) for credentials, resuming and how it works.

---

## Repository layout

```
docs/
  deployment-guide-keycloak.md   The guide. Read this first.
  attachments.md                 Attachments A (Keycloak), B (clusters without the beta
                                 certificates API) and C (troubleshooting)
auto-build/
  run.sh                         Runs the guide's blocks verbatim against the current cluster
  extract.py                     Pulls the runnable blocks out of the guide, in document order
  check-paste.py                 Pastes every block into interactive zsh and bash and reports breaks
  demo-ui.sh                     Brings the UI back up on a cluster the guide built
  README.md                      Credentials, flags and how it works
DECISIONS.md                     Why settled choices were settled, so they are not reopened
LESSONS.md                       What turned out to be true about the products, with versions
```

Product versions are not duplicated here. They are pinned in the environment setup block at the
top of the guide, which is itself a runnable block, so the guide and the automation cannot
disagree about what is being deployed.

---

## Releases

Each certified state of the guide is tagged:

| Tag | Certified against |
|---|---|
| `certified-alpha8` | kagent-enterprise 1.0.0-alpha8 |
| `certified-alpha10` | kagent-enterprise 1.0.0-alpha10 |
| `certified-alpha10-r2` | kagent-enterprise 1.0.0-alpha10, with tracing, paste-safe blocks in bash and zsh, and no dependency on this repository |

The guide documents a validated deployment at a point in time. It does not cover upgrade paths
between product versions; a fresh install of the pinned set is the only path it verifies.

---

## Contributing

Corrections are welcome, particularly from anyone who has run the guide and found that reality
disagrees with it. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for what to check before opening a pull
request and the conventions the guide follows.

---

## Support

This repository is reference material accompanying a deployment guide. It is not a supported Solo
product and carries no SLA.

For the products it deploys, use your normal Solo support channel. For problems with the guide
itself, open an issue here.
