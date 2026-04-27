---
title: "Contributing to ztick"
---

This guide explains how to contribute code, documentation, and bug reports to ztick.

## Code of Conduct

Be respectful and constructive. We welcome contributions from everyone.

## Getting Started

### 1. Fork and Clone

```bash
git clone https://github.com/yourusername/ztick.git
cd ztick
```

### 2. Create a Branch

Use descriptive branch names:

```bash
git checkout -b feature/add-http-runner
# or
git checkout -b fix/protocol-parsing-bug
# or
git checkout -b docs/api-reference
```

### 3. Make Changes

Follow the architecture and conventions described in [Architecture](architecture.md).

### 4. Run Tests

Ensure all tests pass:

```bash
zig build test
```

### 5. Format Code

Enforce code style:

```bash
zig fmt .
```

### 6. Commit

Write clear, concise commit messages:

```bash
git commit -m "feat: implement HTTP runner adapter

- Add HTTP client interface
- Support webhook execution
- Add tests for HTTP parsing and requests"
```

### 7. Push and Open PR

```bash
git push origin feature/add-http-runner
```

Then open a pull request on GitHub with a clear description of your changes.

## Code Style Guide

### Zig Conventions

1. **Naming**
   - Variables and functions: `snake_case`
   - Types and structs: `PascalCase`
   - Constants: `SCREAMING_SNAKE_CASE`

   ```zig
   const max_jobs = 1000;  // constant
   const Job = struct { ... };  // type
   fn process_job() void { ... }  // function
   var current_job: Job = undefined;  // variable
   ```

2. **Functions**
   - Keep functions short (< 50 lines)
   - Use descriptive names that explain intent
   - Document public functions with doc comments

   ```zig
   /// Processes a job and returns the execution result.
   /// Caller owns the returned memory.
   pub fn process(allocator: std.mem.Allocator, job: Job) !?Execution {
       // implementation
   }
   ```

3. **Error Handling**
   - Use error unions (`!Type`) for fallible operations
   - Propagate errors with `try` keyword
   - Avoid panic in library code

   ```zig
   // Good
   const job = try scheduler.get_job(id);

   // Bad
   const job = scheduler.get_job(id) orelse unreachable;
   ```

4. **Memory Management**
   - Pass allocator as parameter to all functions that allocate
   - Document who owns returned memory
   - Use `defer` for cleanup

   ```zig
   pub fn create_job(allocator: std.mem.Allocator, id: []const u8) !Job {
       const owned_id = try allocator.dupe(u8, id);
       defer allocator.free(owned_id);
       // Use owned_id
   }
   ```

### Architecture Compliance

1. **Dependency Direction**
   - Domain → only uses Zig stdlib
   - Application → uses Domain + stdlib
   - Infrastructure → uses Domain + Application + stdlib
   - Interfaces → uses all layers

   Check your imports:
   ```zig
   // In domain/job.zig
   const std = @import("std");  // ✓ OK
   const application = @import("../application.zig");  // ✗ Violates architecture
   ```

2. **Testing**
   - Co-locate unit tests with implementation
   - Use `test` blocks in the same file
   - Aim for 80%+ coverage

   ```zig
   pub const Job = struct {
       identifier: []const u8,
       execution: i64,
   };

   test "job creation" {
       const job = Job{ .identifier = "test", .execution = 1000 };
       try std.testing.expect(job.execution == 1000);
   }
   ```

3. **Error Messages**
   - Be specific: "invalid job identifier" not "invalid"
   - Lowercase start: "expected whitespace, found EOF"

### Documentation

1. **Comments**
   - Explain "why" not "what"
   - Use `///` for public API documentation
   - Use `//` for internal logic

   ```zig
   /// Schedules a job for execution at the given timestamp.
   /// Returns an error if the job identifier is already in use.
   pub fn schedule(self: *Scheduler, job: Job) !void {
       // Check if job already exists
       if (self.jobs.get(job.identifier)) |_| {
           return error.DuplicateIdentifier;
       }
       // ...
   }
   ```

2. **Commit Messages**
   - Use conventional commits: `feat:`, `fix:`, `docs:`, `test:`, `refactor:`
   - First line: <= 70 characters
   - Include rationale in body

   ```
   fix: prevent jobs from executing before scheduled time

   Previously, jobs could execute 1 tick early if scheduled
   exactly at the evaluation boundary. This was because the
   comparison used `<=` instead of `<`.

   Fixes #123
   ```

## Before Submitting a PR

- [ ] All tests pass: `zig build test`
- [ ] Code is formatted: `zig fmt . && git diff --check`
- [ ] Commit messages follow convention
- [ ] Documentation updated (if user-facing change)
- [ ] Feature branch is up-to-date with `main`

## Review Process

1. **Automated checks**
   - CI runs tests and formatters
   - All checks must pass before review

2. **Code review**
   - At least one maintainer reviews changes
   - Feedback on architecture, style, correctness
   - Changes requested → update branch, push, request re-review

3. **Merge**
   - Approved changes are merged with squash or rebase
   - Branch is deleted

## Types of Contributions

### Bug Fixes

Start with a failing test:

```zig
test "job should not execute before scheduled time" {
    var scheduler = try Scheduler.init(allocator);
    try scheduler.handle_query(Request{
        .instruction = .{ .set = .{ .identifier = "test", .execution = 1000 } }
    });

    try scheduler.tick(999);  // One tick before

    const job = scheduler.job_storage.get("test");
    try std.testing.expectEqual(JobStatus.planned, job.?.status);
}
```

Then fix the implementation to make the test pass.

### New Features

1. Update domain types if needed
2. Implement application logic
3. Add infrastructure adapters
4. Wire into interfaces
5. Include tests at each layer
6. Update user documentation

### Documentation

- Fix typos and clarify explanations
- Add missing examples
- Update references to match code
- Add architecture notes for future contributors

## Questions?

- Check existing issues and PRs
- Ask in discussions
- Review architecture documentation

## License

By contributing, you agree that your contributions are licensed under the same license as the project.
