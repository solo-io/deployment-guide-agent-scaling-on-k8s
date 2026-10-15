# auto-build

Runs [`../docs/deployment-guide-keycloak.md`](../docs/deployment-guide-keycloak.md) by executing
the guide itself: every runnable block, verbatim, in document order, in one bash session. A block
that fails is a guide problem, and the fix goes in `docs/`, not here.

| File | What it does |
|---|---|
| `extract.py` | Writes the guide's runnable blocks out as one bash script, or lists their IDs |
| `run.sh` | Applies your credentials, runs that script against the current cluster, logs each block |
| `demo-ui.sh` | Brings the UI back up on a cluster the guide built, for a demo |
| `check-paste.py` | Pastes every block into an interactive zsh and bash, with and without `shell-setup`, and reports the blocks that break |

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

## UI passwords

Step 23 creates three users to sign in to the UI as: `admin`, `writer` and `reader`. `run.sh` points
the guide at `auto-build/.env.local` for their passwords (`KAGENT_UI_CREDENTIALS_FILE`): if
`KAGENT_ADMIN_PASSWORD`, `KAGENT_WRITER_PASSWORD` or `KAGENT_READER_PASSWORD` is already set,
there or in your environment, it is used; otherwise the guide generates it and appends it to that
file, mode 0600. No block prints them, and a rebuilt cluster gets the same ones.

## Usage

```bash
auto-build/run.sh --dry-run          # print the script that would run, run nothing
auto-build/run.sh                    # run every block
auto-build/run.sh --from <block-id>  # resume at a block
auto-build/run.sh --to <block-id>    # stop after a block
auto-build/run.sh --shell zsh         # run it under zsh (default: bash)
auto-build/extract.py docs/deployment-guide-keycloak.md --list   # block IDs, in order

auto-build/run.sh --attachment docs/attachments.md --to step-9-gateway-log   # Attachment B's path
auto-build/run.sh --attachment docs/attachments.md --only c-pools-check,c-license-state
```

It runs against whatever `KUBECONFIG` points at, from a new, empty directory outside the repository
(deleted afterwards), so a block that depends on the repository or the current directory fails
here as it would for someone working from the guide alone. A certification passes under both
`--shell bash` and `--shell zsh`; zsh runs with `-f`, so no startup file is read. Step 1 creates the cluster, so a full run expects
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

## Attachments

`docs/attachments.md` holds two kinds of runnable block.

**Replacements.** A block tagged `replaces=<id>` runs in place of the guide's block `<id>`, and one
tagged `after=<id>` runs right after it. Attachment B is written this way: its blocks change Up and
Running for a cluster without the beta certificates API without copying the rest of it. With
`--attachment`, `--from` and `--to` work on the merged sequence, and `--list` shows each block's tag.

**Standalone blocks.** Attachment A's check and Attachment C's fixes are untagged and `when=manual`,
because each applies only in a particular situation. They run only when named with `--only`.

## Running chosen blocks

`--only <id>[,<id>...]` runs the environment block, the restore described under Resuming, every
helper block, and then the named blocks in the order given, including `when=manual` ones. It is how
Attachment C's fixes were run, and it works for any guide block too, for example `--only
keycloak-forward`.

## Opening the UI for a demo

```bash
auto-build/demo-ui.sh
```

Against the cluster `KUBECONFIG` points at, after the guide has run: restarts the worker pool if its
containers restarted in place (a node restart; the guide's Attachment C.23), forwards the UI to
127.0.0.1:14000 and Keycloak to 127.0.0.1:18080 unless something already answers there, checks both
answer, and prints the UI's URL, the three users and the path of the file holding their passwords.
`KAGENT_UI_PORT`, `KEYCLOAK_PORT` and `KAGENT_UI_CREDENTIALS_FILE` change the defaults; the
Keycloak port must be the one the cluster was built with, because it is part of the issuer URL.

## Checking that blocks survive a paste

```bash
auto-build/check-paste.py
```

A reader pastes blocks into an interactive shell, which reads them differently from a script: zsh
does not take `#` as a comment unless `interactive_comments` is set, and both shells expand `!` in
double quotes as history. `zsh -n` checks none of that, and an interactive zsh refuses `noexec`, so
the check runs each block for real in `zsh -f -i` and `bash -i` with `PATH` pointing at stubs that
do nothing, and collects the errors the shell reports while reading it. Each block is pasted with
default options and after the guide's `shell-setup` block. It also flags variables named after
zsh's special parameters (`status`, `path` and the rest). It exits 1 if a block fails after
`shell-setup`; blocks that fail only without it are listed for information.
