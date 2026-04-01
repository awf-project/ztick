const std = @import("std");
const domain = @import("../domain.zig");

const Token = domain.auth.Token;

pub const AuthParseError = error{
    MissingSecret,
    EmptyNamespace,
    DuplicateSecret,
};

fn unquote(s: []const u8) []const u8 {
    if (s.len >= 2 and s[0] == '"' and s[s.len - 1] == '"') {
        return s[1 .. s.len - 1];
    }
    return s;
}

fn flush_token(
    allocator: std.mem.Allocator,
    tokens: *std.ArrayListUnmanaged(Token),
    name: []u8,
    secret: ?[]u8,
    namespace: ?[]u8,
) (AuthParseError || std.mem.Allocator.Error)!void {
    const sec = secret orelse {
        allocator.free(name);
        if (namespace) |ns| allocator.free(ns);
        return AuthParseError.MissingSecret;
    };
    const ns = namespace orelse {
        allocator.free(name);
        allocator.free(sec);
        return AuthParseError.EmptyNamespace;
    };
    if (ns.len == 0) {
        allocator.free(name);
        allocator.free(sec);
        allocator.free(ns);
        return AuthParseError.EmptyNamespace;
    }
    for (tokens.items) |existing| {
        if (std.mem.eql(u8, existing.secret, sec)) {
            allocator.free(name);
            allocator.free(sec);
            allocator.free(ns);
            return AuthParseError.DuplicateSecret;
        }
    }
    try tokens.append(allocator, Token{ .name = name, .secret = sec, .namespace = ns });
}

pub fn parse(allocator: std.mem.Allocator, content: []const u8) (AuthParseError || std.mem.Allocator.Error)![]Token {
    var tokens = std.ArrayListUnmanaged(Token){};
    errdefer {
        for (tokens.items) |t| {
            allocator.free(t.name);
            allocator.free(t.secret);
            allocator.free(t.namespace);
        }
        tokens.deinit(allocator);
    }

    var cur_name: ?[]u8 = null;
    var cur_secret: ?[]u8 = null;
    var cur_namespace: ?[]u8 = null;
    errdefer {
        if (cur_name) |n| allocator.free(n);
        if (cur_secret) |s| allocator.free(s);
        if (cur_namespace) |ns| allocator.free(ns);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        if (line[0] == '[') {
            if (cur_name) |name| {
                cur_name = null;
                const sec = cur_secret;
                cur_secret = null;
                const ns = cur_namespace;
                cur_namespace = null;
                try flush_token(allocator, &tokens, name, sec, ns);
            }

            const end = std.mem.indexOfScalar(u8, line, ']') orelse continue;
            const section = std.mem.trim(u8, line[1..end], " \t");
            if (std.mem.startsWith(u8, section, "token.")) {
                const token_name = section["token.".len..];
                if (token_name.len > 0) {
                    cur_name = try allocator.dupe(u8, token_name);
                }
            }
            continue;
        }

        if (cur_name == null) continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = unquote(std.mem.trim(u8, line[eq + 1 ..], " \t"));

        if (std.mem.eql(u8, key, "secret")) {
            if (cur_secret) |prev| allocator.free(prev);
            cur_secret = try allocator.dupe(u8, val);
        } else if (std.mem.eql(u8, key, "namespace")) {
            if (cur_namespace) |prev| allocator.free(prev);
            cur_namespace = try allocator.dupe(u8, val);
        }
    }

    if (cur_name) |name| {
        cur_name = null;
        const sec = cur_secret;
        cur_secret = null;
        const ns = cur_namespace;
        cur_namespace = null;
        try flush_token(allocator, &tokens, name, sec, ns);
    }

    return tokens.toOwnedSlice(allocator);
}

pub fn load(allocator: std.mem.Allocator, path: []const u8) ![]Token {
    const file = std.fs.cwd().openFile(path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return err,
    };
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(content);
    return parse(allocator, content);
}

test "parse returns empty slice for content with no token sections" {
    const tokens = try parse(std.testing.allocator, "");
    defer std.testing.allocator.free(tokens);
    try std.testing.expectEqual(@as(usize, 0), tokens.len);
}

test "parse valid auth file with two token sections" {
    const content =
        \\[token.deploy]
        \\secret = "sk_deploy_a1b2c3"
        \\namespace = "deploy."
        \\[token.backup]
        \\secret = "sk_backup_d4e5f6"
        \\namespace = "backup."
    ;
    const tokens = try parse(std.testing.allocator, content);
    defer {
        for (tokens) |t| {
            std.testing.allocator.free(t.name);
            std.testing.allocator.free(t.secret);
            std.testing.allocator.free(t.namespace);
        }
        std.testing.allocator.free(tokens);
    }
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
}

test "parse rejects missing secret key in token section" {
    const content =
        \\[token.deploy]
        \\namespace = "deploy."
    ;
    try std.testing.expectError(AuthParseError.MissingSecret, parse(std.testing.allocator, content));
}

test "parse rejects duplicate secrets across sections" {
    const content =
        \\[token.deploy]
        \\secret = "sk_shared"
        \\namespace = "deploy."
        \\[token.backup]
        \\secret = "sk_shared"
        \\namespace = "backup."
    ;
    try std.testing.expectError(AuthParseError.DuplicateSecret, parse(std.testing.allocator, content));
}

test "parse rejects empty namespace value" {
    const content =
        \\[token.deploy]
        \\secret = "sk_deploy_a1b2c3"
        \\namespace = ""
    ;
    try std.testing.expectError(AuthParseError.EmptyNamespace, parse(std.testing.allocator, content));
}

test "parse handles wildcard namespace correctly" {
    const content =
        \\[token.admin]
        \\secret = "sk_admin_a1b2c3"
        \\namespace = "*"
    ;
    const tokens = try parse(std.testing.allocator, content);
    defer {
        for (tokens) |t| {
            std.testing.allocator.free(t.name);
            std.testing.allocator.free(t.secret);
            std.testing.allocator.free(t.namespace);
        }
        std.testing.allocator.free(tokens);
    }
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
}

test "parse valid auth file returns correct token fields" {
    const content =
        \\[token.deploy]
        \\secret = "sk_deploy_a1b2c3"
        \\namespace = "deploy."
    ;
    const tokens = try parse(std.testing.allocator, content);
    defer {
        for (tokens) |t| {
            std.testing.allocator.free(t.name);
            std.testing.allocator.free(t.secret);
            std.testing.allocator.free(t.namespace);
        }
        std.testing.allocator.free(tokens);
    }
    try std.testing.expectEqual(@as(usize, 1), tokens.len);
    try std.testing.expectEqualStrings("deploy", tokens[0].name);
    try std.testing.expectEqualStrings("sk_deploy_a1b2c3", tokens[0].secret);
    try std.testing.expectEqualStrings("deploy.", tokens[0].namespace);
}

test "load returns error for nonexistent file path" {
    try std.testing.expectError(error.FileNotFound, load(std.testing.allocator, "/nonexistent/auth.toml"));
}
