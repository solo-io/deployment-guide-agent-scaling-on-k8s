#!/usr/bin/env python3
"""Write the guide's runnable blocks out as one bash script, in document order.

A runnable block is a fenced block whose info string is `bash run id=<id>`. Blocks
marked `when=manual` are skipped. Each block is preceded by a marker line
(`>>>BLOCK <id>`) so a log can be split per block.

The credentials are applied right after the environment setup block, from
__CRED_<NAME> variables that run.sh exports, so the placeholders the guide sets
never reach a command.

  extract.py <guide.md> [--from <id>] [--to <id>]   script on stdout
  extract.py <guide.md> --list                      block ids, one per line

With --from, blocks before <id> are skipped except the environment block and any
block whose id ends in -helper or -helpers (function definitions later blocks
call), and values a reader's shell would still hold are restored from the cluster.
"""
import re
import sys

CREDENTIALS = ["KAGENT_LICENSE_KEY", "AGENTGATEWAY_LICENSE_KEY", "ANTHROPIC_API_KEY"]

# Shell state a block sets with `export` that later blocks read. Restored on --from.
# Read from the gateway's Secret (Step 6), which exists before the kagent copy does (Step 8).
RESTORE = """\
if kubectl get secret llm-virtual-keys -n agentgateway-system >/dev/null 2>&1; then
  export AGENT_CONSUMER_KEY=$(kubectl get secret llm-virtual-keys -n agentgateway-system -o jsonpath='{.data.team-agents}' | base64 --decode | jq -r .key)
fi"""


def blocks(path):
    lines = open(path).read().splitlines()
    out, i = [], 0
    while i < len(lines):
        m = re.match(r"^```bash run id=(\S+)(.*)$", lines[i])
        if m:
            body = []
            i += 1
            while lines[i] != "```":
                body.append(lines[i])
                i += 1
            out.append((m.group(1), "when=manual" in m.group(2), "\n".join(body)))
        i += 1
    return out


def main():
    args = sys.argv[1:]
    if not args:
        sys.exit(__doc__)
    found = blocks(args[0])
    ids = [b[0] for b in found]
    if len(set(ids)) != len(ids):
        sys.exit("duplicate block ids: " + ", ".join(sorted({i for i in ids if ids.count(i) > 1})))
    if "--list" in args:
        print("\n".join(f"{b[0]}{'  (manual)' if b[1] else ''}" for b in found))
        return
    frm = args[args.index("--from") + 1] if "--from" in args else None
    to = args[args.index("--to") + 1] if "--to" in args else None
    for want in (frm, to):
        if want and want not in ids:
            sys.exit(f"no block with id {want}")
    start = ids.index(frm) if frm else 0
    end = ids.index(to) if to else len(found) - 1
    script = ["set -eo pipefail"]
    for n, (bid, manual, body) in enumerate(found):
        if manual:
            continue
        is_env = bid == "environment-setup-env"
        is_helper = bid.endswith("-helper") or bid.endswith("-helpers")
        if n > end:
            break
        if n < start and not (is_env or is_helper):
            continue
        script += [f"echo '>>>BLOCK {bid}'", body]
        if is_env:
            script += [f'export {c}="$__CRED_{c}"' for c in CREDENTIALS]
            script.append('export PATH="$ATE_BIN_DIR:$PATH"')
            if frm:
                script.append(RESTORE)
    script.append("echo '>>>DONE'")
    print("\n".join(script))


main()
