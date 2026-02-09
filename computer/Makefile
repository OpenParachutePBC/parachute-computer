# Dev shortcuts. For first-time install, use ./install.sh

.PHONY: run test clean help

VENV := .venv
BIN := $(VENV)/bin

help:                                 ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

run: $(VENV)                          ## Start server in foreground
	$(BIN)/parachute server --foreground

test: $(VENV)                         ## Run tests
	$(BIN)/pip install -e ".[dev]" -q
	$(BIN)/python -m pytest tests/ -v

clean:                                ## Remove venv and caches
	rm -rf $(VENV)
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

$(VENV):
	@echo "Run ./install.sh first"
	@exit 1
