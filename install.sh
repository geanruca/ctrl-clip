#!/usr/bin/env bash
# Installs the ctrl-clip skill for Claude Code on a Linux desktop (X11 or Wayland).
#
#   curl -fsSL https://raw.githubusercontent.com/geanruca/ctrl-clip/main/install.sh | bash
#   ./install.sh [--no-autoload] [--no-test] [--uninstall]
#
#   --no-autoload  don't add the "Drafts to paste" rule to CLAUDE.md (the skill then only
#                  runs when Claude decides to invoke it, or when you type /ctrl-clip)
#   --no-test      skip the end-to-end self-test
#   --uninstall    remove the skill and everything it registered
#
# Honors CLAUDE_CONFIG_DIR (default ~/.claude) and XDG_DATA_HOME.
set -euo pipefail

repo_tarball="${CTRL_CLIP_TARBALL:-https://github.com/geanruca/ctrl-clip/archive/refs/heads/main.tar.gz}"  # override (e.g. file://…) for offline tests
claude_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
skill_dir="$claude_dir/skills/ctrl-clip"
skill_files=(SKILL.md clip.sh clip-url-handler.sh clip-setup.sh)

say() { printf '⧉ %s\n' "$*"; }
warn() { printf '⚠ %s\n' "$*" >&2; }
die() { printf '✗ %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,13s/^# \{0,1\}//p' "${BASH_SOURCE[0]:-install.sh}" 2>/dev/null || echo "see https://github.com/geanruca/ctrl-clip"; }

suggest_packages() {
  local clipboard=$1 manager
  for manager in apt-get dnf pacman zypper; do
    command -v "$manager" >/dev/null || continue
    case $manager in
      apt-get) echo "sudo apt install xdg-utils shared-mime-info desktop-file-utils libnotify-bin $clipboard" ;;
      dnf) echo "sudo dnf install xdg-utils shared-mime-info desktop-file-utils libnotify $clipboard" ;;
      pacman) echo "sudo pacman -S xdg-utils shared-mime-info desktop-file-utils libnotify $clipboard" ;;
      zypper) echo "sudo zypper install xdg-utils shared-mime-info desktop-file-utils libnotify-tools $clipboard" ;;
    esac
    return
  done
  echo "install: xdg-utils shared-mime-info desktop-file-utils libnotify $clipboard"
}

check_requirements() {
  [[ "$(uname -s)" == Linux ]] || die "Ctrl+click copy links need a Linux desktop (freedesktop MIME types + xdg-open)."

  if [[ -z "${DISPLAY:-}" && -z "${WAYLAND_DISPLAY:-}" ]]; then
    die "No desktop session found (DISPLAY and WAYLAND_DISPLAY are empty). Run the installer from a terminal on the desktop where Claude Code runs; over plain SSH, xdg-open and the clipboard would act on the remote machine."
  fi

  local clipboard_pkg=xclip cmd missing=()
  local required=(xdg-open xdg-mime update-mime-database update-desktop-database)
  if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
    clipboard_pkg=wl-clipboard
    required+=(wl-copy wl-paste)
  elif ! command -v xsel >/dev/null; then
    required+=(xclip)
  fi
  for cmd in "${required[@]}"; do
    command -v "$cmd" >/dev/null || missing+=("$cmd")
  done
  if (( ${#missing[@]} )); then
    die "Missing: ${missing[*]}. Install them with:
    $(suggest_packages "$clipboard_pkg")"
  fi
  command -v notify-send >/dev/null || warn "notify-send not found: copying works, but without a desktop notification ($(suggest_packages "" | sed 's/ *$//'))."

  local settings="$claude_dir/settings.json"
  if ! grep -Eq '"tui"[[:space:]]*:[[:space:]]*"fullscreen"' "$settings" 2>/dev/null; then
    warn "$settings has no \"tui\": \"fullscreen\". The Ctrl+click flow is verified in fullscreen mode; enable it with /config or add that key."
  fi
}

# Sets $src to the directory holding skills/ctrl-clip: this checkout, or a fresh download
# (removed on exit) when the script is piped from curl.
resolve_source() {
  src=""
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    src=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  fi
  [[ -n "$src" && -f "$src/skills/ctrl-clip/SKILL.md" ]] && return

  src=$(mktemp -d)
  trap 'rm -rf -- "$src"' EXIT
  if command -v curl >/dev/null; then
    curl -fsSL "$repo_tarball" | tar -xz -C "$src" --strip-components=1
  elif command -v wget >/dev/null; then
    wget -qO- "$repo_tarball" | tar -xz -C "$src" --strip-components=1
  else
    die "Need curl or wget to download ctrl-clip."
  fi
}

uninstall() {
  if [[ -x "$skill_dir/clip-setup.sh" ]]; then
    "$skill_dir/clip-setup.sh" --uninstall
  fi
  local file
  for file in "${skill_files[@]}"; do rm -f -- "${skill_dir:?}/$file"; done
  rmdir -- "$skill_dir" 2>/dev/null || true
  say "Removed $skill_dir"
}

main() {
  local autoload=1 self_test=1 arg
  for arg in "$@"; do
    case $arg in
      --no-autoload) autoload=0 ;;
      --no-test) self_test=0 ;;
      --uninstall) uninstall; return ;;
      -h | --help) usage; return ;;
      *) die "Unknown option: $arg (see --help)" ;;
    esac
  done

  check_requirements

  resolve_source
  mkdir -p -- "$skill_dir"
  if [[ "$(readlink -f -- "$skill_dir")" != "$(readlink -f -- "$src/skills/ctrl-clip")" ]]; then
    install -m 644 -- "$src/skills/ctrl-clip/SKILL.md" "$skill_dir/SKILL.md"
    install -m 755 -- "$src/skills/ctrl-clip/clip.sh" "$src/skills/ctrl-clip/clip-url-handler.sh" \
      "$src/skills/ctrl-clip/clip-setup.sh" "$skill_dir/"
  fi
  say "Skill installed in $skill_dir"

  "$skill_dir/clip-setup.sh" >/dev/null
  say "Registered *.claudeclip → claude-clip-url-handler.desktop"

  if (( autoload )); then
    "$skill_dir/clip-setup.sh" --claude-md
  fi
  if (( self_test )); then
    "$skill_dir/clip-setup.sh" --check
  fi

  say "Done. Restart Claude Code, ask it to draft a Slack message, then Ctrl+click \"⧉ ctrl + click\"."
}

main "$@"
