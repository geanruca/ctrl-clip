#!/usr/bin/env bash
# End-to-end test on a real desktop session (or under xvfb-run in CI). Installs into a
# throwaway HOME and runs the self-test, which opens a draft through the real xdg-open and
# reads the real clipboard. Your own MIME registrations, CLAUDE.md and clipboard text are
# left as they were.
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
  echo "skipped: no desktop session (run it from a desktop terminal or under xvfb-run)"
  exit 0
fi

sandbox=$(mktemp -d)
trap 'rm -rf -- "$sandbox"' EXIT
export HOME="$sandbox/home"
export XDG_DATA_HOME="$HOME/.local/share" XDG_CONFIG_HOME="$HOME/.config" CLAUDE_CONFIG_DIR="$HOME/.claude"
mkdir -p "$HOME"

# install.sh ends with clip-setup.sh --check, which exits non-zero if any check fails.
"$root_dir/install.sh" --no-autoload

"$CLAUDE_CONFIG_DIR/skills/ctrl-clip/clip-setup.sh" --uninstall
if [[ -e "$XDG_DATA_HOME/applications/claude-clip-url-handler.desktop" ]]; then
  echo "✗ uninstall left the desktop entry behind"
  exit 1
fi
echo "⧉ Integration test passed"
