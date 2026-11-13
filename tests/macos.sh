#!/bin/bash
# macOS check: clip.sh must clean drafts exactly as on Linux with BSD sed/wc/ps, the
# system bash 3.2 and zsh, and copy through pbcopy. The Ctrl+click link is Linux-only.
# shellcheck disable=SC2016  # $ and backticks are literal draft text
set -eu

root_dir=$(cd "$(dirname "$0")/.." && pwd)
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir "$sandbox/bin"
cat > "$sandbox/bin/pbcopy" <<EOF
#!/bin/sh
cat > "$sandbox/clipboard"
printf '%s' "\${LC_ALL:-\${LC_CTYPE:-\${LANG:-}}}" > "$sandbox/locale"
EOF
chmod +x "$sandbox/bin/pbcopy"

export PATH="$sandbox/bin:$PATH" LC_ALL=en_US.UTF-8
export CLIP="$root_dir/skills/ctrl-clip/clip.sh" DRAFT="$sandbox/draft.txt"
unset DISPLAY WAYLAND_DISPLAY
printf '%s\n' '> Hi team, the deploy is done ✅' '>' '│ - API latency is back to normal' \
  '▎ - cost: $0 `extra` "quoted"   ' '' '' > "$DRAFT"
expected='Hi team, the deploy is done ✅

- API latency is back to normal
- cost: $0 `extra` "quoted"'

failures=0
run() {
  name=$1
  shift
  rm -f "$sandbox/clipboard"
  if out=$("$@" 2>&1) && [ "$(cat "$sandbox/clipboard" 2>/dev/null)" = "$expected" ]; then
    echo "  ✓ $name: $out"
  else
    echo "  ✗ $name"
    echo "      output:    $out"
    echo "      clipboard: $(cat "$sandbox/clipboard" 2>/dev/null)"
    failures=$((failures + 1))
  fi
}

echo "bash $(/bin/bash -c 'echo $BASH_VERSION'), zsh $(zsh -fc 'echo $ZSH_VERSION')"
run "bash 3.2, file argument" /bin/bash "$CLIP" "$DRAFT"
run "bash 3.2, stdin" /bin/bash -c '/bin/bash "$CLIP" < "$DRAFT"'
run "zsh, pipe" zsh -f -c 'cat "$DRAFT" | "$CLIP"'
run "/usr/bin/env bash" "$CLIP" "$DRAFT"

# The real pbcopy reads stdin as MacRoman unless the locale is UTF-8, and Claude Code's
# Bash tool runs with no locale at all: clip.sh must hand pbcopy a UTF-8 locale.
rm -f "$sandbox/locale"
if env -u LC_ALL -u LC_CTYPE -u LANG /bin/bash "$CLIP" "$DRAFT" >/dev/null 2>&1 \
  && case $(cat "$sandbox/locale" 2>/dev/null) in *[Uu][Tt][Ff]-8) true ;; *) false ;; esac; then
  echo "  ✓ no locale set: pbcopy runs under $(cat "$sandbox/locale")"
else
  echo "  ✗ no locale set: pbcopy ran under '$(cat "$sandbox/locale" 2>/dev/null)', accents would paste as MacRoman"
  failures=$((failures + 1))
fi
[ "$failures" -eq 0 ]
