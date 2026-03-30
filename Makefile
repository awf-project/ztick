.PHONY: build test test-functional lint

build:
	zig build --summary all

test:
	zig build test --summary all

test-functional:
	zig build test-functional --summary all

lint:
	zig fmt --check .
