# ctrl-clip test targets. `make test` runs everything this machine can run.
SCRIPTS := install.sh $(wildcard skills/ctrl-clip/*.sh) $(wildcard tests/*.sh)
JSON := .claude-plugin/plugin.json .claude-plugin/marketplace.json hooks/hooks.json

.PHONY: test lint unit shells integration

test: lint unit shells integration

lint:
	@if command -v shellcheck >/dev/null; then shellcheck -x -P SCRIPTDIR $(SCRIPTS) && echo "shellcheck OK"; \
	else echo "shellcheck not installed; skipping (CI runs it)"; fi
	@for f in $(JSON); do python3 -m json.tool $$f >/dev/null || exit 1; done; echo "JSON manifests OK"

unit:
	@bash tests/unit.sh

shells:
	@bash tests/shells.sh

integration:
	@bash tests/integration.sh
