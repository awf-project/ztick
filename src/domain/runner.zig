pub const Runner = union(enum) {
    shell: struct {
        command: []const u8,
    },
    amqp: struct {
        dsn: []const u8,
        exchange: []const u8,
        routing_key: []const u8,
    },
};
