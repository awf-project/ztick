.PHONY: build test test-functional test-all test-sanitize test-valgrind fmt lint clean

build:
	zig build --summary all

test:
	zig build test --summary all

test-functional:
	zig build test-functional --summary all

test-all:
	zig build test-all --summary all

test-sanitize:
	zig build test-sanitize --summary all

test-valgrind: build
	valgrind --leak-check=full --error-exitcode=1 zig-out/bin/ztick --help

fmt:
	zig fmt .

lint:
	zig fmt --check .

clean:
	rm -rf zig-out .zig-cache
