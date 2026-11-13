# Socket Firewall inside Fly Sprites

**Run coding agents in a Sprite. Make every package they install go through Socket Firewall first.**

Audience: anyone letting Claude Code, Codex, or their own agent `npm install` and `pip install` unattended. Time: about 30 minutes. Cost: a few cents of Sprite compute; Socket Firewall Free costs nothing and needs no account.

Live-checked 2026-11-12 on Ubuntu 26.04.1, x86_64, `sfw` 1.16.0. Evidence: [lab-run-2026-11-12.md](lab-run-2026-11-12.md).

---

## Why both

A Sprite's network policy is a domain allowlist. Its `defaults` preset allows `registry.npmjs.org` and `pypi.org`, so agents can install packages. But a domain allowlist cannot tell `lodash` from `lodahs`. Anything published to an allowed registry gets through.

Socket Firewall (`sfw`) works at the package level. It runs a local proxy and checks every package download, including transitive ones, against Socket's malware data. Downloads of known malware fail with a 403 before any code reaches the disk.

| Threat | Sprite | `sfw` |
| --- | --- | --- |
| Agent damages your laptop | ✅ the agent never runs there | — |
| Agent reaches an arbitrary host | ✅ DNS allowlist | — |
| Agent installs a known-malware package from an allowed registry | ❌ registry is allowed | ✅ blocked, exit 1 |
| Something gets through anyway | ✅ checkpoint restore | — |

**What `sfw` Free does not do.** It blocks only human-confirmed malware. AI-flagged packages get a warning, and unknown versions pass. It covers npm, yarn, pnpm, pip, uv, and cargo. Telemetry is always on. It enforces nothing on its own: anything that skips the `sfw` proxy skips the check. Module 3 shows how to close most of that gap.

---

## Module 0: Create the Sprite and install `sfw`

On your laptop:

```bash
export S="sfw-lab-$(date +%Y%m%d-%H%M%S)"
sprite create "$S" --skip-console
sprite exec -s "$S" -- bash -s < scripts/install-sfw.sh
```

[`install-sfw.sh`](scripts/install-sfw.sh) fetches the pinned release binary into `~/.local/bin`. It also writes shims so that `npm`, `npx`, `pip`, `pip3`, `uv`, and `cargo` run through `sfw`.

> **Why not `npm i -g sfw`?** On a Sprite, npm's global bin dir sits inside the nvm tree and isn't on PATH. The install succeeds, then `sfw: command not found`.

Install **before** applying a network policy. The GitHub release download comes from `release-assets.githubusercontent.com`, which `defaults` does not allow.

## Module 1: Lock egress, then checkpoint

```bash
sprite api "/v1/sprites/$S/policy/network" -- \
  -X POST -H 'Content-Type: application/json' --data @policy.json
sprite checkpoint create -s "$S"
```

[`policy.json`](policy.json) is `defaults` plus two additions:

- **`*.socket.dev`**: not in `defaults`. `sfw` **fails closed**: if it can't reach `firewall-api.socket.dev`, it refuses every install, clean ones included (`getaddrinfo EAI_AGAIN firewall-api.socket.dev`).
- **`index.crates.io`**: also missing from `defaults` (`crates.io` and `static.crates.io` are there). Without it, cargo can't resolve the sparse index.

Do it in this order: policy first, then checkpoint. A checkpoint stores the network policy, and `sprite restore` brings back the policy as it was at that moment. If you restore a checkpoint taken before the policy existed, the Sprite is unrestricted again.

## Module 2: See it block

```bash
sprite exec -s "$S" -- bash -s < scripts/check-sfw.sh
```

Expected:

```
PASS  sfw on PATH: /home/sprite/.local/bin/sfw
PASS  resolves firewall-api.socket.dev
PASS  resolves registry.npmjs.org
PASS  npm resolves to sfw shim
PASS  clean package installs through sfw
PASS  known-malware package blocked (exit 1)
GATE: PASS
```

**If you don't see `GATE: PASS`, stop.** Read the result from that line, not from the command's exit status.

Then try it by hand:

```bash
sprite console -s "$S"
mkdir demo && cd demo && npm init -y
npm install crossenv
```

```
npm error 403 403 Forbidden - GET https://registry.npmjs.org/crossenv/-/crossenv-0.0.2-security.tgz

=== Socket Firewall ===

 - blocked npm package: name: crossenv; version: 0.0.2-security; reason: malware (critical) - https://socket.dev/npm/package/crossenv/alerts/0.0.2-security
```

`crossenv` is a [Socket sample package](https://docs.socket.dev/docs/sample-malware-packages): a typosquat of `cross-env` that npm removed. Its `0.0.2-security` version is npm's empty placeholder, so the test is safe even if the block fails. **Don't test with the other packages on that page.** Many of them are live malware.

Now compare with the real binary:

```bash
/.sprite/bin/npm install crossenv     # installs: no shim, no sfw, no check
```

That's the gap Module 3 closes.

## Module 3: Wrap the agent, not just the tools

The shims catch only commands resolved by name on PATH. They miss absolute paths (`/.sprite/bin/npm`) and a venv's own `pip` (`/tmp/v/bin/pip` comes first once the venv is activated).

`sfw` works by setting environment variables for the process it launches: `HTTPS_PROXY`, `SSL_CERT_FILE`, `NODE_EXTRA_CA_CERTS`, `PIP_CERT`, `CARGO_HTTP_PROXY`, and so on. Children inherit them. So launch the agent itself under `sfw`:

```bash
sfw claude
sfw codex
```

Every install the agent runs then goes through the proxy, whatever path it uses to call the package manager:

```bash
sfw bash -c '/.sprite/bin/npm install crossenv'    # blocked
```

The proxy only filters registry downloads. Other HTTPS traffic passes through it. Tested: Anthropic API, GitHub API, `git clone`. The shims detect when they're already running under `sfw` and skip the second wrap.

Add one line to the project's `CLAUDE.md` / `AGENTS.md` so the agent keeps the proxy on:

```markdown
Package installs go through Socket Firewall. If an install fails with a
"Socket Firewall … blocked" message, do not retry around it; report the package.
```

> **Still bypassable.** An agent that runs `env -u HTTPS_PROXY npm install` is outside the check, and the network policy won't stop it, because the registry is allowed. Free `sfw` makes the safe path the default; it can't enforce it. For enforcement, see Socket Firewall Enterprise's registry mode. That's out of scope here and untested.

## Module 4: Roll back a miss

```bash
sprite checkpoint list -s "$S"
sprite restore -s "$S" <version>      # the checkpoint from Module 1
```

The whole filesystem comes back, and so does the network policy from that checkpoint.

## Cost

Cold-cache `npm install express` (~65 packages), three runs each: **2.1–2.5 s plain, 3.4–3.9 s through `sfw`.** That's about 1.4 s per install.

## Cleanup

```bash
sprite destroy -s "$S"
```

## Files

| File | Runs where | What it does |
| --- | --- | --- |
| [`scripts/install-sfw.sh`](scripts/install-sfw.sh) | in the Sprite | installs the `sfw` binary and package-manager shims |
| [`scripts/check-sfw.sh`](scripts/check-sfw.sh) | in the Sprite | gate: DNS, shim, clean install, malware block |
| [`policy.json`](policy.json) | laptop → Sprites API | `defaults` + `*.socket.dev` + `index.crates.io` |
| [`lab-run-2026-11-12.md`](lab-run-2026-11-12.md) | — | evidence from the live run |
