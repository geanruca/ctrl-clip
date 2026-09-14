#!/usr/bin/env bash
# Shell-compatibility demo. From each shell's own syntax: pipe a draft into clip.sh, pass
# it as a file, run the Ctrl+click handler, and run the `curl … | bash` installer. Every
# copy must reach the (stub) clipboard byte-for-byte clean.
#
#   tests/shells.sh                               test every shell installed here
#   REQUIRED_SHELLS="bash zsh fish" tests/shells.sh   also fail when one is missing (CI)
# shellcheck disable=SC2016
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_sandbox EXIT

shells=(bash zsh fish dash ksh mksh tcsh nu pwsh elvish xonsh)
tests=(pipe file handler install)

# Shell invocations without user config files, so results don't depend on dotfiles.
run_in() {
  local code=$2
  case $1 in
    bash) bash --norc --noprofile -c "$code" ;;
    zsh) zsh -f -c "$code" ;;
    fish) fish --no-config -c "$code" ;;
    tcsh) tcsh -f -c "$code" ;;
    nu) nu --no-config-file -c "$code" ;;
    pwsh) pwsh -NoProfile -NonInteractive -Command "$code" ;;
    elvish) elvish -norc -c "$code" ;;
    xonsh) xonsh --no-rc -c "$code" ;;
    *) "$1" -c "$code" ;;
  esac
}

# The command each test runs, written idiomatically for each shell. Paths arrive through
# the environment: DRAFT, CLIP, HANDLER, CLIPFILE, INSTALLER.
code_for() {
  local flags="--no-test --no-autoload"
  case "$1" in
    bash | zsh | dash | ksh | mksh)
      case $2 in
        pipe) echo 'cat "$DRAFT" | "$CLIP"' ;;
        file) echo '"$CLIP" "$DRAFT"' ;;
        handler) echo '"$HANDLER" "file://$CLIPFILE"' ;;
        install) echo "cat \"\$INSTALLER\" | bash -s -- $flags" ;;
      esac ;;
    fish | tcsh)
      case $2 in
        pipe) echo 'cat $DRAFT | $CLIP' ;;
        file) echo '$CLIP $DRAFT' ;;
        handler) echo '$HANDLER file://$CLIPFILE' ;;
        install) echo "cat \$INSTALLER | bash -s -- $flags" ;;
      esac ;;
    nu)
      case $2 in
        pipe) echo 'open --raw $env.DRAFT | ^$env.CLIP' ;;
        file) echo '^$env.CLIP $env.DRAFT' ;;
        handler) echo '^$env.HANDLER $"file://($env.CLIPFILE)"' ;;
        install) echo "open --raw \$env.INSTALLER | ^bash -s -- $flags" ;;
      esac ;;
    pwsh)
      case $2 in
        pipe) echo 'Get-Content -Raw $env:DRAFT | & $env:CLIP; exit $LASTEXITCODE' ;;
        file) echo '& $env:CLIP $env:DRAFT; exit $LASTEXITCODE' ;;
        handler) echo '& $env:HANDLER "file://$env:CLIPFILE"; exit $LASTEXITCODE' ;;
        install) echo "Get-Content -Raw \$env:INSTALLER | bash -s -- $flags; exit \$LASTEXITCODE" ;;
      esac ;;
    elvish)
      case $2 in
        pipe) echo 'cat $E:DRAFT | (external $E:CLIP)' ;;
        file) echo '(external $E:CLIP) $E:DRAFT' ;;
        handler) echo '(external $E:HANDLER) file://$E:CLIPFILE' ;;
        install) echo "cat \$E:INSTALLER | bash -s -- $flags" ;;
      esac ;;
    xonsh)
      case $2 in
        pipe) echo 'cat $DRAFT | @($CLIP)' ;;
        file) echo '@($CLIP) $DRAFT' ;;
        handler) echo '@($HANDLER) @("file://" + $CLIPFILE)' ;;
        install) echo "cat \$INSTALLER | bash -s -- $flags" ;;
      esac ;;
  esac
}

version_of() {
  case $1 in
    bash) bash -c 'echo "${BASH_VERSION%%(*}"' ;;
    zsh) zsh -fc 'echo $ZSH_VERSION' ;;
    fish) fish --version | awk '{print $NF}' ;;
    dash) dpkg-query -W -f='${Version}' dash ;;
    ksh) ksh -c 'echo ${.sh.version}' | awk '{print $3}' ;;
    mksh) mksh -c 'echo $KSH_VERSION' | awk '{print $3}' ;;
    tcsh) tcsh -fc 'echo $tcsh' ;;
    nu) nu --version ;;
    pwsh) pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()' ;;
    elvish) elvish -version ;;
    xonsh) xonsh --version | awk '{print $NF}' ;;
  esac 2>/dev/null </dev/null | head -n 1 | cut -c1-24 || true
}

new_sandbox --full-path
export CLIP="$skill_src/clip.sh" HANDLER="$skill_src/clip-url-handler.sh"
export DRAFT="$sandbox/draft.txt" INSTALLER="$root_dir/install.sh"
export CLIPFILE="$HOME/.cache/claude-clip/shell-demo.claudeclip"
cat > "$DRAFT" <<'EOF'
> Hi team, the deploy is done ✅
>
│ - API latency is back to normal
│ - I'll keep monitoring; cost: $0 `extra` "quoted"
EOF
expected=$'Hi team, the deploy is done ✅\n\n- API latency is back to normal\n- I\'ll keep monitoring; cost: $0 `extra` "quoted"'
mkdir -p "$(dirname "$CLIPFILE")"
cp "$DRAFT" "$CLIPFILE"

pkg="$sandbox/pkg/ctrl-clip-main"
mkdir -p "$pkg/skills"
cp -R "$skill_src" "$pkg/skills/"
cp "$root_dir/install.sh" "$pkg/"
tar -czf "$sandbox/main.tar.gz" -C "$sandbox/pkg" ctrl-clip-main
export CTRL_CLIP_TARBALL="file://$sandbox/main.tar.gz"
installed_skill="$CLAUDE_CONFIG_DIR/skills/ctrl-clip/clip-setup.sh"

# check SHELL TEST — prints ✅ or ❌, details go to $sandbox/log.
check() {
  local status=0 got output
  reset_clipboard
  rm -rf -- "$CLAUDE_CONFIG_DIR/skills"
  output=$(cd "$sandbox" && run_in "$1" "$(code_for "$1" "$2")" 2>&1) || status=$?
  if [[ $2 == install ]]; then
    got=$([[ -x "$installed_skill" ]] && echo "$expected")
  else
    got=$(clipboard)
  fi
  if [[ $status -eq 0 && "$got" == "$expected" ]]; then
    echo ✅
  else
    printf '%s %s: exit %s\n  output: %s\n  clipboard: %q\n' "$1" "$2" "$status" "$output" "$got" >> "$sandbox/log"
    echo ❌
  fi
}

table='| Shell | Version | pipe → clip.sh | clip.sh FILE | Ctrl+click handler | curl … \| bash install |'
table+=$'\n|---|---|:-:|:-:|:-:|:-:|'
failures=0
required=" ${REQUIRED_SHELLS:-} "
for sh in "${shells[@]}"; do
  if ! command -v "$sh" >/dev/null; then
    if [[ "$required" == *" $sh "* ]]; then
      table+=$'\n'"| $sh | — | ❌ missing | ❌ missing | ❌ missing | ❌ missing |"
      failures=$((failures + 1))
    else
      table+=$'\n'"| $sh | — | not installed | not installed | not installed | not installed |"
    fi
    continue
  fi
  row="| $sh | $(version_of "$sh") |"
  for t in "${tests[@]}"; do
    result=$(check "$sh" "$t")
    [[ "$result" == ✅ ]] || failures=$((failures + 1))
    row+=" $result |"
  done
  table+=$'\n'"$row"
done

printf '%s\n' "$table"
if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
  printf '## Shell compatibility\n\n%s\n' "$table" >> "$GITHUB_STEP_SUMMARY"
fi
if [[ $failures -gt 0 ]]; then
  printf '\n%d failure(s):\n' "$failures"
  cat "$sandbox/log" 2>/dev/null || true
  exit 1
fi
