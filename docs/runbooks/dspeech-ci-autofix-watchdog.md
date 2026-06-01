# Dspeech CI Auto-Fix Watchdog

## Purpose

`scripts/ci/dspeech_ci_watchdog.py` is a script-only poller for red GitHub Actions runs in `daocism/dspeech`. It keeps CI ownership inside the Dspeech lead loop: a new failed run is captured once, failed logs are stored locally, and one serialized worker is dispatched with a self-contained fix prompt.

The watchdog does not merge, force-push, or mark work done. The worker prompt requires a dedicated `fix/ci-<short>` branch, adversarial build -> review -> verify loop, PR, and a real green GitHub Actions run.

## Cost Model

Clean ticks are cheap: the script calls `gh run list`, compares `databaseId` values against local JSON state, emits empty stdout, and exits. Model work starts only for a new failed run or queued pending failure after the active worker clears.

## State

Default mini-pc state path:

```bash
/home/claw/.hermes/state/dspeech-ci-watchdog
```

Contents:

- `state.json` - seen failed run IDs, active worker PID, pending failures, history.
- `lock` - `flock` guard for overlapping ticks.
- `logs/run-<id>-failed.log` - `gh run view <id> --log-failed` output.
- `prompts/<watchdog-run-id>.md` - self-contained worker prompt.
- `worker-logs/<watchdog-run-id>.log` - dispatch stdout/stderr.

The script sets `umask 077`, creates state directories with `0700`, and writes state/log/prompt files private to the watchdog user.

## Trust Filter

The default filter dispatches only completed failed runs from trusted branch/event pairs:

- branches: `main`, `feat/**`, `fix/**`
- events: `push`, `workflow_dispatch`

Unsupported events, including arbitrary fork PR logs, are recorded in `state.json` under `skipped_untrusted_runs` and are not dispatched.

## Secret

Runtime GitHub auth is provided by 1Password, not by files in this repo:

```bash
GH_TOKEN=op://MyInfra-Active/github-pat-daocism-MyInfra-2026-2027/credential
```

Use `op run --env-file` around the watchdog runtime env file. Do not write the plaintext token into cron, state, prompt, logs, or Git.

## Enable

Create a runtime env file on the host that runs the watchdog:

```bash
mkdir -p /home/claw/.hermes/state
cat > /home/claw/.hermes/state/dspeech-ci-watchdog.env <<'EOF'
GH_TOKEN=op://MyInfra-Active/github-pat-daocism-MyInfra-2026-2027/credential
DSPEECH_CI_WATCHDOG_STATE_DIR=/home/claw/.hermes/state/dspeech-ci-watchdog
DSPEECH_CI_WATCHDOG_DISPATCH_CMD=ssh ubuntu-vm 'run_id={watchdog_run_id}; set -eu; tmp=$(mktemp /tmp/dspeech-ci-watchdog.XXXXXX.md); cleanup() { rm -f "$tmp"; }; trap cleanup EXIT; cat >"$tmp"; exec /home/user/projects/MyInfra/scripts/selfops-webui/dispatch.sh team-lead-infra "$tmp" "$run_id"'
EOF
chmod 0600 /home/claw/.hermes/state/dspeech-ci-watchdog.env
```

Initialize the current trusted red runs as already seen, without dispatching:

```bash
op run --env-file=/home/claw/.hermes/state/dspeech-ci-watchdog.env -- \
  /home/claw/projects/dspeech/scripts/ci/dspeech_ci_watchdog.py --init-baseline
```

Local no-network state verification:

```bash
/home/claw/projects/dspeech/scripts/ci/dspeech_ci_watchdog.py \
  --state-dir /home/claw/.hermes/state/dspeech-ci-watchdog \
  --dry-run --no-network
```

Idempotent cron install command:

```bash
(crontab -l 2>/dev/null | grep -v 'dspeech_ci_watchdog.py'; printf '%s\n' '0 * * * * /usr/bin/op run --env-file=/home/claw/.hermes/state/dspeech-ci-watchdog.env -- /home/claw/projects/dspeech/scripts/ci/dspeech_ci_watchdog.py >/tmp/dspeech-ci-watchdog.cron.log 2>&1') | crontab -
```

This command is provided for installation only; this runbook does not assert that cron is enabled.

## Disable

Remove the matching crontab line:

```bash
crontab -l | grep -v 'dspeech_ci_watchdog.py' | crontab -
```

## Inspect Activity

Read the state:

```bash
jq . /home/claw/.hermes/state/dspeech-ci-watchdog/state.json
```

Inspect captured CI evidence:

```bash
ls -la /home/claw/.hermes/state/dspeech-ci-watchdog/logs
```

Inspect worker prompts and dispatch output:

```bash
ls -la /home/claw/.hermes/state/dspeech-ci-watchdog/prompts
ls -la /home/claw/.hermes/state/dspeech-ci-watchdog/worker-logs
```

Find what a worker fixed by following the PR branch recorded in the worker log, then verify the PR's GitHub Actions run is green.
