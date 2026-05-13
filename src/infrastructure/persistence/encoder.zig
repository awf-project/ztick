/// Thin re-export of application/persistence_codec.zig.
/// The Entry type and encode/decode functions live in the application layer
/// because they depend only on domain types. Infrastructure code (background.zig,
/// backend tests) imports through this shim for backward compatibility.
const codec = @import("../../application/persistence_codec.zig");

pub const Entry = codec.Entry;
pub const DecodeError = codec.DecodeError;
pub const encode = codec.encode;
pub const decode = codec.decode;
pub const free_entry_fields = codec.free_entry_fields;
