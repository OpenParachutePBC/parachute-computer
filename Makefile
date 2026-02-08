.PHONY: install install-global update run test clean help

VENV := .venv
BIN := $(VENV)/bin
PY := python3

help:                                 ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

$(VENV): pyproject.toml
	$(PY) -m venv $(VENV)
	$(BIN)/pip install --upgrade pip setuptools wheel -q
	$(BIN)/pip install -e . -q
	@touch $(VENV)

install: $(VENV)                      ## First-time install: venv + deps + config + daemon
	$(BIN)/parachute install

install-global: $(VENV)               ## Install wrapper to ~/.local/bin
	@mkdir -p $(HOME)/.local/bin
	@printf '#!/usr/bin/env bash\nexec "$(CURDIR)/$(BIN)/python" -m parachute "$$@"\n' > $(HOME)/.local/bin/parachute
	@chmod +x $(HOME)/.local/bin/parachute
	@echo "Installed: $(HOME)/.local/bin/parachute"

update:                               ## Pull latest code and reinstall deps
	git pull
	$(BIN)/pip install -e . -q
	@echo "Updated. Restart the server: parachute server restart"

run: $(VENV)                          ## Start server in foreground
	$(BIN)/parachute server --foreground

test: $(VENV)                         ## Run tests
	$(BIN)/pip install -e ".[dev]" -q
	$(BIN)/python -m pytest tests/ -v

clean:                                ## Remove venv and caches
	rm -rf $(VENV)
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
