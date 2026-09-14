#!/usr/bin/env bash
# Shared helpers for the ctrl-clip tests: a hermetic sandbox (throwaway HOME, XDG dirs and
# CLAUDE_CONFIG_DIR, stub clipboard/desktop commands that record what they're asked to do)
# plus a few assertions. Sourced by unit.sh and shells.sh.
# shellcheck disable=SC2016,SC2034

tests_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root_dir=$(cd -- "$tests_dir/.." && pwd)
skill_src="$root_dir/skills/ctrl-clip"
original_path=$PATH
sandbox=""
passed=0
failed=0

if [[ -t 1 ]]; then
  green=$'\033[32m' red=$'\033[31m' bold=$'\033[1m' reset=$'\033[0m'
else
  green="" red="" bold="" reset=""
fi

section() { printf '\n%s%s%s\n' "$bold" "$1" "$reset"; }
pass() { passed=$((passed + 1)); printf '  %s✓%s %s\n' "$green" "$reset" "$1"; }
fail() {
  failed=$((failed + 1))
  printf '  %s✗%s %s\n' "$red" "$reset" "$1"
  if [[ $# -gt 1 ]]; then printf '%s\n' "$2" | sed 's/^/      /'; fi
}

# assert_eq NAME ACTUAL EXPECTED
assert_eq() {
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "$(printf 'expected: %q\ngot:      %q' "$3" "$2")"; fi
}
# assert_contains NAME HAYSTACK NEEDLE
assert_contains() {
  if [[ "$2" == *"$3"* ]]; then pass "$1"; else fail "$1" "$(printf 'missing: %q\nin:      %q' "$3" "$2")"; fi
}
assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then pass "$1"; else fail "$1" "$(printf 'unexpected: %q\nin:         %q' "$3" "$2")"; fi
}
# assert_status NAME EXPECTED_STATUS COMMAND...
assert_status() {
  local name=$1 expected=$2 status=0
  shift 2
  "$@" >/dev/null 2>&1 || status=$?
  assert_eq "$name" "$status" "$expected"
}

finish() {
  printf '\n%s%d passed, %d failed%s\n' "$bold" "$passed" "$failed" "$reset"
  [[ $failed -eq 0 ]]
}

# stub NAME BODY — an executable in $sandbox/bin that runs BODY with $sandbox set.
stub() {
  printf '#!/usr/bin/env bash\nsandbox=%q\n%s\n' "$sandbox" "$2" > "$sandbox/bin/$1"
  chmod +x "$sandbox/bin/$1"
}
drop_stub() { rm -f -- "$sandbox/bin/$1"; }

write_stubs() {
  local copy='echo "${0##*/}" >> "$sandbox/calls"; cat > "$sandbox/clipboard"'
  local paste='cat "$sandbox/clipboard" 2>/dev/null'
  stub wl-copy "$copy"
  stub wl-paste "$paste"
  stub pbcopy "$copy"
  stub pbpaste "$paste"
  stub xclip "if [[ \" \$* \" == *' -o '* ]]; then $paste; else $copy; fi"
  stub xsel "if [[ \" \$* \" == *' --output '* ]]; then $paste; else $copy; fi"
  stub notify-send 'printf "%s\n" "$*" >> "$sandbox/notifications"'
  stub update-mime-database 'echo "update-mime-database $*" >> "$sandbox/calls"'
  stub update-desktop-database 'echo "update-desktop-database $*" >> "$sandbox/calls"'
  stub xdg-open 'echo "xdg-open $*" >> "$sandbox/calls"'
  stub xdg-mime '
case "$1 $2" in
  "query default") cat "$sandbox/mime-default" 2>/dev/null ;;
  "query filetype") if [[ "$3" == *.claudeclip ]]; then echo application/x-claude-clip; else echo text/plain; fi ;;
  default\ *) echo "xdg-mime default $2 $3" >> "$sandbox/calls"; printf "%s\n" "$2" > "$sandbox/mime-default" ;;
esac'
}

# new_sandbox [--full-path] — fresh sandbox with stubs first on PATH. Without --full-path the
# rest of PATH is only basic utilities, so a real xclip or xdg-mime can never leak in.
new_sandbox() {
  export PATH=$original_path
  [[ -z "$sandbox" ]] || rm -rf -- "$sandbox"
  sandbox=$(mktemp -d)
  mkdir -p "$sandbox/home" "$sandbox/bin" "$sandbox/sys"
  export HOME="$sandbox/home"
  export XDG_DATA_HOME="$HOME/.local/share" XDG_CONFIG_HOME="$HOME/.config" CLAUDE_CONFIG_DIR="$HOME/.claude"
  export DISPLAY=:99 LC_ALL=C.UTF-8
  unset WAYLAND_DISPLAY XDG_CURRENT_DESKTOP CTRL_CLIP_TARBALL
  write_stubs
  if [[ "${1:-}" == --full-path ]]; then
    export PATH="$sandbox/bin:$original_path"
    return
  fi
  local tool path
  for tool in bash sh env cat sed awk grep tr wc ps base64 head tail cut sort mkdir rm rmdir cp mv ln \
    chmod touch stat date basename dirname readlink uname mktemp seq sleep install tar gzip curl find id; do
    path=$(PATH=$original_path command -v "$tool" 2>/dev/null) || continue
    [[ "$path" == /* ]] && ln -s "$path" "$sandbox/sys/$tool"
  done
  export PATH="$sandbox/bin:$sandbox/sys"
}

cleanup_sandbox() { [[ -z "$sandbox" ]] || rm -rf -- "$sandbox"; }

clipboard() { cat "$sandbox/clipboard" 2>/dev/null; }
reset_clipboard() {
  printf SENTINEL > "$sandbox/clipboard"
  : > "$sandbox/calls"
  : > "$sandbox/notifications"
}
