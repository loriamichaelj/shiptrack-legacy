# Local development targets. CI runs the same commands (see .github/workflows/ci.yml).
PY := .venv/bin/python
BIN := .venv/bin

.PHONY: venv up down lint format typecheck test cov check migrate ui-install ui-check check-all package package-test

venv:
	uv venv --python 3.12 .venv
	uv pip install --python $(PY) --require-hashes -r requirements.txt -r requirements-dev.txt
	uv pip install --python $(PY) --no-deps -e .

up:
	docker compose up -d --wait

down:
	docker compose down

lint:
	$(BIN)/ruff check .
	$(BIN)/ruff format --check .

format:
	$(BIN)/ruff check --fix .
	$(BIN)/ruff format .

typecheck:
	$(BIN)/mypy

test:
	$(BIN)/pytest

# Coverage gate: at least 75% on domain/ and api/.
cov:
	$(BIN)/pytest --cov=shiptrack.domain --cov=shiptrack.api --cov-fail-under=75 --cov-report=term-missing:skip-covered

migrate:
	$(BIN)/alembic upgrade head

check: lint typecheck cov

ui-install:
	cd web && npm ci

# The same UI checks CI runs: lint, typecheck, tests, build, and the dist checks.
ui-check:
	cd web && npm run lint && npm run typecheck && npm test && npm run build && npm run check:dist

check-all: check ui-check

SHA ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)

# Release tarball in dist/ (needs Docker).
package:
	scripts/build_tarball.sh $(SHA)
	shellcheck -x scripts/*.sh tests/packaging/*.sh

# Install the tarball on a fresh amazonlinux:2023 container and exercise deploy and nginx (needs `make up`).
package-test:
	tests/packaging/run.sh $(SHA)
