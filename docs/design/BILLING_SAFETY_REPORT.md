# Billing Safety Report

## What Changed

Waspflow now has an env-only billing guard in `lib/billing.sh`.

- `waspflow doctor` reports the active auth/billing path implied by the current environment.
- Claude worker launch preflight refuses to proceed when `ANTHROPIC_API_KEY` is set, unless the user intentionally sets `WASPFLOW_ALLOW_API_BILLING=1`.
- Claude headless resume (`claude --resume ... --print`) uses the same guard, because it is another unattended billable Claude turn.
- Codex reports and warns when `OPENAI_API_KEY` is set, but does not hard-stop.

The guard does not call provider CLIs or networks. It only reads environment variables.

## User-Facing UX

Doctor with `ANTHROPIC_API_KEY` set:

```text
  [warn] claude auth: ANTHROPIC_API_KEY is set -> headless workers bill pay-as-you-go API rates, NOT your subscription. A fleet can run up large charges (see issue #37686). Unset it to use your subscription.
```

Doctor without `ANTHROPIC_API_KEY`:

```text
  [ok]   claude auth: subscription/Agent-SDK credit (no ANTHROPIC_API_KEY)
```

Codex doctor line when `OPENAI_API_KEY` is set:

```text
  [warn] codex auth: OPENAI_API_KEY is set -> headless Codex may use API pay-as-you-go billing instead of subscription-backed CLI auth. Verify billing before fleet use.
```

Claude hard stop:

```text
waspflow: claude billing guard: ANTHROPIC_API_KEY is set.
waspflow: Headless Claude workers will bill pay-as-you-go API rates, NOT your subscription/Agent-SDK credit.
waspflow: A fleet can run up large charges (see claude-code issue #37686).
waspflow: Fix: unset ANTHROPIC_API_KEY before spawning Claude workers.
waspflow: Intentional override: WASPFLOW_ALLOW_API_BILLING=1 waspflow spawn --provider claude ...
```

Claude intentional override:

```text
waspflow: claude billing guard: ANTHROPIC_API_KEY is set; proceeding because WASPFLOW_ALLOW_API_BILLING=1.
waspflow: claude billing guard: headless workers bill pay-as-you-go API rates, NOT your subscription. Monitor usage before running fleets.
```

## Verification Transcript

Syntax:

```text
$ bash -n bin/waspflow
$ bash -n lib/core.sh
$ bash -n lib/billing.sh
$ bash -n lib/providers/claude.sh
$ bash -n lib/providers/codex.sh
```

All returned exit code 0.

Doctor with `ANTHROPIC_API_KEY` set:

```text
$ env PATH="/home/tnunamak/code/waspflow-waspflow-billing-guard/bin:$PATH" ANTHROPIC_API_KEY=sk-ant-test OPENAI_API_KEY= waspflow doctor
waspflow doctor
  WASPFLOW_HOME = /home/tnunamak/.local/state/waspflow
  tmux session  = waspflow
  [ok]   tmux
  [ok]   jq
  [ok]   git
  [ok]   claude
  [ok]   codex
  [ok]   curl
  [ok]   uuidgen
  [warn] claude auth: ANTHROPIC_API_KEY is set -> headless workers bill pay-as-you-go API rates, NOT your subscription. A fleet can run up large charges (see issue #37686). Unset it to use your subscription.
  [ok]   codex auth: no OPENAI_API_KEY in environment; billing follows configured Codex CLI auth
  -> ready
```

Doctor with `ANTHROPIC_API_KEY` unset:

```text
$ env PATH="/home/tnunamak/code/waspflow-waspflow-billing-guard/bin:$PATH" ANTHROPIC_API_KEY= OPENAI_API_KEY= waspflow doctor
waspflow doctor
  WASPFLOW_HOME = /home/tnunamak/.local/state/waspflow
  tmux session  = waspflow
  [ok]   tmux
  [ok]   jq
  [ok]   git
  [ok]   claude
  [ok]   codex
  [ok]   curl
  [ok]   uuidgen
  [ok]   claude auth: subscription/Agent-SDK credit (no ANTHROPIC_API_KEY)
  [ok]   codex auth: no OPENAI_API_KEY in environment; billing follows configured Codex CLI auth
  -> ready
```

Doctor with `OPENAI_API_KEY` set:

```text
$ env PATH="/home/tnunamak/code/waspflow-waspflow-billing-guard/bin:$PATH" ANTHROPIC_API_KEY= OPENAI_API_KEY=sk-openai-test waspflow doctor
waspflow doctor
  WASPFLOW_HOME = /home/tnunamak/.local/state/waspflow
  tmux session  = waspflow
  [ok]   tmux
  [ok]   jq
  [ok]   git
  [ok]   claude
  [ok]   codex
  [ok]   curl
  [ok]   uuidgen
  [ok]   claude auth: subscription/Agent-SDK credit (no ANTHROPIC_API_KEY)
  [warn] codex auth: OPENAI_API_KEY is set -> headless Codex may use API pay-as-you-go billing instead of subscription-backed CLI auth. Verify billing before fleet use.
  -> ready
```

Actual blocked spawn preflight. This command stopped before worker launch and did not create lane state under the test `WASPFLOW_HOME`.

```text
$ env PATH="/home/tnunamak/code/waspflow-waspflow-billing-guard/bin:$PATH" ANTHROPIC_API_KEY=sk-ant-test WASPFLOW_ALLOW_API_BILLING= OPENAI_API_KEY= WASPFLOW_HOME=/home/tnunamak/.local/state/waspflow-billing-guard-test waspflow spawn --provider claude --lane billing-guard-block-test --cwd /home/tnunamak/code/waspflow-waspflow-billing-guard -- "Do not run; billing guard should stop this."
waspflow: claude billing guard: ANTHROPIC_API_KEY is set.
waspflow: Headless Claude workers will bill pay-as-you-go API rates, NOT your subscription/Agent-SDK credit.
waspflow: A fleet can run up large charges (see claude-code issue #37686).
waspflow: Fix: unset ANTHROPIC_API_KEY before spawning Claude workers.
waspflow: Intentional override: WASPFLOW_ALLOW_API_BILLING=1 waspflow spawn --provider claude ...
waspflow: spawn aborted: claude preflight failed
```

Direct guard decision with override:

```text
$ bash -c 'source lib/core.sh; set +e; ANTHROPIC_API_KEY=sk-ant-test; WASPFLOW_ALLOW_API_BILLING=1; billing_preflight_provider claude; printf "rc=%s\n" "$?"'
waspflow: claude billing guard: ANTHROPIC_API_KEY is set; proceeding because WASPFLOW_ALLOW_API_BILLING=1.
waspflow: claude billing guard: headless workers bill pay-as-you-go API rates, NOT your subscription. Monitor usage before running fleets.
rc=0
```

Direct guard decision with no key:

```text
$ bash -c 'source lib/core.sh; set +e; unset ANTHROPIC_API_KEY; unset WASPFLOW_ALLOW_API_BILLING; billing_preflight_provider claude; printf "rc=%s\n" "$?"'
rc=0
```

Codex secondary warning:

```text
$ bash -c 'source lib/core.sh; set +e; OPENAI_API_KEY=sk-openai-test; billing_preflight_provider codex; printf "rc=%s\n" "$?"'
waspflow: codex billing notice: OPENAI_API_KEY is set; verify whether Codex will use API pay-as-you-go billing before fleet use.
rc=0
```

## Confidence

High for the intended safety property: Claude workers cannot be launched by `spawn` while `ANTHROPIC_API_KEY` is present unless `WASPFLOW_ALLOW_API_BILLING=1` is also present, and the blocked path fails before lane state or tmux worker creation.

Medium-high for broader billing coverage: this also protects Claude headless resume, but it cannot prove how external provider CLIs interpret every possible wrapper or future auth mechanism. The check is deliberately env-only and therefore avoids network calls or provider invocations that could themselves have billing or side effects.
