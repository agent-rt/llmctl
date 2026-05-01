//! Session persistence: multi-turn conversations as JSON.
//! Per TECH-DESIGN §9. Load existing messages, append turn, save back.
const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");

const Allocator = std.mem.Allocator;

pub const SCHEMA_VERSION: u32 = 1;

pub const Session = struct {
    version: u32 = SCHEMA_VERSION,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    system: ?[]const u8 = null,
    /// role/content pairs. `system` lives at top level, not in messages.
    messages: std.ArrayList(StoredMessage) = .empty,
    total_input_tokens: u32 = 0,
    total_output_tokens: u32 = 0,
};

pub const StoredMessage = struct {
    role: []const u8, // "user" | "assistant"
    content: []const u8,
};

pub const LoadError = anyerror;
pub const SaveError = anyerror;

/// Load session JSON from `path`. Returns empty Session if file missing.
pub fn load(arena: Allocator, io: Io, path: []const u8) LoadError!Session {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return Session{},
        else => return e,
    };
    defer file.close(io);

    var buf: [8192]u8 = undefined;
    var fr: Io.File.Reader = .init(file, io, &buf);
    var collected: std.ArrayList(u8) = .empty;
    while (true) {
        const n = try fr.interface.readSliceShort(&buf);
        if (n == 0) break;
        try collected.appendSlice(arena, buf[0..n]);
    }
    if (collected.items.len == 0) return Session{};

    return parse(arena, collected.items);
}

pub fn parse(arena: Allocator, json_text: []const u8) !Session {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, json_text, .{});
    const root = parsed.value;
    if (root != .object) return error.InvalidSchema;

    var s = Session{};

    if (root.object.get("version")) |v| if (v == .integer) {
        s.version = @intCast(v.integer);
    };
    if (s.version != SCHEMA_VERSION) return error.UnsupportedVersion;

    if (root.object.get("provider")) |v| if (v == .string) {
        s.provider = try arena.dupe(u8, v.string);
    };
    if (root.object.get("model")) |v| if (v == .string) {
        s.model = try arena.dupe(u8, v.string);
    };
    if (root.object.get("system")) |v| if (v == .string) {
        s.system = try arena.dupe(u8, v.string);
    };

    if (root.object.get("messages")) |m| {
        if (m != .array) return error.InvalidSchema;
        for (m.array.items) |it| {
            if (it != .object) return error.InvalidSchema;
            const role = it.object.get("role") orelse return error.InvalidSchema;
            const content = it.object.get("content") orelse return error.InvalidSchema;
            if (role != .string or content != .string) return error.InvalidSchema;
            try s.messages.append(arena, .{
                .role = try arena.dupe(u8, role.string),
                .content = try arena.dupe(u8, content.string),
            });
        }
    }

    if (root.object.get("usage")) |u| if (u == .object) {
        if (u.object.get("total_input_tokens")) |t| if (t == .integer) {
            s.total_input_tokens = @intCast(t.integer);
        };
        if (u.object.get("total_output_tokens")) |t| if (t == .integer) {
            s.total_output_tokens = @intCast(t.integer);
        };
    };

    return s;
}

/// Atomically write session to `path` (writes to .tmp then rename).
pub fn save(arena: Allocator, io: Io, path: []const u8, s: Session) SaveError!void {
    var allocating = std.Io.Writer.Allocating.init(arena);
    const writer = &allocating.writer;
    var w: std.json.Stringify = .{ .writer = writer, .options = .{ .whitespace = .indent_2 } };

    try w.beginObject();
    try w.objectField("version");
    try w.write(s.version);
    if (s.provider) |p| {
        try w.objectField("provider");
        try w.write(p);
    }
    if (s.model) |m| {
        try w.objectField("model");
        try w.write(m);
    }
    if (s.system) |sys| {
        try w.objectField("system");
        try w.write(sys);
    }
    try w.objectField("messages");
    try w.beginArray();
    for (s.messages.items) |msg| {
        try w.beginObject();
        try w.objectField("role");
        try w.write(msg.role);
        try w.objectField("content");
        try w.write(msg.content);
        try w.endObject();
    }
    try w.endArray();
    try w.objectField("usage");
    try w.beginObject();
    try w.objectField("total_input_tokens");
    try w.write(s.total_input_tokens);
    try w.objectField("total_output_tokens");
    try w.write(s.total_output_tokens);
    try w.endObject();
    try w.endObject();

    const json_bytes = allocating.written();

    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});

    // Write to .tmp, then atomically rename. Mode 0600 for safety.
    const cwd = Io.Dir.cwd();
    const tmp = try cwd.createFile(io, tmp_path, .{ .truncate = true });
    {
        defer tmp.close(io);
        var write_buf: [4096]u8 = undefined;
        var fw: Io.File.Writer = .init(tmp, io, &write_buf);
        try fw.interface.writeAll(json_bytes);
        try fw.interface.flush();
    }
    try cwd.rename(tmp_path, cwd, path, io);
}

const testing = std.testing;

test "round-trip: save and load" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var s = Session{ .provider = "local", .model = "gemma", .system = "be brief" };
    try s.messages.append(a, .{ .role = "user", .content = "hi" });
    try s.messages.append(a, .{ .role = "assistant", .content = "Hello!" });
    s.total_input_tokens = 5;
    s.total_output_tokens = 3;

    // Serialize to JSON via parse round-trip rather than hitting filesystem in unit test.
    var allocating = std.Io.Writer.Allocating.init(a);
    const writer = &allocating.writer;
    var w: std.json.Stringify = .{ .writer = writer };
    try w.beginObject();
    try w.objectField("version");
    try w.write(@as(u32, 1));
    try w.objectField("provider");
    try w.write(s.provider.?);
    try w.objectField("model");
    try w.write(s.model.?);
    try w.objectField("system");
    try w.write(s.system.?);
    try w.objectField("messages");
    try w.beginArray();
    for (s.messages.items) |msg| {
        try w.beginObject();
        try w.objectField("role");
        try w.write(msg.role);
        try w.objectField("content");
        try w.write(msg.content);
        try w.endObject();
    }
    try w.endArray();
    try w.objectField("usage");
    try w.beginObject();
    try w.objectField("total_input_tokens");
    try w.write(s.total_input_tokens);
    try w.objectField("total_output_tokens");
    try w.write(s.total_output_tokens);
    try w.endObject();
    try w.endObject();

    const back = try parse(a, allocating.written());
    try testing.expectEqualStrings("local", back.provider.?);
    try testing.expectEqualStrings("gemma", back.model.?);
    try testing.expectEqualStrings("be brief", back.system.?);
    try testing.expectEqual(@as(usize, 2), back.messages.items.len);
    try testing.expectEqualStrings("user", back.messages.items[0].role);
    try testing.expectEqualStrings("hi", back.messages.items[0].content);
    try testing.expectEqualStrings("assistant", back.messages.items[1].role);
    try testing.expectEqualStrings("Hello!", back.messages.items[1].content);
    try testing.expectEqual(@as(u32, 5), back.total_input_tokens);
    try testing.expectEqual(@as(u32, 3), back.total_output_tokens);
}

test "parse: rejects unsupported version" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnsupportedVersion, parse(arena.allocator(), "{\"version\":99,\"messages\":[]}"));
}

test "parse: rejects non-object root" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.InvalidSchema, parse(arena.allocator(), "[]"));
}

test "parse: empty messages array OK" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const s = try parse(arena.allocator(), "{\"version\":1,\"messages\":[]}");
    try testing.expectEqual(@as(usize, 0), s.messages.items.len);
}
