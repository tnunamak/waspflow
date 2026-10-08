# S8 install contract: fresh homes, spaces in install paths, and honest doctor failures.
(
  fixture="$(mktemp -d "$scratch/waspflow-s8-install-XXXXXX")"
  fixture_home="$fixture/home"
  fixture_bin="$fixture/provider-bin"
  fixture_install_bin="$fixture/install bin"
  trap 'rm -rf "$fixture"' EXIT
  mkdir -p "$fixture_home" "$fixture_bin"

  # The provider commands are deliberately inert: doctor must not require a
  # configured account or contact a live provider.
  for provider in claude codex grok agy qwen dsh; do
    printf '#!/usr/bin/env bash\nexit 0\n' >"$fixture_bin/$provider"
    chmod +x "$fixture_bin/$provider"
  done
  printf '#!/usr/bin/env bash\nexit 1\n' >"$fixture_bin/tmux"
  chmod +x "$fixture_bin/tmux"

  clean_path="$fixture_bin:$PATH"
  export WASPFLOW_DOCTOR_LATEST_TAG=v0.0.0

  # The checkout executable works before installation and does not create
  # account configuration in a clean home.
  HOME="$fixture_home" PATH="$clean_path" "$root/bin/waspflow" doctor >"$fixture/direct-doctor.out"
  grep -q 'PASS provider codex' "$fixture/direct-doctor.out"
  [[ ! -e "$fixture_home/.claude" && ! -e "$fixture_home/.codex" ]]

  HOME="$fixture_home" PATH="$clean_path" WASPFLOW_INSTALL_BIN="$fixture_install_bin" \
    "$root/install.sh" >"$fixture/install.out"
  [[ -L "$fixture_install_bin/waspflow" ]]
  grep -Fq "linked $fixture_install_bin/waspflow -> $root/bin/waspflow" "$fixture/install.out"
  printf -v quoted_install_bin '%q' "$fixture_install_bin"
  printf -v quoted_install_command '%q' "$fixture_install_bin/waspflow"
  grep -Fq "next: add $quoted_install_bin to PATH, then run: $quoted_install_command doctor" "$fixture/install.out"
  PATH="$fixture_install_bin:$clean_path" HOME="$fixture_home" waspflow doctor >"$fixture/symlink-doctor.out"
  grep -q 'waspflow doctor' "$fixture/symlink-doctor.out"
  grep -q 'PASS provider codex' "$fixture/symlink-doctor.out"
  [[ ! -e "$fixture_home/.claude" && ! -e "$fixture_home/.codex" ]]

  # A controlled PATH without jq is a hard doctor failure. Installation must
  # still succeed without running doctor, then direct doctor reports the exact
  # missing prerequisite.
  missing_bin="$fixture/missing-jq-bin"
  mkdir -p "$missing_bin"
  for command in bash awk python3 git flock dirname find timeout sort tail mkdir ln cat readlink cksum date; do
    ln -s "$(command -v "$command")" "$missing_bin/$command"
  done
  for provider in claude codex grok agy qwen dsh; do
    ln -s "$fixture_bin/$provider" "$missing_bin/$provider"
  done
  ln -s "$fixture_bin/tmux" "$missing_bin/tmux"

  failed_install_bin="$fixture/failed install bin"
  HOME="$fixture_home" PATH="$missing_bin" WASPFLOW_INSTALL_BIN="$failed_install_bin" \
    "$root/install.sh" >"$fixture/failed-install.out"
  [[ -L "$failed_install_bin/waspflow" ]]
  printf -v quoted_failed_bin '%q' "$failed_install_bin"
  printf -v quoted_failed_command '%q' "$failed_install_bin/waspflow"
  grep -Fq "next: add $quoted_failed_bin to PATH, then run: $quoted_failed_command doctor" "$fixture/failed-install.out"
  if HOME="$fixture_home" PATH="$missing_bin" "$failed_install_bin/waspflow" doctor >"$fixture/failed-doctor.out" 2>"$fixture/failed-doctor.err"; then
    echo 'doctor: missing jq succeeded' >&2
    exit 1
  fi
  grep -q 'FAIL tool jq (required)' "$fixture/failed-doctor.out"
)
