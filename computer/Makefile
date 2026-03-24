# Dev shortcuts. For first-time install, use ./install.sh

.PHONY: run test test-fast test-integration clean help

VENV := .venv
BIN := $(VENV)/bin

help:                                 ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

run: $(VENV)                          ## Start server in foreground
	$(BIN)/parachute server --foreground

test-fast: $(VENV)                    ## Run unit tests only (fast)
	$(BIN)/python -m pytest tests/unit/ tests/core/ -x -q

test: $(VENV)                         ## Run all tests
	$(BIN)/pip install -e ".[dev]" -q
	$(BIN)/python -m pytest tests/ -v

test-integration: $(VENV)             ## Run integration tests (needs server)
	$(BIN)/python -m pytest tests/integration/ -v

clean:                                ## Remove venv and caches
	rm -rf $(VENV)
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

$(VENV):
	@echo "Run ./install.sh first"
	@exit 1
