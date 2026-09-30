PREFIX ?= $(HOME)/.local
APP_HOME ?= $(PREFIX)/share/repobar
BIN_DIR ?= $(PREFIX)/bin

.PHONY: help test check syntax lint install-user uninstall

help:
	@printf '%s\n' \
		'repobar targets:' \
		'  test                Run Ruby tests' \
		'  syntax              Ruby -wc over bin, lib and test' \
		'  lint                qmllint the QuickShell panel' \
		'  check               Syntax, tests, and config validation' \
		'  install-user        Install app under ~/.local' \
		'  uninstall           Remove the installed app and link'

test:
	ruby -Itest test/run.rb

# rg is required, and its absence must fail the gate rather than silently skip
# the syntax check (which is what `ruby -wc` with no arguments did).
syntax:
	@command -v rg >/dev/null || { echo "repobar: ripgrep (rg) is required"; exit 1; }
	ruby -wc $$(rg --files bin lib test) >/dev/null || exit 1

lint:
	@command -v qmllint >/dev/null || { echo "repobar: qmllint is required (qt6-declarative-dev-tools)"; exit 1; }
	qmllint frontend/quickshell/shell.qml

check: syntax
	ruby -Itest test/run.rb
	bin/repobar config validate

install-user:
	mkdir -p "$(APP_HOME)" "$(BIN_DIR)"
	cp -R bin lib frontend README.md AGENTS.md docs "$(APP_HOME)/"
	ln -sf "$(APP_HOME)/bin/repobar" "$(BIN_DIR)/repobar"
	chmod +x "$(APP_HOME)/bin/repobar"

uninstall:
	rm -rf "$(APP_HOME)"
	rm -f "$(BIN_DIR)/repobar"
