SHELL := /bin/bash

.PHONY: app engine run clean fmt

app:
	@./scripts/build-app.sh

engine:
	@mkdir -p build
	@cd engine && go build -o ../build/mcstackr-engine ./cmd/mcstackr-engine

run: app
	@open build/MCStackr.app

fmt:
	@cd engine && gofmt -w .
	@cd app && swift format --in-place --recursive Sources 2>/dev/null || true

clean:
	@rm -rf build app/.build
