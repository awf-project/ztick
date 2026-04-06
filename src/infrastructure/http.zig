pub const json = @import("http/json.zig");

const std = @import("std");
const http = std.http;
const domain = @import("../domain.zig");
const Channel = @import("channel.zig").Channel;
const tcp_server = @import("tcp_server.zig");

const query = domain.query;
const instruction = domain.instruction;
const runner_mod = domain.runner;

const ResponseRouter = tcp_server.ResponseRouter;

const json_content_type: http.Header = .{ .name = "content-type", .value = "application/json" };

pub const HttpServer = struct {
    allocator: std.mem.Allocator,
    address: []const u8,
    running: *std.atomic.Value(bool),
    request_ch: *Channel(query.Request),
    response_router: *ResponseRouter,
    next_client_id: std.atomic.Value(u128),
    bearer_token: ?[]const u8,

    const openapi_spec = @embedFile("openapi.json");

    pub fn init(
        allocator: std.mem.Allocator,
        address: []const u8,
        running: *std.atomic.Value(bool),
        request_ch: *Channel(query.Request),
        response_router: *ResponseRouter,
        bearer_token: ?[]const u8,
    ) HttpServer {
        return .{
            .allocator = allocator,
            .address = address,
            .running = running,
            .request_ch = request_ch,
            .response_router = response_router,
            .next_client_id = std.atomic.Value(u128).init(1_000_000),
            .bearer_token = bearer_token,
        };
    }

    pub fn start(self: *HttpServer) !void {
        const listen_addr = parseAddress(self.address) orelse return;
        var server = listen_addr.listen(.{ .reuse_address = true }) catch return;
        defer server.deinit();

        while (self.running.load(.acquire)) {
            const conn = server.accept() catch |err| switch (err) {
                error.SocketNotListening => return,
                else => continue,
            };
            self.handle_connection(conn.stream);
        }
    }

    fn handle_connection(self: *HttpServer, stream: std.net.Stream) void {
        defer stream.close();

        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var net_reader = stream.reader(&read_buf);
        var net_writer = stream.writer(&write_buf);
        var srv = http.Server.init(net_reader.interface(), &net_writer.interface);

        var request = srv.receiveHead() catch {
            self.send_error_response(&srv, .bad_request, "bad request");
            return;
        };

        // Extract path and query from target
        const target = request.head.target;
        const q_idx = std.mem.indexOfScalar(u8, target, '?');
        const path = if (q_idx) |i| target[0..i] else target;
        const query_str: ?[]const u8 = if (q_idx) |i| target[i + 1 ..] else null;

        // Extract Authorization header
        var authorization: ?[]const u8 = null;
        var header_it = request.iterateHeaders();
        while (header_it.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "authorization")) {
                authorization = header.value;
            }
        }

        // Auth check for protected endpoints
        if (self.bearer_token) |expected_token| {
            if (!isPublicPath(path)) {
                const authorized = if (authorization) |auth|
                    std.mem.startsWith(u8, auth, "Bearer ") and
                        std.mem.eql(u8, auth["Bearer ".len..], expected_token)
                else
                    false;
                if (!authorized) {
                    self.respond_json(&request, .unauthorized, "unauthorized");
                    return;
                }
            }
        }

        // Read body for PUT requests
        var body_buf: [1024 * 1024]u8 = undefined;
        var body: []const u8 = "";

        if (request.head.method == .PUT) {
            const content_length = request.head.content_length orelse {
                self.respond_json(&request, .bad_request, "missing content-length");
                return;
            };
            if (content_length > body_buf.len) {
                self.respond_json(&request, .payload_too_large, "body too large");
                return;
            }
            var body_reader_buf: [4096]u8 = undefined;
            const body_reader = request.readerExpectNone(&body_reader_buf);
            body_reader.readSliceAll(body_buf[0..content_length]) catch {
                self.respond_json(&request, .bad_request, "bad request");
                return;
            };
            body = body_buf[0..content_length];
        }

        self.route(&request, path, query_str, body);
    }

    fn route(self: *HttpServer, request: *http.Server.Request, path: []const u8, query_str: ?[]const u8, body: []const u8) void {
        if (std.mem.eql(u8, path, "/health")) {
            if (request.head.method != .GET) return self.respond_json(request, .method_not_allowed, "method not allowed");
            const resp = json.serialize_health(self.allocator) catch return;
            defer self.allocator.free(resp);
            request.respond(resp, .{ .extra_headers = &.{json_content_type}, .keep_alive = false }) catch return;
            return;
        }

        if (std.mem.eql(u8, path, "/openapi.json")) {
            if (request.head.method != .GET) return self.respond_json(request, .method_not_allowed, "method not allowed");
            request.respond(openapi_spec, .{ .extra_headers = &.{json_content_type}, .keep_alive = false }) catch return;
            return;
        }

        if (std.mem.startsWith(u8, path, "/jobs")) {
            self.route_jobs(request, path, query_str, body);
            return;
        }

        if (std.mem.startsWith(u8, path, "/rules")) {
            self.route_rules(request, path, query_str, body);
            return;
        }

        self.respond_json(request, .not_found, "not found");
    }

    fn route_jobs(self: *HttpServer, request: *http.Server.Request, path: []const u8, query_str: ?[]const u8, body: []const u8) void {
        if (std.mem.eql(u8, path, "/jobs")) {
            if (request.head.method != .GET) return self.respond_json(request, .method_not_allowed, "method not allowed");
            const prefix = if (query_str) |q| extractQueryParam(q, "prefix") orelse "" else "";
            self.handle_list_jobs(request, prefix);
            return;
        }

        const id = extractResourceId(path, "/jobs/") orelse {
            self.respond_json(request, .bad_request, "missing resource id");
            return;
        };

        switch (request.head.method) {
            .PUT => self.handle_put_job(request, id, body),
            .GET => self.handle_get_job(request, id),
            .DELETE => self.handle_delete_job(request, id),
            else => self.respond_json(request, .method_not_allowed, "method not allowed"),
        }
    }

    fn route_rules(self: *HttpServer, request: *http.Server.Request, path: []const u8, query_str: ?[]const u8, body: []const u8) void {
        if (std.mem.eql(u8, path, "/rules")) {
            if (request.head.method != .GET) return self.respond_json(request, .method_not_allowed, "method not allowed");
            const prefix = if (query_str) |q| extractQueryParam(q, "prefix") orelse "" else "";
            self.handle_list_rules(request, prefix);
            return;
        }

        const id = extractResourceId(path, "/rules/") orelse {
            self.respond_json(request, .bad_request, "missing resource id");
            return;
        };

        switch (request.head.method) {
            .PUT => self.handle_put_rule(request, id, body),
            .DELETE => self.handle_delete_rule(request, id),
            else => self.respond_json(request, .not_found, "not found"),
        }
    }

    fn handle_put_job(self: *HttpServer, request: *http.Server.Request, id: []const u8, body: []const u8) void {
        const input = json.parse_job_body(self.allocator, body) catch {
            self.respond_json(request, .bad_request, "invalid json");
            return;
        };

        const owned_id = self.allocator.dupe(u8, id) catch return;
        const response = self.send_query(.{ .set = .{ .identifier = owned_id, .execution = input.execution } }) orelse {
            self.allocator.free(owned_id);
            return;
        };
        _ = response;

        const resp_body = json.serialize_job(self.allocator, id, "planned", input.execution) catch return;
        defer self.allocator.free(resp_body);
        request.respond(resp_body, .{ .extra_headers = &.{json_content_type}, .keep_alive = false }) catch return;
    }

    fn handle_get_job(self: *HttpServer, request: *http.Server.Request, id: []const u8) void {
        const owned_id = self.allocator.dupe(u8, id) catch return;
        const response = self.send_query(.{ .get = .{ .identifier = owned_id } }) orelse {
            self.allocator.free(owned_id);
            return;
        };
        self.allocator.free(owned_id);

        if (!response.success) {
            self.respond_json(request, .not_found, "not found");
            return;
        }

        if (response.body) |resp_body| {
            defer self.allocator.free(resp_body);
            var parts = std.mem.splitScalar(u8, resp_body, ' ');
            const status = parts.next() orelse "unknown";
            const exec_str = parts.next() orelse "0";
            const exec_ns = std.fmt.parseInt(i64, exec_str, 10) catch 0;
            const body = json.serialize_job(self.allocator, id, status, exec_ns) catch return;
            defer self.allocator.free(body);
            request.respond(body, .{ .extra_headers = &.{json_content_type}, .keep_alive = false }) catch return;
        } else {
            self.respond_json(request, .not_found, "not found");
        }
    }

    fn handle_delete_job(self: *HttpServer, request: *http.Server.Request, id: []const u8) void {
        const owned_id = self.allocator.dupe(u8, id) catch return;
        const response = self.send_query(.{ .remove = .{ .identifier = owned_id } }) orelse {
            self.allocator.free(owned_id);
            return;
        };
        self.allocator.free(owned_id);

        if (response.success) {
            request.respond("", .{ .status = .no_content, .keep_alive = false }) catch return;
        } else {
            self.respond_json(request, .not_found, "not found");
        }
    }

    fn handle_list_jobs(self: *HttpServer, request: *http.Server.Request, prefix: []const u8) void {
        const owned_prefix = self.allocator.dupe(u8, prefix) catch return;
        const response = self.send_query(.{ .query = .{ .pattern = owned_prefix } }) orelse {
            self.allocator.free(owned_prefix);
            return;
        };
        self.allocator.free(owned_prefix);

        if (response.body) |resp_body| {
            defer self.allocator.free(resp_body);
            var jobs = std.ArrayListUnmanaged(json.JobEntry){};
            defer jobs.deinit(self.allocator);

            var lines = std.mem.splitScalar(u8, resp_body, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                var parts = std.mem.splitScalar(u8, line, ' ');
                const id = parts.next() orelse continue;
                const status = parts.next() orelse continue;
                const exec_str = parts.next() orelse continue;
                const exec_ns = std.fmt.parseInt(i64, exec_str, 10) catch continue;
                jobs.append(self.allocator, .{ .id = id, .status = status, .execution = exec_ns }) catch continue;
            }

            const body = json.serialize_jobs_array(self.allocator, jobs.items) catch return;
            defer self.allocator.free(body);
            request.respond(body, .{ .extra_headers = &.{json_content_type}, .keep_alive = false }) catch return;
        } else {
            request.respond("[]", .{ .extra_headers = &.{json_content_type}, .keep_alive = false }) catch return;
        }
    }

    fn handle_put_rule(self: *HttpServer, request: *http.Server.Request, id: []const u8, body: []const u8) void {
        const input = json.parse_rule_body(self.allocator, body) catch {
            self.respond_json(request, .bad_request, "invalid json");
            return;
        };

        const is_shell = std.mem.eql(u8, input.runner, "shell");
        const is_direct = std.mem.eql(u8, input.runner, "direct");
        const is_awf = std.mem.eql(u8, input.runner, "awf");

        if (!is_shell and !is_direct and !is_awf) {
            self.allocator.free(input.pattern);
            self.allocator.free(input.runner);
            for (input.args) |arg| self.allocator.free(arg);
            self.allocator.free(input.args);
            self.respond_json(request, .bad_request, "unsupported runner type");
            return;
        }

        const owned_id = self.allocator.dupe(u8, id) catch {
            self.allocator.free(input.pattern);
            self.allocator.free(input.runner);
            for (input.args) |arg| self.allocator.free(arg);
            self.allocator.free(input.args);
            return;
        };

        const runner_type: runner_mod.Runner = if (is_shell)
            .{ .shell = .{ .command = if (input.args.len > 0) input.args[0] else "" } }
        else if (is_direct)
            .{ .direct = .{ .executable = if (input.args.len > 0) input.args[0] else "", .args = if (input.args.len > 1) input.args[1..] else &.{} } }
        else
            build_awf_runner(self.allocator, input.args) orelse {
                self.allocator.free(owned_id);
                self.allocator.free(input.pattern);
                self.allocator.free(input.runner);
                for (input.args) |arg| self.allocator.free(arg);
                self.allocator.free(input.args);
                self.respond_json(request, .bad_request, "missing workflow argument");
                return;
            };

        const resp_body = json.serialize_rule(self.allocator, id, input.pattern, input.runner) catch {
            self.allocator.free(owned_id);
            self.allocator.free(input.pattern);
            self.allocator.free(input.runner);
            for (input.args) |arg| self.allocator.free(arg);
            self.allocator.free(input.args);
            return;
        };
        defer self.allocator.free(resp_body);

        const response = self.send_query(.{ .rule_set = .{
            .identifier = owned_id,
            .pattern = input.pattern,
            .runner = runner_type,
        } }) orelse {
            self.allocator.free(owned_id);
            self.allocator.free(input.pattern);
            self.allocator.free(input.runner);
            for (input.args) |arg| self.allocator.free(arg);
            self.allocator.free(input.args);
            return;
        };
        _ = response;

        if (is_awf) {
            const awf = runner_type.awf;
            for (input.args) |arg| {
                var consumed = arg.ptr == awf.workflow.ptr;
                if (!consumed) {
                    for (awf.inputs) |inp| {
                        if (arg.ptr == inp.ptr) {
                            consumed = true;
                            break;
                        }
                    }
                }
                if (!consumed) self.allocator.free(arg);
            }
        }
        self.allocator.free(input.runner);
        self.allocator.free(input.args);

        request.respond(resp_body, .{ .extra_headers = &.{json_content_type}, .keep_alive = false }) catch return;
    }

    fn handle_delete_rule(self: *HttpServer, request: *http.Server.Request, id: []const u8) void {
        const owned_id = self.allocator.dupe(u8, id) catch return;
        const response = self.send_query(.{ .remove_rule = .{ .identifier = owned_id } }) orelse {
            self.allocator.free(owned_id);
            return;
        };
        self.allocator.free(owned_id);

        if (response.success) {
            request.respond("", .{ .status = .no_content, .keep_alive = false }) catch return;
        } else {
            self.respond_json(request, .not_found, "not found");
        }
    }

    fn handle_list_rules(self: *HttpServer, request: *http.Server.Request, prefix: []const u8) void {
        const response = self.send_query(.{ .list_rules = .{} }) orelse return;

        if (response.body) |resp_body| {
            defer self.allocator.free(resp_body);
            var rules = std.ArrayListUnmanaged(json.RuleEntry){};
            defer rules.deinit(self.allocator);

            var lines = std.mem.splitScalar(u8, resp_body, '\n');
            while (lines.next()) |line| {
                if (line.len == 0) continue;
                var parts = std.mem.splitScalar(u8, line, ' ');
                const id = parts.next() orelse continue;
                const pattern = parts.next() orelse continue;
                const runner_type = parts.next() orelse continue;
                if (prefix.len > 0 and !std.mem.startsWith(u8, id, prefix)) continue;
                rules.append(self.allocator, .{ .id = id, .pattern = pattern, .runner = runner_type }) catch continue;
            }

            const body = json.serialize_rules_array(self.allocator, rules.items) catch return;
            defer self.allocator.free(body);
            request.respond(body, .{ .extra_headers = &.{json_content_type}, .keep_alive = false }) catch return;
        } else {
            request.respond("[]", .{ .extra_headers = &.{json_content_type}, .keep_alive = false }) catch return;
        }
    }

    fn respond_json(self: *HttpServer, request: *http.Server.Request, status: http.Status, message: []const u8) void {
        const body = json.serialize_error(self.allocator, message) catch return;
        defer self.allocator.free(body);
        request.respond(body, .{ .status = status, .extra_headers = &.{json_content_type}, .keep_alive = false }) catch return;
    }

    fn send_error_response(self: *HttpServer, srv: *http.Server, status: http.Status, message: []const u8) void {
        const body = json.serialize_error(self.allocator, message) catch return;
        defer self.allocator.free(body);
        const phrase = status.phrase() orelse "";
        srv.out.print("{s} {d} {s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{
            @tagName(http.Version.@"HTTP/1.1"), @intFromEnum(status), phrase, body.len,
        }) catch return;
        srv.out.writeAll(body) catch return;
        srv.out.flush() catch return;
    }

    fn send_query(self: *HttpServer, instr: instruction.Instruction) ?query.Response {
        const client_id = self.next_client_id.fetchAdd(1, .monotonic);

        var resp_ch = Channel(query.Response).init(self.allocator, 1) catch return null;
        defer resp_ch.deinit();

        self.response_router.register(client_id, &resp_ch);
        defer self.response_router.deregister(client_id);

        self.request_ch.send(.{
            .client = client_id,
            .identifier = "http",
            .instruction = instr,
        }) catch return null;

        return resp_ch.receive();
    }
};

fn extractResourceId(path: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    const id = path[prefix.len..];
    if (id.len == 0) return null;
    return id;
}

fn extractQueryParam(query_str: []const u8, key: []const u8) ?[]const u8 {
    var pairs = std.mem.splitScalar(u8, query_str, '&');
    while (pairs.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) {
            return pair[eq + 1 ..];
        }
    }
    return null;
}

fn isPublicPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/openapi.json");
}

fn parseAddress(address: []const u8) ?std.net.Address {
    const colon = std.mem.lastIndexOfScalar(u8, address, ':') orelse return null;
    const host = address[0..colon];
    const port = std.fmt.parseUnsigned(u16, address[colon + 1 ..], 10) catch return null;
    return std.net.Address.parseIp(host, port) catch return null;
}

fn build_awf_runner(allocator: std.mem.Allocator, args: []const []const u8) ?runner_mod.Runner {
    if (args.len == 0) return null;
    const workflow = args[0];
    const remaining = args[1..];
    // Remaining args must be pairs of "--input" + value
    if (remaining.len % 2 != 0) return null;
    var k: usize = 0;
    while (k < remaining.len) : (k += 2) {
        if (!std.mem.eql(u8, remaining[k], "--input")) return null;
    }
    const input_count = remaining.len / 2;
    const inputs = allocator.alloc([]const u8, input_count) catch return null;
    var j: usize = 0;
    while (j < input_count) : (j += 1) {
        inputs[j] = remaining[j * 2 + 1];
    }
    return .{ .awf = .{ .workflow = workflow, .inputs = inputs } };
}

// Tests

test "json namespace exposes serialize_health returning correct response" {
    const allocator = std.testing.allocator;
    const result = try json.serialize_health(allocator);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{\"status\":\"ok\"}", result);
}

test "json namespace exposes serialize_error returning correct response" {
    const allocator = std.testing.allocator;
    const result = try json.serialize_error(allocator, "not found");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("{\"error\":\"not found\"}", result);
}

test "extractResourceId returns id after prefix" {
    try std.testing.expectEqualStrings("deploy.v1", extractResourceId("/jobs/deploy.v1", "/jobs/").?);
}

test "extractResourceId returns null for path without id" {
    try std.testing.expectEqual(@as(?[]const u8, null), extractResourceId("/jobs/", "/jobs/"));
}

test "extractResourceId returns null for non-matching prefix" {
    try std.testing.expectEqual(@as(?[]const u8, null), extractResourceId("/rules/foo", "/jobs/"));
}

test "extractQueryParam returns value for matching key" {
    try std.testing.expectEqualStrings("deploy.", extractQueryParam("prefix=deploy.", "prefix").?);
}

test "extractQueryParam returns null for missing key" {
    try std.testing.expectEqual(@as(?[]const u8, null), extractQueryParam("other=value", "prefix"));
}

test "isPublicPath returns true for health" {
    try std.testing.expect(isPublicPath("/health"));
}

test "isPublicPath returns true for openapi" {
    try std.testing.expect(isPublicPath("/openapi.json"));
}

test "isPublicPath returns false for jobs" {
    try std.testing.expect(!isPublicPath("/jobs"));
}

test "parseAddress parses ip and port" {
    const addr = parseAddress("127.0.0.1:5680");
    try std.testing.expect(addr != null);
    try std.testing.expectEqual(@as(u16, 5680), addr.?.getPort());
}

test "parseAddress returns null for invalid input" {
    try std.testing.expect(parseAddress("invalid") == null);
}

test "build_awf_runner returns runner with workflow and no inputs from single arg" {
    const args = [_][]const u8{"code-review"};
    const runner = build_awf_runner(std.testing.allocator, &args);
    try std.testing.expect(runner != null);
    defer std.testing.allocator.free(runner.?.awf.inputs);
    try std.testing.expectEqualStrings("code-review", runner.?.awf.workflow);
    try std.testing.expectEqual(@as(usize, 0), runner.?.awf.inputs.len);
}

test "build_awf_runner extracts input values from multiple --input flags" {
    const args = [_][]const u8{ "generate-report", "--input", "format=pdf", "--input", "target=main" };
    const runner = build_awf_runner(std.testing.allocator, &args);
    try std.testing.expect(runner != null);
    defer std.testing.allocator.free(runner.?.awf.inputs);
    try std.testing.expectEqualStrings("generate-report", runner.?.awf.workflow);
    try std.testing.expectEqual(@as(usize, 2), runner.?.awf.inputs.len);
    try std.testing.expectEqualStrings("format=pdf", runner.?.awf.inputs[0]);
    try std.testing.expectEqualStrings("target=main", runner.?.awf.inputs[1]);
}

test "build_awf_runner returns null when args is empty" {
    const args = [_][]const u8{};
    const runner = build_awf_runner(std.testing.allocator, &args);
    try std.testing.expectEqual(@as(?runner_mod.Runner, null), runner);
}
