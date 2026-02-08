.PHONY: install install-global run test clean help

VENV := .venv
BIN := $(VENV)/bin
PY := python3

help:                                 ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

$(VENV): pyproject.toml
	$(PY) -m venv $(VENV)
	$(BIN)/pip install --upgrade pip setuptools wheel
	$(BIN)/pip install -e .
	@touch $(VENV)

install: $(VENV)                      ## Full install: venv + deps + setup + daemon
	$(BIN)/parachute install

install-global: $(VENV)               ## Also install wrapper to ~/.local/bin
	@mkdir -p $(HOME)/.local/bin
	@printf '#!/usr/bin/env bash\nexec "$(CURDIR)/$(BIN)/python" -m parachute "$$@"\n' > $(HOME)/.local/bin/parachute
	@chmod +x $(HOME)/.local/bin/parachute
	@echo "Installed: $(HOME)/.local/bin/parachute"

run: $(VENV)                          ## Start server in foreground
	$(BIN)/parachute server --foreground

test: $(VENV)                         ## Run tests
	$(BIN)/python -m pytest tests/ -v

clean:                                ## Remove venv and caches
	rm -rf $(VENV)
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
