const std = @import("std");

const c = @cImport({
    @cInclude("openssl/ssl.h");
    @cInclude("openssl/err.h");
});

pub const TlsError = error{
    ContextInitFailed,
    CertificateLoadFailed,
    PrivateKeyLoadFailed,
    HandshakeFailed,
};

pub const TlsStream = struct {
    ssl: *c.SSL,
    fd: std.posix.fd_t,

    pub fn read(self: TlsStream, buf: []u8) !usize {
        const n = c.SSL_read(self.ssl, @ptrCast(buf.ptr), @intCast(buf.len));
        if (n > 0) return @intCast(n);
        const ssl_err = c.SSL_get_error(self.ssl, n);
        if (ssl_err == c.SSL_ERROR_ZERO_RETURN) return 0;
        return error.ConnectionResetByPeer;
    }

    pub fn write(self: TlsStream, buf: []const u8) !usize {
        const n = c.SSL_write(self.ssl, @ptrCast(buf.ptr), @intCast(buf.len));
        if (n > 0) return @intCast(n);
        return error.BrokenPipe;
    }

    pub fn close(self: TlsStream) void {
        _ = c.SSL_shutdown(self.ssl);
        c.SSL_free(self.ssl);
        std.posix.close(self.fd);
    }
};

pub const TlsContext = struct {
    ssl_ctx: *c.SSL_CTX,

    pub fn create(cert_path: []const u8, key_path: []const u8) TlsError!TlsContext {
        const method = c.TLS_server_method() orelse return TlsError.ContextInitFailed;
        const ssl_ctx = c.SSL_CTX_new(method) orelse return TlsError.ContextInitFailed;
        errdefer c.SSL_CTX_free(ssl_ctx);

        if (c.SSL_CTX_set_min_proto_version(ssl_ctx, c.TLS1_3_VERSION) != 1) return TlsError.ContextInitFailed;

        var cert_buf: [4096]u8 = undefined;
        const cert_cstr = try slice_to_c_path(&cert_buf, cert_path, TlsError.CertificateLoadFailed);

        var key_buf: [4096]u8 = undefined;
        const key_cstr = try slice_to_c_path(&key_buf, key_path, TlsError.PrivateKeyLoadFailed);

        if (c.SSL_CTX_use_certificate_file(ssl_ctx, cert_cstr, c.SSL_FILETYPE_PEM) != 1) {
            return TlsError.CertificateLoadFailed;
        }

        if (c.SSL_CTX_use_PrivateKey_file(ssl_ctx, key_cstr, c.SSL_FILETYPE_PEM) != 1) {
            return TlsError.PrivateKeyLoadFailed;
        }

        if (c.SSL_CTX_check_private_key(ssl_ctx) != 1) {
            return TlsError.PrivateKeyLoadFailed;
        }

        return TlsContext{ .ssl_ctx = ssl_ctx };
    }

    pub fn accept(self: *TlsContext, fd: std.posix.fd_t) TlsError!TlsStream {
        const ssl = c.SSL_new(self.ssl_ctx) orelse return TlsError.HandshakeFailed;
        errdefer c.SSL_free(ssl);
        if (c.SSL_set_fd(ssl, @intCast(fd)) != 1) return TlsError.HandshakeFailed;
        if (c.SSL_accept(ssl) != 1) return TlsError.HandshakeFailed;
        return TlsStream{ .ssl = ssl, .fd = fd };
    }

    pub fn deinit(self: *TlsContext) void {
        c.SSL_CTX_free(self.ssl_ctx);
    }

    fn slice_to_c_path(buf: *[4096]u8, path: []const u8, comptime err: TlsError) TlsError![*c]const u8 {
        if (path.len >= buf.len) return err;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        return @ptrCast(buf);
    }
};

test "create returns context when cert and key paths are valid PEM files" {
    var ctx = try TlsContext.create("test/fixtures/tls/cert.pem", "test/fixtures/tls/key.pem");
    ctx.deinit();
}

test "create returns CertificateLoadFailed when cert path does not exist" {
    const result = TlsContext.create("/nonexistent/cert.pem", "/nonexistent/key.pem");
    try std.testing.expectError(TlsError.CertificateLoadFailed, result);
}

test "create returns CertificateLoadFailed when PEM content is invalid" {
    const tmp_cert = "/tmp/ztick_test_invalid_cert.pem";
    const tmp_key = "/tmp/ztick_test_invalid_key.pem";
    const cert_file = try std.fs.cwd().createFile(tmp_cert, .{});
    defer std.fs.cwd().deleteFile(tmp_cert) catch {};
    try cert_file.writeAll("not a valid pem certificate");
    cert_file.close();
    const key_file = try std.fs.cwd().createFile(tmp_key, .{});
    defer std.fs.cwd().deleteFile(tmp_key) catch {};
    try key_file.writeAll("not a valid pem key");
    key_file.close();

    const result = TlsContext.create(tmp_cert, tmp_key);
    try std.testing.expectError(TlsError.CertificateLoadFailed, result);
}
