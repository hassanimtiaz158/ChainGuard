# ChainGuard developer tasks.
#
# NOTE: these recipes assume a POSIX shell. On native Windows (PowerShell/cmd)
# run the underlying commands directly, e.g. `cd contracts && forge test`.

SHELL := /bin/bash
.DEFAULT_GOAL := help

CONTRACTS := contracts
BACKEND   := backend
FRONTEND  := frontend

.PHONY: help deps build test lint fmt up down logs clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'

deps: ## Vendor pinned Foundry libraries into contracts/lib
	cd $(CONTRACTS) && forge install --no-git --shallow \
		foundry-rs/forge-std@v1.17.0 \
		OpenZeppelin/openzeppelin-contracts@v5.7.0

build: ## Build contracts, backend and frontend
	cd $(CONTRACTS) && forge build
	cd $(BACKEND)   && uv sync
	cd $(FRONTEND)  && npm run build

test: ## Run contract, backend and frontend test suites
	cd $(CONTRACTS) && forge test
	cd $(BACKEND)   && uv run pytest
	cd $(FRONTEND)  && npm run test

lint: ## Lint and type-check every workspace
	cd $(CONTRACTS) && forge fmt --check
	cd $(BACKEND)   && uv run ruff check . && uv run ruff format --check . && uv run mypy app worker
	cd $(FRONTEND)  && npm run lint && npm run typecheck

fmt: ## Auto-format every workspace
	cd $(CONTRACTS) && forge fmt
	cd $(BACKEND)   && uv run ruff format . && uv run ruff check --fix .
	cd $(FRONTEND)  && npm run format

up: ## Start the full Docker Compose stack
	docker compose up -d

down: ## Stop the stack and remove volumes
	docker compose down -v

logs: ## Tail logs for every service
	docker compose logs -f

clean: ## Remove build artifacts
	rm -rf $(CONTRACTS)/out $(CONTRACTS)/cache $(CONTRACTS)/broadcast
	rm -rf $(FRONTEND)/.next $(FRONTEND)/node_modules
	find $(BACKEND) -type d -name __pycache__ -prune -exec rm -rf {} +