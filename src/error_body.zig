//! Smart parsing of provider error bodies.
//!
//! OpenAI:        {"error":{"message":"...","type":"...","code":"..."}}
//! Anthropic:     {"type":"error","error":{"type":"...","message":"..."}}
//! llama-server:  {"error":{"message":"...","type":"...","code":4xx}}  (sometimes plain text)
//!
//! `extractMessage` returns the cleanest human-readable string we can pull from
//! the body. Falls back to a truncated copy of the raw body when the shape is
//! unknown or JSON parsing fails. The returned string is arena-allocated.
const std = @import("std");

const max_raw_len: usize = 500;

/// Extract a human-readable message from a provider error body. Caller owns
/// the returned slice (arena-allocated). Always non-null; on total failure
/// returns a truncated copy of the input.
pub fn extractMessage(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) return try arena.dupe(u8, "(empty response body)");

    // Only attempt JSON if it looks like one. Cheap guard avoids parser noise
    // on plain text or HTML error pages from misconfigured proxies.
    if (trimmed[0] == '{' or trimmed[0] == '[') {
        if (tryJson(arena, trimmed)) |msg| return msg else |_| {}
    }

    return try truncate(arena, trimmed);
}

fn tryJson(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    defer parsed.deinit();
    return try fromValue(arena, parsed.value);
}

fn fromValue(arena: std.mem.Allocator, root: std.json.Value) ![]const u8 {
    const root_obj = switch (root) {
        .object => |o| o,
        else => return error.NotObject,
    };

    // Both OpenAI and Anthropic nest under `error`.
    const err_field = root_obj.get("error") orelse {
        // Some servers return {"message":"..."} or {"detail":"..."} flat.
        if (asString(root_obj.get("message"))) |m| return try arena.dupe(u8, m);
        if (asString(root_obj.get("detail"))) |m| return try arena.dupe(u8, m);
        return error.NoErrorField;
    };

    const msg = blk: switch (err_field) {
        .string => |s| break :blk s,
        .object => |eo| {
            const inner = asString(eo.get("message")) orelse return error.NoMessage;
            const code = asString(eo.get("code"));
            const etype = asString(eo.get("type"));
            // Format: "<message> [<code-or-type>]"
            const tag: ?[]const u8 = code orelse etype;
            if (tag) |t| {
                if (!std.mem.eql(u8, t, "error")) {
                    return try std.fmt.allocPrint(arena, "{s} [{s}]", .{ inner, t });
                }
            }
            break :blk inner;
        },
        else => return error.UnexpectedShape,
    };
    return try arena.dupe(u8, msg);
}

fn asString(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn truncate(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    if (body.len <= max_raw_len) return try arena.dupe(u8, body);
    return try std.fmt.allocPrint(arena, "{s}… (truncated, {d} bytes total)", .{ body[0..max_raw_len], body.len });
}

const testing = std.testing;

test "openai: nested error object with code" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body =
        \\{"error":{"message":"Invalid API key","type":"invalid_request_error","code":"invalid_api_key"}}
    ;
    const got = try extractMessage(arena.allocator(), body);
    try testing.expectEqualStrings("Invalid API key [invalid_api_key]", got);
}

test "openai: error object without code falls back to type" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body =
        \\{"error":{"message":"Rate limited","type":"rate_limit_error"}}
    ;
    const got = try extractMessage(arena.allocator(), body);
    try testing.expectEqualStrings("Rate limited [rate_limit_error]", got);
}

test "anthropic: top-level type=error wrapper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body =
        \\{"type":"error","error":{"type":"invalid_request_error","message":"max_tokens is required"}}
    ;
    const got = try extractMessage(arena.allocator(), body);
    try testing.expectEqualStrings("max_tokens is required [invalid_request_error]", got);
}

test "flat: {message: ...}" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "{\"message\":\"server overloaded\"}";
    const got = try extractMessage(arena.allocator(), body);
    try testing.expectEqualStrings("server overloaded", got);
}

test "flat: {detail: ...} (FastAPI style)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const body = "{\"detail\":\"Not Found\"}";
    const got = try extractMessage(arena.allocator(), body);
    try testing.expectEqualStrings("Not Found", got);
}

test "plain text body passes through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try extractMessage(arena.allocator(), "service unavailable");
    try testing.expectEqualStrings("service unavailable", got);
}

test "empty body" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try extractMessage(arena.allocator(), "");
    try testing.expectEqualStrings("(empty response body)", got);
}

test "malformed JSON falls back to truncated raw" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const got = try extractMessage(arena.allocator(), "{not valid json");
    try testing.expectEqualStrings("{not valid json", got);
}

test "long body truncated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const long = "a" ** 600;
    const got = try extractMessage(arena.allocator(), long);
    try testing.expect(got.len < long.len);
    try testing.expect(std.mem.indexOf(u8, got, "truncated") != null);
}
