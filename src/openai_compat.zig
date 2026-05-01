//! OpenAI-compatible provider: chat completions endpoint.
//! Covers llama-server, Ollama, LM Studio, vLLM, Groq, Together, OpenRouter, OpenAI itself.
//! Per TECH-DESIGN §3.3, §4.

const std = @import("std");
const types = @import("types.zig");
const sse = @import("sse.zig");

const Allocator = std.mem.Allocator;

pub const HttpRequest = struct {
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
};

/// Build chat-completions JSON request body. Returns body + headers.
pub fn buildRequest(
    arena: Allocator,
    base_url: []const u8,
    auth: types.Auth,
    opts: types.RequestOptions,
) !HttpRequest {
    // ── URL ──
    const url = try std.fmt.allocPrint(arena, "{s}/v1/chat/completions", .{trimTrailingSlash(base_url)});

    // ── Body ──
    var allocating = std.Io.Writer.Allocating.init(arena);
    const writer = &allocating.writer;
    var s: std.json.Stringify = .{ .writer = writer };

    try s.beginObject();
    try s.objectField("model");
    try s.write(opts.model);

    try s.objectField("stream");
    try s.write(opts.stream);

    if (opts.stream) {
        try s.objectField("stream_options");
        try s.beginObject();
        try s.objectField("include_usage");
        try s.write(true);
        try s.endObject();
    }

    try s.objectField("messages");
    try s.beginArray();
    if (opts.system) |sys| {
        try s.beginObject();
        try s.objectField("role");
        try s.write("system");
        try s.objectField("content");
        try s.write(sys);
        try s.endObject();
    }
    for (opts.messages) |msg| {
        try s.beginObject();
        try s.objectField("role");
        try s.write(msg.role.toString());
        try s.objectField("content");
        // For now we only handle a single text part (P1 scope).
        var combined: std.ArrayList(u8) = .empty;
        for (msg.content) |part| switch (part) {
            .text => |t| try combined.appendSlice(arena, t),
        };
        try s.write(combined.items);
        try s.endObject();
    }
    try s.endArray();

    if (opts.temperature) |t| {
        try s.objectField("temperature");
        try s.write(t);
    }
    if (opts.max_tokens) |m| {
        try s.objectField("max_tokens");
        try s.write(m);
    }
    if (opts.top_p) |p| {
        try s.objectField("top_p");
        try s.write(p);
    }
    if (opts.stop) |stops| {
        try s.objectField("stop");
        try s.beginArray();
        for (stops) |st| try s.write(st);
        try s.endArray();
    }

    // Merge --extra fields at top level. They override standard fields if same key.
    var it = opts.extra.iterator();
    while (it.next()) |entry| {
        try s.objectField(entry.key_ptr.*);
        try s.write(entry.value_ptr.*);
    }

    try s.endObject();
    const body_bytes = allocating.written();

    // ── Headers ──
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(arena, .{ .name = "Content-Type", .value = "application/json" });
    try headers.append(arena, .{ .name = "Accept", .value = "text/event-stream" });
    try auth.applyHeaders(&headers, arena);

    return .{
        .url = url,
        .body = body_bytes,
        .headers = headers.items,
    };
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
        seen_done: bool = false,
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

    /// Feed raw bytes; emit Deltas.
    pub fn feed(self: *StreamDecoder, chunk: []const u8, out: *std.ArrayList(types.Delta)) !void {
        const gpa = self.arena.allocator();
        var events: std.ArrayList(sse.SseEvent) = .empty;
        defer events.deinit(gpa);
        try self.sse_parser.feed(chunk, &events);

        for (events.items) |ev| {
            try self.handleEvent(ev, out);
        }
    }

    /// Called when stream ends (HTTP body closed). Emits final finish if not already.
    pub fn finalize(self: *StreamDecoder, out: *std.ArrayList(types.Delta)) !void {
        const gpa = self.arena.allocator();
        if (!self.state.seen_finish) {
            try out.append(gpa, .{ .finish = .{
                .reason = self.state.finish_reason,
                .usage = self.state.usage,
            } });
            self.state.seen_finish = true;
        }
    }

    fn handleEvent(self: *StreamDecoder, ev: sse.SseEvent, out: *std.ArrayList(types.Delta)) !void {
        const gpa = self.arena.allocator();

        // OpenAI uses unnamed events with [DONE] sentinel.
        if (std.mem.eql(u8, ev.data, "[DONE]")) {
            self.state.seen_done = true;
            if (!self.state.seen_finish) {
                try out.append(gpa, .{ .finish = .{
                    .reason = self.state.finish_reason,
                    .usage = self.state.usage,
                } });
                self.state.seen_finish = true;
            }
            return;
        }

        const parsed = std.json.parseFromSlice(std.json.Value, gpa, ev.data, .{}) catch {
            // Tolerate malformed chunks (some servers send heartbeats).
            return;
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return;

        // ── usage chunk (final chunk in OpenAI when stream_options.include_usage) ──
        if (root.object.get("usage")) |u| {
            if (u == .object) {
                var new_usage: types.Usage = .{};
                if (u.object.get("prompt_tokens")) |t| if (t == .integer) {
                    new_usage.input_tokens = @intCast(t.integer);
                };
                if (u.object.get("completion_tokens")) |t| if (t == .integer) {
                    new_usage.output_tokens = @intCast(t.integer);
                };
                self.state.usage.merge(new_usage);
                try out.append(gpa, .{ .usage_update = self.state.usage });
            }
        }

        // ── choices[0].delta.content ──
        if (root.object.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0) {
                const choice = choices.array.items[0];
                if (choice == .object) {
                    if (choice.object.get("delta")) |d| {
                        if (d == .object) {
                            if (d.object.get("content")) |c| {
                                if (c == .string and c.string.len > 0) {
                                    const text_copy = try gpa.dupe(u8, c.string);
                                    try out.append(gpa, .{ .text = text_copy });
                                }
                            }
                            if (d.object.get("reasoning_content")) |r| {
                                // llama-server / DeepSeek-style thinking content.
                                if (r == .string and r.string.len > 0) {
                                    const t = try gpa.dupe(u8, r.string);
                                    try out.append(gpa, .{ .thinking = t });
                                }
                            }
                        }
                    }
                    if (choice.object.get("finish_reason")) |fr| {
                        if (fr == .string) {
                            self.state.finish_reason = mapFinishReason(fr.string);
                        }
                    }
                }
            }
        }
    }
};

fn mapFinishReason(s: []const u8) types.FinishReason {
    if (std.mem.eql(u8, s, "stop")) return .end_turn;
    if (std.mem.eql(u8, s, "length")) return .max_tokens;
    if (std.mem.eql(u8, s, "tool_calls")) return .tool_use;
    if (std.mem.eql(u8, s, "content_filter")) return .content_filter;
    return .other;
}

// ── Batch Decoder (non-streaming) ──

pub fn decodeBatch(arena: Allocator, body: []const u8) !struct {
    content: []const u8,
    usage: types.Usage,
    finish_reason: types.FinishReason,
} {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;

    const choices = root.object.get("choices") orelse return error.InvalidResponse;
    if (choices != .array or choices.array.items.len == 0) return error.InvalidResponse;
    const choice = choices.array.items[0];
    if (choice != .object) return error.InvalidResponse;

    const message = choice.object.get("message") orelse return error.InvalidResponse;
    if (message != .object) return error.InvalidResponse;
    const content = message.object.get("content") orelse return error.InvalidResponse;
    const content_str = if (content == .string) try arena.dupe(u8, content.string) else "";

    var usage: types.Usage = .{};
    if (root.object.get("usage")) |u| if (u == .object) {
        if (u.object.get("prompt_tokens")) |t| if (t == .integer) {
            usage.input_tokens = @intCast(t.integer);
        };
        if (u.object.get("completion_tokens")) |t| if (t == .integer) {
            usage.output_tokens = @intCast(t.integer);
        };
    };

    var finish: types.FinishReason = .unknown;
    if (choice.object.get("finish_reason")) |fr| if (fr == .string) {
        finish = mapFinishReason(fr.string);
    };

    return .{ .content = content_str, .usage = usage, .finish_reason = finish };
}

// ── Tests ──
const testing = std.testing;

test "stream decoder: typical OpenAI flow" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dec = StreamDecoder.init(&arena);
    defer dec.deinit();

    var out: std.ArrayList(types.Delta) = .empty;
    defer out.deinit(gpa);

    const stream =
        "data: {\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n" ++
        "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n" ++
        "data: [DONE]\n\n";

    try dec.feed(stream, &out);

    var text_count: usize = 0;
    var found_finish = false;
    var saw_usage = false;
    for (out.items) |d| switch (d) {
        .text => text_count += 1,
        .finish => |f| {
            found_finish = true;
            try testing.expectEqual(types.FinishReason.end_turn, f.reason);
            try testing.expectEqual(@as(u32, 5), f.usage.input_tokens);
            try testing.expectEqual(@as(u32, 2), f.usage.output_tokens);
        },
        .usage_update => saw_usage = true,
        else => {},
    };
    try testing.expectEqual(@as(usize, 2), text_count);
    try testing.expect(found_finish);
    try testing.expect(saw_usage);
}

test "stream decoder: tolerates malformed chunk" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var dec = StreamDecoder.init(&arena);
    defer dec.deinit();

    var out: std.ArrayList(types.Delta) = .empty;
    defer out.deinit(gpa);

    try dec.feed("data: not-json\n\ndata: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n", &out);

    var got_text = false;
    for (out.items) |d| switch (d) {
        .text => |t| {
            got_text = true;
            try testing.expectEqualStrings("x", t);
        },
        else => {},
    };
    try testing.expect(got_text);
}

test "buildRequest: basic shape" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const messages = [_]types.Message{
        .{
            .role = .user,
            .content = &[_]types.ContentPart{.{ .text = "hi" }},
        },
    };

    const opts = types.RequestOptions{
        .model = "gpt-4",
        .messages = &messages,
        .system = "be brief",
        .stream = true,
    };

    const req = try buildRequest(
        arena.allocator(),
        "https://api.example.com/",
        .{ .bearer = "sk-test" },
        opts,
    );

    try testing.expectEqualStrings("https://api.example.com/v1/chat/completions", req.url);
    // Body should contain key fields.
    try testing.expect(std.mem.indexOf(u8, req.body, "\"model\":\"gpt-4\"") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"role\":\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"role\":\"user\"") != null);

    // Auth header present.
    var saw_auth = false;
    for (req.headers) |h| {
        if (std.mem.eql(u8, h.name, "Authorization")) {
            saw_auth = true;
            try testing.expectEqualStrings("Bearer sk-test", h.value);
        }
    }
    try testing.expect(saw_auth);
}

test "buildRequest: extra fields merged" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();

    var extra: std.StringHashMapUnmanaged(std.json.Value) = .empty;
    try extra.put(gpa, "cache_prompt", .{ .bool = true });
    try extra.put(gpa, "seed", .{ .integer = 42 });

    const messages = [_]types.Message{};
    const opts = types.RequestOptions{
        .model = "x",
        .messages = &messages,
        .extra = extra,
    };

    const req = try buildRequest(arena.allocator(), "http://localhost:8800", .none, opts);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"cache_prompt\":true") != null);
    try testing.expect(std.mem.indexOf(u8, req.body, "\"seed\":42") != null);
}

test "buildRequest: no auth header when none" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const opts = types.RequestOptions{
        .model = "x",
        .messages = &[_]types.Message{},
    };

    const req = try buildRequest(arena.allocator(), "http://localhost:8800", .none, opts);
    for (req.headers) |h| {
        try testing.expect(!std.mem.eql(u8, h.name, "Authorization"));
    }
}
