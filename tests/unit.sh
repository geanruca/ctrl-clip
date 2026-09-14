#!/usr/bin/env bash
# Hermetic unit tests: no display, clipboard or desktop needed. Stub commands record what
# the scripts do inside a throwaway HOME.
# shellcheck disable=SC2016,SC2030,SC2031,SC2088
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
trap cleanup_sandbox EXIT

clip="$skill_src/clip.sh"
handler="$skill_src/clip-url-handler.sh"

# cleaned TEXT — copy printf-escaped TEXT through clip.sh, print the clipboard.
cleaned() {
  printf '%b' "$1" | "$clip" >/dev/null
  clipboard
}

new_sandbox

section "clip.sh: cleaning"
assert_eq "strips > markers, nested ones too" "$(cleaned '> Hi\n> > nested\n>\n> end')" $'Hi\nnested\n\nend'
assert_eq "strips │ ┃ ▎ ▍ ▌ ⎿ ⏺ bars" "$(cleaned '│ a\n┃ b\n▎ c\n▍ d\n▌ e\n⎿ f\n⏺ g')" $'a\nb\nc\nd\ne\nf\ng'
assert_eq "strips indented bars and markers" "$(cleaned '  │ x\n   > y')" $'x\ny'
assert_eq "keeps > and │ inside a line" "$(cleaned 'a > b\nx │ y')" $'a > b\nx │ y'
assert_eq "strips trailing whitespace" "$(cleaned 'a  \nb\t')" $'a\nb'
assert_eq "squeezes runs of blank lines" "$(cleaned 'a\n\n\n\nb')" $'a\n\nb'
assert_eq "trims leading and trailing blank lines" "$(cleaned '\n\n>\na\n>\n\n')" a
assert_eq "no trailing newline on the clipboard" "$(wc -c < "$sandbox/clipboard" | tr -d ' ')" 1

cat > "$sandbox/special.txt" <<'EOF'
> Cost: $5 for $HOME `whoami` "double" 'single' \n ✅ *bold* _it_
EOF
"$clip" "$sandbox/special.txt" >/dev/null
assert_eq "file argument keeps \$, backticks, quotes, backslashes and emoji" "$(clipboard)" \
  "Cost: \$5 for \$HOME \`whoami\` \"double\" 'single' \\n ✅ *bold* _it_"
assert_eq "reports lines and characters" "$(printf 'Hi\n\n- ok ✅\n' | "$clip")" "⧉ Copied 3 lines / 10 chars"

section "clip.sh: clipboard backend"
backend() {
  : > "$sandbox/calls"
  echo hi | "$clip" >/dev/null 2>&1 || true
  head -n 1 "$sandbox/calls"
}
assert_eq "Wayland session → wl-copy" "$(export WAYLAND_DISPLAY=wayland-0; backend)" wl-copy
assert_eq "X11 session → xclip" "$(backend)" xclip
drop_stub wl-copy
assert_eq "Wayland without wl-copy → xclip (XWayland)" "$(export WAYLAND_DISPLAY=wayland-0; backend)" xclip
drop_stub xclip
assert_eq "X11 without xclip → xsel" "$(backend)" xsel
write_stubs
assert_eq "no display → pbcopy" "$(unset DISPLAY; backend)" pbcopy
drop_stub pbcopy
stub ps 'if [[ "$*" == *tty=* ]]; then echo "?"; else echo 1; fi'
status=0
err=$( (unset DISPLAY; echo hi | "$clip") 2>&1 >/dev/null) || status=$?
assert_eq "no backend and no terminal → exit 1" "$status" 1
assert_contains "no backend and no terminal → explains why" "$err" "no clipboard backend available"
drop_stub ps
write_stubs

section "clip-url-handler.sh: only drafts in ~/.cache/claude-clip"
new_sandbox
clip_dir="$HOME/.cache/claude-clip"
run_handler() {
  reset_clipboard
  local status=0
  "$handler" "$@" >/dev/null 2>&1 || status=$?
  echo "$status"
}
rejected() { # NAME PATH
  assert_eq "$1 → rejected" "$(run_handler "$2")" 1
  assert_eq "$1 → clipboard untouched" "$(clipboard)" SENTINEL
}

rejected "missing draft" "$clip_dir/missing.claudeclip"
assert_contains "missing draft → 'not found' notification" "$(cat "$sandbox/notifications")" "Draft 'missing' not found"
assert_eq "creates the drafts dir with mode 700" "$(stat -c %a "$clip_dir")" 700

draft="$sandbox/draft.txt"
printf '> Hi team\n>\n│ - done\n' > "$draft"
cp "$draft" "$clip_dir/slack-42_review.claudeclip"
assert_eq "valid draft → exit 0" "$(run_handler "$clip_dir/slack-42_review.claudeclip")" 0
assert_eq "valid draft → clean text on the clipboard" "$(clipboard)" $'Hi team\n\n- done'
assert_contains "valid draft → notification with the summary" "$(cat "$sandbox/notifications")" "⧉ Copied 3 lines"
assert_eq "file:// URL form → exit 0" "$(run_handler "file://$clip_dir/slack-42_review.claudeclip")" 0

mkdir -p "$HOME/.cache/other"
cp "$draft" "$HOME/.cache/other/x.claudeclip"
cp "$draft" "$HOME/.cache/outside.claudeclip"
rejected "file outside the drafts dir" "$HOME/.cache/outside.claudeclip"
assert_contains "outside file → 'Invalid link' notification" "$(cat "$sandbox/notifications")" "Invalid link"
rejected "../ traversal" "$clip_dir/../other/x.claudeclip"
cp "$draft" "$clip_dir/bad id.claudeclip"
rejected "id with a space" "$clip_dir/bad id.claudeclip"
cp "$draft" "$clip_dir/a@b.claudeclip"
rejected "id with @" "$clip_dir/a@b.claudeclip"
id64=$(printf 'a%.0s' $(seq 64))
cp "$draft" "$clip_dir/$id64.claudeclip"
cp "$draft" "$clip_dir/b$id64.claudeclip"
assert_eq "64-character id → accepted" "$(run_handler "$clip_dir/$id64.claudeclip")" 0
rejected "65-character id" "$clip_dir/b$id64.claudeclip"
cp "$draft" "$clip_dir/note.txt"
rejected "wrong extension" "$clip_dir/note.txt"
ln -s "$HOME/.cache/outside.claudeclip" "$clip_dir/link.claudeclip"
rejected "symlink" "$clip_dir/link.claudeclip"
assert_eq "no argument → rejected" "$(run_handler)" 1
assert_eq "logs every invocation" "$(wc -l < "$clip_dir/handler.log" | tr -d ' ')" 12

section "clip-setup.sh: registration"
new_sandbox
skill="$CLAUDE_CONFIG_DIR/skills/ctrl-clip"
mkdir -p "$skill"
cp "$skill_src"/* "$skill/"
chmod -x "$skill/clip.sh"
mime_file="$XDG_DATA_HOME/mime/packages/claude-clip.xml"
desktop_file="$XDG_DATA_HOME/applications/claude-clip-url-handler.desktop"

assert_eq "prints the absolute drafts dir" "$("$skill/clip-setup.sh")" "CLIP_DIR=$HOME/.cache/claude-clip"
assert_contains "installs the *.claudeclip MIME glob" "$(cat "$mime_file")" '<glob pattern="*.claudeclip" weight="100"/>'
assert_contains "desktop entry runs this skill's handler" "$(cat "$desktop_file")" "Exec=$skill/clip-url-handler.sh %f"
assert_eq "sets the default app" "$(cat "$sandbox/mime-default")" claude-clip-url-handler.desktop
assert_eq "refreshes both databases" "$(grep -c '^update-' "$sandbox/calls")" 2
assert_eq "makes the scripts executable" "$([[ -x "$skill/clip.sh" ]] && echo yes)" yes

stamps() { stat -c %y "$mime_file" "$desktop_file"; }
before=$(stamps)
: > "$sandbox/calls"
"$skill/clip-setup.sh" >/dev/null
assert_eq "second run rewrites nothing" "$(stamps)" "$before"
assert_eq "second run refreshes nothing" "$(cat "$sandbox/calls")" ""

spaced="$sandbox/my skills/ctrl-clip"
mkdir -p "$spaced"
cp "$skill_src"/* "$spaced/"
"$spaced/clip-setup.sh" >/dev/null
assert_contains "quotes an Exec path with spaces" "$(cat "$desktop_file")" "Exec=\"$spaced/clip-url-handler.sh\" %f"
"$skill/clip-setup.sh" >/dev/null

rule=$("$skill/clip-setup.sh" --rule)
assert_contains "rule names the ctrl-clip skill" "$rule" '`ctrl-clip` skill'
assert_contains "rule has the absolute file:// link" "$rule" "(file://$HOME/.cache/claude-clip/<id>.claudeclip)"
assert_not_contains "rule never uses ~/" "$rule" '~/'
assert_not_contains "rule never uses \$HOME" "$rule" '$HOME'
status=0
hook=$(PATH="$sandbox/sys" "$skill/clip-setup.sh" --hook 2>/dev/null) || status=$?
assert_eq "--hook prints the rule even without xdg tools" "$hook" "$rule"
assert_eq "--hook exits 0 even without xdg tools" "$status" 0
assert_status "unknown option → exit 2" 2 "$skill/clip-setup.sh" --bogus

section "clip-setup.sh: autoload rule in CLAUDE.md"
mkdir -p "$CLAUDE_CONFIG_DIR"
printf '# My notes\n\nKeep this.\n' > "$sandbox/dotfiles-CLAUDE.md"
ln -s "$sandbox/dotfiles-CLAUDE.md" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
"$skill/clip-setup.sh" --claude-md >/dev/null
"$skill/clip-setup.sh" --claude-md >/dev/null
md=$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")
assert_eq "one managed block after two runs" "$(grep -c '^<!-- claude-clip:begin -->$' <<< "$md")" 1
assert_contains "keeps existing content" "$md" $'# My notes\n\nKeep this.'
assert_contains "block holds the rule" "$md" "$rule"
assert_eq "a symlinked CLAUDE.md stays a symlink" "$(readlink "$CLAUDE_CONFIG_DIR/CLAUDE.md")" "$sandbox/dotfiles-CLAUDE.md"
assert_eq "backs up the original" "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md.claude-clip.bak")" $'# My notes\n\nKeep this.'
printf '\n## Drafts to paste\nan old hand-written rule\n' >> "$sandbox/dotfiles-CLAUDE.md"
assert_contains "warns about an unmanaged 'Drafts to paste' section" \
  "$("$skill/clip-setup.sh" --claude-md 2>&1 >/dev/null)" "unmanaged"

section "clip-setup.sh: uninstall"
"$skill/clip-setup.sh" --uninstall >/dev/null
assert_eq "removes the MIME package" "$([[ -e "$mime_file" ]] && echo present || echo gone)" gone
assert_eq "removes the desktop entry" "$([[ -e "$desktop_file" ]] && echo present || echo gone)" gone
assert_eq "removes the drafts dir" "$([[ -e "$HOME/.cache/claude-clip" ]] && echo present || echo gone)" gone
md=$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")
assert_not_contains "removes the managed block" "$md" "claude-clip:begin"
assert_contains "keeps the rest of CLAUDE.md" "$md" "Keep this."

section "install.sh"
new_sandbox
skill="$CLAUDE_CONFIG_DIR/skills/ctrl-clip"
out=$("$root_dir/install.sh" --no-test --no-autoload 2>&1)
assert_eq "installs the skill files with the right modes" \
  "$(cd "$skill" && stat -c '%n %a' SKILL.md clip.sh clip-url-handler.sh clip-setup.sh | tr '\n' ' ')" \
  "SKILL.md 644 clip.sh 755 clip-url-handler.sh 755 clip-setup.sh 755 "
assert_eq "registers the handler" "$(cat "$sandbox/mime-default")" claude-clip-url-handler.desktop
assert_eq "--no-autoload leaves CLAUDE.md alone" "$([[ -e "$CLAUDE_CONFIG_DIR/CLAUDE.md" ]] && echo exists || echo absent)" absent
assert_contains "warns when the TUI isn't fullscreen" "$out" '"tui": "fullscreen"'

printf '{\n  "tui": "fullscreen"\n}\n' > "$CLAUDE_CONFIG_DIR/settings.json"
out=$("$root_dir/install.sh" --no-test 2>&1)
assert_not_contains "no TUI warning once fullscreen is on" "$out" 'has no "tui"'
assert_contains "adds the autoload rule by default" "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")" "<!-- claude-clip:begin -->"

pkg="$sandbox/pkg/ctrl-clip-main"
mkdir -p "$pkg/skills"
cp -R "$skill_src" "$pkg/skills/"
cp "$root_dir/install.sh" "$pkg/"
tar -czf "$sandbox/main.tar.gz" -C "$sandbox/pkg" ctrl-clip-main
rm -rf "$CLAUDE_CONFIG_DIR/skills"
status=0
out=$(cd "$sandbox" && cat "$root_dir/install.sh" | CTRL_CLIP_TARBALL="file://$sandbox/main.tar.gz" bash -s -- --no-test --no-autoload 2>&1) || status=$?
assert_eq "piped install (curl | bash) exits 0" "$status" 0
assert_eq "piped install downloads and installs the skill" "$([[ -x "$skill/clip-setup.sh" ]] && echo installed)" installed

status=0
out=$(env -u DISPLAY -u WAYLAND_DISPLAY "$root_dir/install.sh" --no-test 2>&1) || status=$?
assert_eq "no desktop session → exit 1" "$status" 1
assert_contains "no desktop session → explains SSH" "$out" "over plain SSH"
drop_stub update-desktop-database
status=0
out=$("$root_dir/install.sh" --no-test 2>&1) || status=$?
assert_eq "missing dependency → exit 1" "$status" 1
assert_contains "missing dependency → names it and the package" "$out" "Missing: update-desktop-database"
write_stubs
"$root_dir/install.sh" --uninstall >/dev/null
assert_eq "--uninstall removes the skill" "$([[ -e "$skill" ]] && echo present || echo gone)" gone
assert_not_contains "--uninstall removes the autoload rule" "$(cat "$CLAUDE_CONFIG_DIR/CLAUDE.md")" "claude-clip:begin"

section "Manifests and shareable content"
for json in .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json; do
  assert_status "$json is valid JSON" 0 env PATH="$original_path" python3 -m json.tool "$root_dir/$json"
done
assert_eq "SKILL.md name matches its folder" "$(sed -n 's/^name: //p' "$skill_src/SKILL.md")" ctrl-clip
assert_eq "plugin and marketplace are named ctrl-clip" \
  "$(cat "$root_dir/.claude-plugin/plugin.json" "$root_dir/.claude-plugin/marketplace.json" | grep -c '"name": "ctrl-clip"')" 3
hook_script=$(sed -n 's/.*CLAUDE_PLUGIN_ROOT}\/\([^\\"]*\).*/\1/p' "$root_dir/hooks/hooks.json")
assert_eq "SessionStart hook points at an executable script" "$([[ -x "$root_dir/$hook_script" ]] && echo "$hook_script")" skills/ctrl-clip/clip-setup.sh
leaks=$(cd "$root_dir" && grep -rInE '/(home|Users)/[A-Za-z0-9._-]+' --exclude-dir=.git . | grep -vE '/(home|Users)/(alice|runner)\b' || true)
assert_eq "no personal home paths in the repo" "$leaks" ""

finish
