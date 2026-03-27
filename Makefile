.PHONY: build test lint

build:
	zig build --summary all

test:
	zig build test --summary all

lint:
	zig fmt --check .
