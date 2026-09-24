# Development tasks. Run from a development clone, never from the installed
# engine (~/.local/share/macos). See docs/development.md.

SH_FILES := bin/macos boot.sh lib/*.sh libexec/macos-* test/run.sh test/stubs/stub test/stubs/defaults

.PHONY: check test lint dev undev status

check: test ## everything CI runs (the suite includes lint and bash 3.2 syntax)

test: ## full test suite (sandboxed; never touches this Mac)
	./test/run.sh

lint: ## shellcheck only (fast)
	shellcheck -x -P . --severity=warning $(SH_FILES)

dev: ## make `macos` run this clone (and link dev dotfiles if known)
	bin/macos dev link --engine "$(CURDIR)"

undev: ## back to the installed engine and dotfiles
	bin/macos dev unlink

status: ## which engine and dotfiles this Mac runs
	bin/macos dev status
