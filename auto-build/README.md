# auto-build

Runs [`../docs/deployment-guide-keycloak.md`](../docs/deployment-guide-keycloak.md) by executing
the guide itself: every runnable block, verbatim, in document order, in one bash session. A block
that fails is a guide problem, and the fix goes in `docs/`, not here.

| File | What it does |
|---|---|
| `extract.py` | Writes the guide's runnable blocks out as one bash script, or lists their IDs |
| `run.sh` | Applies your credentials, runs that script against the current cluster, logs each block |

## Credentials

Three, the same three the guide's environment setup block sets to placeholders:
`KAGENT_LICENSE_KEY`, `AGENTGATEWAY_LICENSE_KEY`, `ANTHROPIC_API_KEY`.

Export them, or put them in `auto-build/.env.local` (gitignored):

```bash
cat > auto-build/.env.local <<'X'
KAGENT_LICENSE_KEY='...'
AGENTGATEWAY_LICENSE_KEY='...'
ANTHROPIC_API_KEY='...'
X
```

`run.sh` refuses to start if any is unset or still the guide's `<...>` placeholder. They are applied
immediately after the environment block, so versions and settings come from the guide and only the
secrets come from you. No block prints them.

## Usage

```bash
auto-build/run.sh --dry-run          # print the script that would run, run nothing
auto-build/run.sh                    # run every block
auto-build/run.sh --from <block-id>  # resume at a block
auto-build/run.sh --to <block-id>    # stop after a block
auto-build/extract.py docs/deployment-guide-keycloak.md --list   # block IDs, in order
```

It runs against whatever `KUBECONFIG` points at. Step 1 creates the cluster, so a full run expects
no kind cluster named `KIND_CLUSTER_NAME` (default `agents`) to exist yet. To keep the build out of
your own kubeconfig and home directory, set both before running:

```bash
export KUBECONFIG=$PWD/kubeconfig ATE_BIN_DIR=$PWD/.bin
```

Each run writes `auto-build/logs/run-<UTC time>.log` (and the exact script it ran beside it, as `.sh`), with a `>>>BLOCK <id>` line before each
block's output and `>>>DONE` at the end. `run.sh` prints the exit status and the last marker, so a
failure names the block it stopped in.

## How blocks are found

A runnable block's fence carries a `run` tag and a stable ID:

````markdown
```bash run id=helm-substrate
````

Blocks without the tag are output or illustration and are ignored. `when=manual` marks a block a
reader runs only when something has failed, and `run.sh` skips it.

Derive an ID from what the block creates, not from its step number, so renumbering does not break
`--from`.

## Resuming

`--from <id>` skips the blocks before `<id>` except two kinds, because later blocks depend on the
shell state they leave:

- the environment setup block (`environment-setup-env`), followed by your credentials;
- any block whose ID ends in `-helper` or `-helpers`, which only define shell functions.

Values a reader's shell would still hold from an earlier block, such as the generated consumer key,
are read back from the cluster. A new block that exports a value later blocks need should either be
cheap to re-run or be added to `RESTORE` in `extract.py`.

## Exit status

`run.sh` exits non-zero if a block fails (with that command's status), and also if the script ends
without reaching `>>>DONE`. The second check exists because a block that reads stdin can swallow the
rest of a piped script and end the run with status 0; the script now runs from a file with stdin
closed, and the check catches anything that ends a run early some other way.
