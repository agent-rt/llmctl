//! Anthropic Messages API provider. Per TECH-DESIGN §3.
//! Validates the 3-layer architecture: only builder + decoder + auth defaults change.
//! Endpoint: POST {base_url}/v1/messages
//! Headers: x-api-key, anthropic-version: 2023-06-01

const std = @import("std");
const types = @import("types.zig");
const sse = @import("sse.zig");

const Allocator = std.mem.Allocator;

pub const HttpRequest = struct {
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
};

pub fn buildRequest(
    arena: Allocator,
    base_url: []const u8,
    auth: types.Auth,
    opts: types.RequestOptions,
) !HttpRequest {
    const url = try std.fmt.allocPrint(arena, "{s}/v1/messages", .{trimTrailingSlash(base_url)});

    var allocating = std.Io.Writer.Allocating.init(arena);
    const writer = &allocating.writer;
    var s: std.json.Stringify = .{ .writer = writer };

    try s.beginObject();
    try s.objectField("model");
    try s.write(opts.model);

    // Anthropic requires max_tokens.
    try s.objectField("max_tokens");
    try s.write(opts.max_tokens orelse 4096);

    try s.objectField("stream");
    try s.write(opts.stream);

    if (opts.system) |sys| {
        try s.objectField("system");
        try s.write(sys);
    }

    if (opts.temperature) |t| {
        try s.objectField("temperature");
        try s.write(t);
    }
    if (opts.top_p) |p| {
        try s.objectField("top_p");
        try s.write(p);
    }
    if (opts.stop) |stops| {
        try s.objectField("stop_sequences");
        try s.beginArray();
        for (stops) |st| try s.write(st);
        try s.endArray();
    }

    try s.objectField("messages");
    try s.beginArray();
    for (opts.messages) |msg| {
        // System messages are top-level, skip if accidentally included.
        if (msg.role == .system) continue;
        try s.beginObject();
        try s.objectField("role");
        try s.write(msg.role.toString());
        try s.objectField("content");
        var combined: std.ArrayList(u8) = .empty;
        for (msg.content) |part| switch (part) {
            .text => |t| try combined.appendSlice(arena, t),
        };
        try s.write(combined.items);
        try s.endObject();
    }
    try s.endArray();

    // Merge --extra fields at top level.
    var it = opts.extra.iterator();
    while (it.next()) |entry| {
        try s.objectField(entry.key_ptr.*);
        try s.write(entry.value_ptr.*);
    }

    try s.endObject();
    const body_bytes = allocating.written();

    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(arena, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(arena, .{ .name = "Accept", .value = "text/event-stream" });
    try headers.append(arena, .{ .name = "anthropic-version", .value = "2023-06-01" });

    // Anthropic uses x-api-key header. Translate Auth.bearer → x-api-key for ergonomic config.
    switch (auth) {
        .none => {},
        .bearer => |token| if (token.len > 0) {
            try headers.append(arena, .{ .name = "x-api-key", .value = token });
        },
        .header => |h| if (h.value.len > 0) {
            try headers.append(arena, .{ .name = h.name, .value = h.value });
        },
    }

    return .{ .url = url, .body = body_bytes, .headers = headers.items };
}

fn trimTrailingSlash(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '/') return s[0 .. s.len - 1];
    return s;
}

// ── Stream Decoder ──

pub const StreamDecoder = struct {
    arena: *std.heap.ArenaAllocator,
    sse_parser: sse.Parser,
    state: State,

    pub const State = struct {
        finish_reason: types.FinishReason = .unknown,
        usage: types.Usage = .{},
        seen_finish: bool = false,
    };

    pub fn init(arena: *std.heap.ArenaAllocator) StreamDecoder {
        return .{
            .arena = arena,
            .sse_parser = sse.Parser.init(arena),
            .state = .{},
        };
    }

    pub fn deinit(self: *StreamDecoder) void {
        self.sse_parser.deinit();
    }

    pub fn feed(self: *StreamDecoder, chunk: []const u8, out: *std.ArrayList(types.Delta)) !void {
        const gpa = self.arena.allocator();
        var events: std.ArrayList(sse.SseEvent) = .empty;
        defer events.deinit(gpa);
        try self.sse_parser.feed(chunk, &events);
        for (events.items) |ev| try self.handleEvent(ev, out);
    }

    pub fn finalize(self: *StreamDecoder, out: *std.ArrayList(types.Delta)) !void {
        const gpa = self.arena.allocator();
        if (!self.state.seen_finish) {
            try out.append(gpa, .{ .finish = .{ .reason = self.state.finish_reason, .usage = self.state.usage } });
            self.state.seen_finish = true;
        }
    }

    fn handleEvent(self: *StreamDecoder, ev: sse.SseEvent, out: *std.ArrayList(types.Delta)) !void {
        const gpa = self.arena.allocator();
        const event_name = ev.event orelse "";

        // Anthropic emits named events; "ping" and content frames have JSON in `data:`.
        if (std.mem.eql(u8, event_name, "ping")) return;

        const parsed = std.json.parseFromSlice(std.json.Value, gpa, ev.data, .{}) catch return;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return;

        if (std.mem.eql(u8, event_name, "message_start")) {
            // {"type":"message_start","message":{"usage":{"input_tokens":N,...}}}
            if (root.object.get("message")) |m| if (m == .object) {
                if (m.object.get("usage")) |u| if (u == .object) {
                    if (u.object.get("input_tokens")) |t| if (t == .integer) {
                        self.state.usage.input_tokens = @intCast(t.integer);
                    };
                };
            };
        } else if (std.mem.eql(u8, event_name, "content_block_delta")) {
            // {"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}
            if (root.object.get("delta")) |d| if (d == .object) {
                const delta_type = blk: {
                    const dt = d.object.get("type") orelse break :blk @as([]const u8, "");
                    if (dt != .string) break :blk @as([]const u8, "");
                    break :blk dt.string;
                };
                if (std.mem.eql(u8, delta_type, "text_delta")) {
                    if (d.object.get("text")) |tv| if (tv == .string and tv.string.len > 0) {
                        const t = try gpa.dupe(u8, tv.string);
                        try out.append(gpa, .{ .text = t });
                    };
                } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
                    if (d.object.get("thinking")) |tv| if (tv == .string and tv.string.len > 0) {
                        const t = try gpa.dupe(u8, tv.string);
                        try out.append(gpa, .{ .thinking = t });
                    };
                }
            };
        } else if (std.mem.eql(u8, event_name, "message_delta")) {
            // {"type":"message_delta","delta":{"stop_reason":"..."},"usage":{"output_tokens":N}}
            if (root.object.get("delta")) |d| if (d == .object) {
                if (d.object.get("stop_reason")) |sr| if (sr == .string) {
                    self.state.finish_reason = mapStopReason(sr.string);
                };
            };
            if (root.object.get("usage")) |u| if (u == .object) {
                if (u.object.get("output_tokens")) |t| if (t == .integer) {
                    self.state.usage.output_tokens = @intCast(t.integer);
                };
            };
        } else if (std.mem.eql(u8, event_name, "message_stop")) {
            try out.append(gpa, .{ .finish = .{ .reason = self.state.finish_reason, .usage = self.state.usage } });
            self.state.seen_finish = true;
        }
        // content_block_start / content_block_stop / error events: ignored or future-handled.
    }
};

fn mapStopReason(s: []const u8) types.FinishReason {
    if (std.mem.eql(u8, s, "end_turn")) return .end_turn;
    if (std.mem.eql(u8, s, "max_tokens")) return .max_tokens;
    if (std.mem.eql(u8, s, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, s, "tool_use")) return .tool_use;
    return .other;
}

// ── Tests ──
const testing = std.testing;

test "buildRequest: anthropic shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const messages = [_]types.Message{
        .{ .role = .user, .content = &[_]types.ContentPart{.{ .text = "hi" }} },
    };
    const opts = types.RequestOptions{
        .model = "claude-sonnet-4-5",
        .messages = &messages,
        .system = "be concise",
        .max_tokens = 1024,
        .stream = true,
    };
    const req = try buildRequest(arena.allocator(), "https://api.anthropic.com", .{ .bearer = "sk-ant-xxx" }, opts);

    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", req.url);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"model\":\"claude-sonnet-4-5\"") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"max_tokens\":1024") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"system\":\"be concise\"") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"stream\":true") != null);

    var saw_x_api_key = false;
    var saw_version = false;
    for (req.headers) |h| {
        if (std.mem.eql(u8, h.name, "x-api-key") and std.mem.eql(u8, h.value, "sk-ant-xxx")) saw_x_api_key = true;
        if (std.mem.eql(u8, h.name, "anthropic-version")) saw_version = true;
    }
    try testing.expect(saw_x_api_key);
    try testing.expect(saw_version);
}

test "stream decoder: typical Anthropic flow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dec = StreamDecoder.init(&arena);
    defer dec.deinit();

    var out: std.ArrayList(types.Delta) = .empty;
    defer out.deinit(gpa);

    const stream =
        "event: message_start\ndata: {\"type\":\"message_start\",\"message\":{\"usage\":{\"input_tokens\":12}}}\n\n" ++
        "event: content_block_start\ndata: {\"type\":\"content_block_start\",\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hello\"}}\n\n" ++
        "event: content_block_delta\ndata: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\" world\"}}\n\n" ++
        "event: content_block_stop\ndata: {\"type\":\"content_block_stop\"}\n\n" ++
        "event: message_delta\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":8}}\n\n" ++
        "event: message_stop\ndata: {\"type\":\"message_stop\"}\n\n";

    try dec.feed(stream, &out);

    var text_count: usize = 0;
    var saw_finish = false;
    for (out.items) |d| switch (d) {
        .text => text_count += 1,
        .finish => |f| {
            saw_finish = true;
            try testing.expectEqual(types.FinishReason.end_turn, f.reason);
            try testing.expectEqual(@as(u32, 12), f.usage.input_tokens);
            try testing.expectEqual(@as(u32, 8), f.usage.output_tokens);
        },
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), text_count);
    try testing.expect(saw_finish);
}

test "stream decoder: ping ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dec = StreamDecoder.init(&arena);
    defer dec.deinit();

    var out: std.ArrayList(types.Delta) = .empty;
    defer out.deinit(gpa);

    try dec.feed("event: ping\ndata: {\"type\":\"ping\"}\n\n", &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
