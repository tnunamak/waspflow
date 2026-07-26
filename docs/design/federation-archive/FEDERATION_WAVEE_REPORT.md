# Federation Wave E report

Date: 2026-07-22

## Delivered

- Contribution history uses a plain, full-row control with a left name/finished-date column and a right receipt-summary chip. Long task and receipt text wraps inside its respective column; the row retains a visible hover affordance and its complete area selects the receipt.
- Settings now renders one card per provider. Display names are Anthropic (Claude), OpenAI, and Google; capacity labels use `Subscription` and `API key`; provider sign-in and Anthropic's managed state have separate, spaced controls.
- The contribution surface no longer invents `Collective: your collective`. It shows the line only when a collective name exists, removes the redundant ready subline, uses a positive idle dot, and quiets the activity link.
- Empty queues now use one quiet line and no disabled next-task button. The contribution copy now says: “Leave contributing on — Waspflow will pick up the next trusted request.”
- Help uses the Anthropic (Claude) brand name. Docker identity now distinguishes `Checking…`, a detected account, a normal not-reported result, and `Couldn't detect — is Docker signed in?` after a probe failure.
- A stale browser token stops polling after two 401 responses and replaces the content with: “This session expired. Reopen Federation from Waspflow (waspflow federation ui).”

## Screenshot verification

I rendered a local authenticated fixture at 1440 × 1100 with a deliberately long activity task name, long combined receipt text, and Anthropic/OpenAI/Google provider states. I inspected the rendered PNG bytes, not only the DOM.

- Activity: the long task title wraps on the left above its finished date. The receipt is a light-green, dark-text chip on the right; it wraps to three short lines inside the chip and does not extend outside the row. The row reads as a list item rather than a filled green button.
- Settings: each provider is a separate bordered row. Anthropic (Claude) shows `Subscription · Signed in` with a distinct managed badge; OpenAI and Google show `Subscription · Needs sign-in` / `API key · Needs sign-in` with a visibly separated Sign in button. No provider label or control overlaps another.

The fixture screenshots had no browser console errors. The live journey also passed with zero normal-view console errors. In the forced stale-token check, Chromium reported exactly the two real 401 responses before polling stopped; it did not continue producing errors.

## Verification

- `node --test tests/*.mjs` — passed after a retry of a transient real-sbx network-proxy setup failure.
- `node --test --test-name-pattern='live sbx integration: real claim' tests/federation-pull.test.mjs` — passed on retry.
- Live headless browser journey against the restarted daemon — passed all 9 checks, including the stale-session check and zero normal-view console errors.
- `bash scripts/verify.sh` — passed on retry (`waspflow verify: ok`). Its first run failed in an unrelated provider-resume fixture at line 2898; the retry passed unchanged.

## Daemon restart

`wf-fed-daemon.service` was restarted and is active on port 4243. The refreshed session token is `eRalaeuOgPN3o-d-gjvYlNRyxlhlFaxZ0w0ruuag-Ss`.
