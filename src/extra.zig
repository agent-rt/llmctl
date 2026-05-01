//! `--extra k=v` parser. Per TECH-DESIGN §18.
const std = @import("std");

/// Parse a `key=value` string. Inferred value types:
///   "true"/"false" → bool
///   integer        → integer
///   float          → float
///   else           → string (no JSON parsing — use --extra-json for that)
pub fn parseKv(arena: std.mem.Allocator, kv: []const u8) !struct { key: []const u8, value: std.json.Value } {
    const eq = std.mem.indexOfScalar(u8, kv, '=') orelse return error.MissingEquals;
    const k = kv[0..eq];
    const v_raw = kv[eq + 1 ..];
    if (k.len == 0) return error.EmptyKey;

    const value: std.json.Value = blk: {
        if (std.mem.eql(u8, v_raw, "true")) break :blk .{ .bool = true };
        if (std.mem.eql(u8, v_raw, "false")) break :blk .{ .bool = false };
        if (std.mem.eql(u8, v_raw, "null")) break :blk .null;
        if (std.fmt.parseInt(i64, v_raw, 10)) |i| {
            break :blk .{ .integer = i };
        } else |_| {}
        if (std.fmt.parseFloat(f64, v_raw)) |f| {
            break :blk .{ .float = f };
        } else |_| {}
        break :blk .{ .string = try arena.dupe(u8, v_raw) };
    };

    return .{ .key = try arena.dupe(u8, k), .value = value };
}

/// Parse a JSON object string and merge entries into `out`.
pub fn mergeJsonObject(
    arena: std.mem.Allocator,
    json_str: []const u8,
    out: *std.StringHashMapUnmanaged(std.json.Value),
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json_str, .{});
    // parsed lifetime is bound to arena; values are arena-owned.
    if (parsed.value != .object) return error.NotAnObject;
    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        try out.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    }
}

const testing = std.testing;

test "parseKv: bool" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseKv(arena.allocator(), "cache_prompt=true");
    try testing.expectEqualStrings("cache_prompt", r.key);
    try testing.expect(r.value == .bool);
    try testing.expect(r.value.bool == true);
}

test "parseKv: integer" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseKv(arena.allocator(), "seed=42");
    try testing.expect(r.value == .integer);
    try testing.expectEqual(@as(i64, 42), r.value.integer);
}

test "parseKv: float" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseKv(arena.allocator(), "temp=0.7");
    try testing.expect(r.value == .float);
}

test "parseKv: string fallback" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const r = try parseKv(arena.allocator(), "name=hello");
    try testing.expect(r.value == .string);
    try testing.expectEqualStrings("hello", r.value.string);
}

test "parseKv: missing equals errors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.MissingEquals, parseKv(arena.allocator(), "noeq"));
}
