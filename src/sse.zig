//! SSE (Server-Sent Events) parser, provider-agnostic.
//!
//! Per TECH-DESIGN §7. Feeds raw bytes (possibly split across HTTP chunks),
//! emits SseEvent values. Holds cross-chunk state for partial lines and
//! multi-line `data:` accumulation.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const SseEvent = struct {
    /// `event:` field, or null if absent.
    event: ?[]const u8,
    /// Concatenated `data:` payload. Multiple `data:` lines are joined with `\n`.
    data: []const u8,
    /// `id:` field, or null if absent.
    id: ?[]const u8,
};

pub const Parser = struct {
    arena: *std.heap.ArenaAllocator,
    /// Buffer for bytes that didn't yet form a complete line.
    line_buf: std.ArrayList(u8),
    /// Currently-accumulating event fields. Reset on dispatch (empty line).
    cur_event: ?[]const u8,
    cur_data: std.ArrayList(u8),
    cur_id: ?[]const u8,
    /// True if any `data:` field was seen for the current event.
    has_data: bool,

    pub fn init(arena: *std.heap.ArenaAllocator) Parser {
        return .{
            .arena = arena,
            .line_buf = .empty,
            .cur_event = null,
            .cur_data = .empty,
            .cur_id = null,
            .has_data = false,
        };
    }

    pub fn deinit(self: *Parser) void {
        const gpa = self.arena.allocator();
        self.line_buf.deinit(gpa);
        self.cur_data.deinit(gpa);
    }

    /// Feed a chunk of bytes. Newly-completed events are appended to `out`.
    /// String memory of emitted events is owned by `self.arena`; it lives
    /// until the arena is reset/freed by the caller.
    pub fn feed(self: *Parser, chunk: []const u8, out: *std.ArrayList(SseEvent)) !void {
        const gpa = self.arena.allocator();
        // Append, normalizing CRLF/CR to LF on the fly.
        try self.line_buf.ensureUnusedCapacity(gpa, chunk.len);
        var i: usize = 0;
        while (i < chunk.len) : (i += 1) {
            const b = chunk[i];
            if (b == '\r') {
                self.line_buf.appendAssumeCapacity('\n');
                if (i + 1 < chunk.len and chunk[i + 1] == '\n') i += 1;
            } else {
                self.line_buf.appendAssumeCapacity(b);
            }
        }

        // Process complete lines.
        var start: usize = 0;
        var idx: usize = 0;
        while (idx < self.line_buf.items.len) : (idx += 1) {
            if (self.line_buf.items[idx] != '\n') continue;
            const line = self.line_buf.items[start..idx];
            try self.handleLine(line, out);
            start = idx + 1;
        }

        // Keep leftover (incomplete line) for next feed.
        if (start > 0) {
            const leftover_len = self.line_buf.items.len - start;
            std.mem.copyForwards(u8, self.line_buf.items[0..leftover_len], self.line_buf.items[start..]);
            self.line_buf.shrinkRetainingCapacity(leftover_len);
        }
    }

    fn handleLine(self: *Parser, line: []const u8, out: *std.ArrayList(SseEvent)) !void {
        const gpa = self.arena.allocator();

        if (line.len == 0) {
            // Empty line: dispatch event if any data accumulated.
            if (self.has_data) {
                const data_copy = try gpa.dupe(u8, self.cur_data.items);
                try out.append(gpa, .{
                    .event = self.cur_event,
                    .data = data_copy,
                    .id = self.cur_id,
                });
            }
            self.cur_event = null;
            self.cur_id = null;
            self.cur_data.clearRetainingCapacity();
            self.has_data = false;
            return;
        }

        // Comment line.
        if (line[0] == ':') return;

        // Parse `field` and `value`.
        const colon = std.mem.indexOfScalar(u8, line, ':');
        const field = if (colon) |c| line[0..c] else line;
        var value: []const u8 = if (colon) |c| line[c + 1 ..] else "";
        // Per spec, single leading space is stripped.
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            self.cur_event = try gpa.dupe(u8, value);
        } else if (std.mem.eql(u8, field, "data")) {
            if (self.has_data) try self.cur_data.append(gpa, '\n');
            try self.cur_data.appendSlice(gpa, value);
            self.has_data = true;
        } else if (std.mem.eql(u8, field, "id")) {
            self.cur_id = try gpa.dupe(u8, value);
        } else {
            // Unknown field, ignore.
        }
    }
};

// ────────────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn parseAll(input: []const u8, out: *std.ArrayList(SseEvent), arena: *std.heap.ArenaAllocator) !void {
    var p = Parser.init(arena);
    defer p.deinit();
    try p.feed(input, out);
}

test "single event single data line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    try parseAll("data: hello\n\n", &out, &arena);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("hello", out.items[0].data);
    try testing.expect(out.items[0].event == null);
}

test "multi-line data joined with newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    try parseAll("data: line1\ndata: line2\n\n", &out, &arena);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("line1\nline2", out.items[0].data);
}

test "event field with data" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    try parseAll("event: message_start\ndata: {\"k\":1}\n\n", &out, &arena);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("message_start", out.items[0].event.?);
    try testing.expectEqualStrings("{\"k\":1}", out.items[0].data);
}

test "comment lines ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    try parseAll(": keep-alive\n: another\ndata: x\n\n", &out, &arena);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("x", out.items[0].data);
}

test "empty event without data is dropped" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    try parseAll("\n\nevent: ping\n\ndata: x\n\n", &out, &arena);
    // First two empty lines: no data → no dispatch.
    // "event: ping" alone with no data → no dispatch.
    // "data: x" → 1 event.
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("x", out.items[0].data);
}

test "cross-chunk split mid-line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    var p = Parser.init(&arena);
    defer p.deinit();

    try p.feed("data: hel", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try p.feed("lo\n\n", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("hello", out.items[0].data);
}

test "cross-chunk split at newline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    var p = Parser.init(&arena);
    defer p.deinit();

    try p.feed("data: hi\n", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try p.feed("\n", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
}

test "CRLF normalized to LF" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    try parseAll("data: hi\r\n\r\n", &out, &arena);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("hi", out.items[0].data);
}

test "CRLF split across chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    var p = Parser.init(&arena);
    defer p.deinit();

    try p.feed("data: hi\r", &out);
    try p.feed("\n\r\n", &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("hi", out.items[0].data);
}

test "OpenAI-style stream with [DONE]" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    const stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hi\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\" there\"}}]}\n\n" ++
        "data: [DONE]\n\n";

    try parseAll(stream, &out, &arena);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("[DONE]", out.items[2].data);
}

test "Anthropic-style event with named events" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    const stream =
        "event: message_start\ndata: {\"type\":\"message_start\"}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\"}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

    try parseAll(stream, &out, &arena);
    try testing.expectEqual(@as(usize, 3), out.items.len);
    try testing.expectEqualStrings("message_start", out.items[0].event.?);
    try testing.expectEqualStrings("content_block_delta", out.items[1].event.?);
    try testing.expectEqualStrings("message_stop", out.items[2].event.?);
}

test "field without colon" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    // "data" alone (no colon) should be treated as field "data" with empty value.
    try parseAll("data\n\n", &out, &arena);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqualStrings("", out.items[0].data);
}

test "byte-by-byte feed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var out: std.ArrayList(SseEvent) = .empty;
    defer out.deinit(gpa);

    var p = Parser.init(&arena);
    defer p.deinit();

    const stream = "data: abc\ndata: def\n\nevent: end\ndata: x\n\n";
    for (stream) |b| {
        try p.feed(&[_]u8{b}, &out);
    }
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqualStrings("abc\ndef", out.items[0].data);
    try testing.expectEqualStrings("end", out.items[1].event.?);
    try testing.expectEqualStrings("x", out.items[1].data);
}
