# Lifio backend — common commands
.PHONY: build test test:race test:cover test:pg lint run docker-build docker-run deploy prod-up prod-down prod-logs prod-ps help

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-20s\033[0m %s\n", $$1, $$2}'

build: ## Build the Go binary
	go build ./...

test: ## Run all tests (no Docker required)
	go test ./... -cover

test:race: ## Run all tests with the race detector
	go test ./... -race

test:cover: ## Run all tests and print per-function coverage
	go test ./... -coverprofile=coverage.out
	go tool cover -func=coverage.out

test:pg: ## Run PostgreSQL parity tests (needs `docker compose up -d postgres`)
	TEST_PG_DSN="postgres://postgres:postgres@localhost:5432/timeoflife?sslmode=disable" go test ./internal/db -run 'Postgres' -v

lint: ## Run all linters
	out="$$(gofmt -l .)"; if [ -n "$$out" ]; then echo "$$out"; exit 1; fi
	go vet ./...
	golangci-lint run

run: ## Run the server locally (needs Postgres via docker-compose)
	go run ./cmd/server

docker-build: ## Build the Docker image
	docker build -t time-of-life-backend .

docker-run: ## Run with docker-compose (local)
	docker compose up -d postgres
	go run ./cmd/server

deploy: ## Deploy to production (requires CI/CD secrets)
	@echo "Deployment is handled by GitHub Actions CI/CD pipeline."
	@echo "Push to main branch to trigger automatic deployment."

# --- Production docker-compose shortcuts ---

prod-up: ## Start production services on the VM
	docker compose -f docker-compose.prod.yml up -d

prod-down: ## Stop production services
	docker compose -f docker-compose.prod.yml down

prod-logs: ## View production logs
	docker compose -f docker-compose.prod.yml logs -f

prod-ps: ## List production services
	docker compose -f docker-compose.prod.yml ps
