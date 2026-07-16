# Codex spawn can leave the initial prompt unsubmitted

Twice on 2026-07-13, `waspflow spawn --provider codex ...` created a healthy live lane and pasted the full marker/prompt into Codex, but left it sitting in the input editor until the orchestrator manually sent Enter to the recorded tmux window. `status` still reported `live`, so this can silently look like worker progress. Add a spawn-submission oracle (Codex transcript event or pane/input-state check), retry Enter once when safe, and fail the spawn explicitly if no turn-start event appears.
