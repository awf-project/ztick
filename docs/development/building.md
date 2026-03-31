# Building the Project

Guide to compiling, testing, and packaging ztick from source.

## Prerequisites

- **Zig 0.15.2** ([download](https://ziglang.org/download/))
- **libssl-dev** (Debian/Ubuntu) or **openssl-devel** (Fedora/RHEL) — required for TLS support
- **git** (optional, for cloning the repository)

Zig package dependencies (fetched automatically by `zig build`):
- **zig-o11y/opentelemetry-sdk** v0.1.1 — OpenTelemetry instrumentation ([ADR-0004](../ADR/0004-opentelemetry-sdk-dependency.md))

## Build Variants

### Debug Build (Default)

```bash
zig build
```

Produces an unoptimized executable with debug symbols. Best for development.

**Output**: `zig-cache/bin/ztick`

**Use case**: Development, debugging, testing

### Release Build (Optimized)

```bash
zig build -Doptimize=ReleaseSafe
```

Produces an optimized executable with safety checks. Recommended for production.

**Output**: `zig-cache/bin/ztick`

**Performance**: 2-3x faster than debug builds

**Use case**: Production deployment

### Release (Unsafe)

```bash
zig build -Doptimize=ReleaseUnsafe
```

Strips all safety checks for maximum speed. Use only if you're confident the code is correct.

**Output**: `zig-cache/bin/ztick`

**Use case**: Benchmarking, extreme performance requirements

## Testing

### Run All Tests

```bash
zig build test
```

Compiles and runs all unit tests across all layers (domain, application, infrastructure, interfaces).

**Output**: Test summary with pass/fail counts

### Selective Testing

Test a specific layer:

```bash
zig build test --test-filter domain
zig build test --test-filter application
zig build test --test-filter infrastructure
zig build test --test-filter interfaces
```

### Functional Tests

Run end-to-end tests:

```bash
zig build test-functional
```

### Test Coverage

ztick aims for high test coverage:

- **Domain**: 95%+ (pure logic, comprehensive tests)
- **Application**: 85%+ (scheduler, storage, query handling)
- **Infrastructure**: 80%+ (adapters, parsers)
- **Overall**: 80%+

To verify coverage, review test blocks in each source file (co-located tests).

## Code Quality

### Format Check

Verify code follows Zig style guide:

```bash
zig fmt --check .
```

### Auto-Format

Fix formatting issues:

```bash
zig fmt .
```

## Build Configuration

The project uses `build.zig` for configuration:

```bash
cat build.zig  # View build configuration
```

### Compiler Flags

You can pass additional flags:

```bash
zig build -Doptimize=ReleaseSafe -Dstrip=true
```

## Cross-Compilation

### Linux to Windows

```bash
zig build -Dtarget=x86_64-windows-gnu
```

### Linux to macOS

```bash
zig build -Dtarget=aarch64-macos
```

### Linux to ARM

```bash
zig build -Dtarget=aarch64-linux-gnu
```

## Installation

After building, install to a system path:

```bash
zig build --prefix=/usr/local install
```

This installs the `ztick` binary to `/usr/local/bin/`.

**Alternative**: Copy the binary manually

```bash
cp zig-cache/bin/ztick /usr/local/bin/ztick
chmod +x /usr/local/bin/ztick
```

## Troubleshooting

### "zig: not found"

Zig is not installed or not in PATH. Install from [ziglang.org](https://ziglang.org).

Verify installation:

```bash
zig version  # Should print 0.15.2
```

### "error: MemoryOutOfBounds"

The test allocator detected a memory leak. Review your test cleanup:

```zig
var gpa = std.heap.GeneralPurposeAllocator(.{}){};
defer _ = gpa.deinit();  // Must have this
```

### Build takes too long

Zig caches build artifacts. To force a clean rebuild:

```bash
rm -rf zig-cache
zig build
```

### Cannot connect to scheduler after build

Ensure the binary was built successfully:

```bash
zig build
ls -la zig-cache/bin/ztick
```

## Development Workflow

### 1. Make Changes

Edit files in `src/`:

```bash
$EDITOR src/domain/job.zig
```

### 2. Run Tests

Test the affected layer:

```bash
zig build test --test-filter domain
```

### 3. Format Code

Keep code style consistent:

```bash
zig fmt .
```

### 4. Build Project

Full build to catch all issues:

```bash
zig build
```

### 5. Manual Testing

Start the scheduler:

```bash
./zig-cache/bin/ztick --config config.toml
```

Test with protocol commands:

```bash
echo 'SET test.job 1711612800' | socat - TCP:localhost:5555
```

## Performance Profiling

### Benchmark Scheduler

To measure how fast the scheduler evaluates jobs:

```bash
# Build release version
zig build -Doptimize=ReleaseSafe

# Run with framerate set high
echo '[database]
framerate = 100' > bench.toml

./zig-cache/bin/ztick --config bench.toml
```

Monitor CPU usage and latency with system tools:

```bash
watch -n 1 'ps aux | grep ztick'
```

### Memory Usage

Check memory consumption:

```bash
valgrind --leak-check=full ./zig-cache/bin/ztick --config config.toml
```

Or on macOS:

```bash
leaks -atExit -- ./zig-cache/bin/ztick --config config.toml
```

## Release Checklist

Before releasing a new version:

- [ ] All tests pass: `zig build test`
- [ ] Code is formatted: `zig fmt --check .`
- [ ] No compiler warnings
- [ ] Documentation is up-to-date
- [ ] Version number bumped in `build.zig.zon`
- [ ] Changelog updated

## See Also

- **[Architecture](architecture.md)** — Design and layer structure
- **[Contributing](contributing.md)** — Code style and submission guidelines
