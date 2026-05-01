//! llmctl — fast, pipe-friendly LLM API debugger.
//! P1 (single model) + P2 sequential multi-model orchestrator.

const std = @import("std");
const Io = std.Io;
const llmctl = @import("llmctl");

const cli = llmctl.cli;
const types = llmctl.types;
const openai_compat = llmctl.openai_compat;
const anthropic = llmctl.anthropic;
const http = llmctl.http;
const redact = llmctl.redact;
const defaults_mod = llmctl.defaults;
const config_cmd = llmctl.config_cmd;
const error_body = llmctl.error_body;

const Compat = enum { openai, anthropic };

const version = "0.2.0";

const ProviderConfig = struct {
    name: []const u8,
    base_url: []const u8,
    auth_env: []const u8 = "",
    auth_kind: enum { none, bearer } = .none,
    compat: Compat = .openai,
};

fn builtinProvider(name: []const u8) ?ProviderConfig {
    if (std.mem.eql(u8, name, "local")) {
        return .{ .name = "local", .base_url = "http://localhost:8080", .auth_kind = .none, .compat = .openai };
    } else if (std.mem.eql(u8, name, "openai")) {
        return .{ .name = "openai", .base_url = "https://api.openai.com", .auth_env = "OPENAI_API_KEY", .auth_kind = .bearer, .compat = .openai };
    } else if (std.mem.eql(u8, name, "openai-compat")) {
        return .{ .name = "openai-compat", .base_url = "", .auth_env = "LLMCTL_API_KEY", .auth_kind = .bearer, .compat = .openai };
    } else if (std.mem.eql(u8, name, "anthropic")) {
        return .{ .name = "anthropic", .base_url = "https://api.anthropic.com", .auth_env = "ANTHROPIC_API_KEY", .auth_kind = .bearer, .compat = .anthropic };
    }
    return null;
}

const BuiltRequest = struct { url: []const u8, body: []const u8, headers: []const std.http.Header };

fn dispatchBuild(arena: std.mem.Allocator, prov: ProviderConfig, auth: types.Auth, opts: types.RequestOptions) !BuiltRequest {
    return switch (prov.compat) {
        .openai => blk: {
            const r = try openai_compat.buildRequest(arena, prov.base_url, auth, opts);
            break :blk .{ .url = r.url, .body = r.body, .headers = r.headers };
        },
        .anthropic => blk: {
            const r = try anthropic.buildRequest(arena, prov.base_url, auth, opts);
            break :blk .{ .url = r.url, .body = r.body, .headers = r.headers };
        },
    };
}

/// Erased decoder dispatcher. Each provider's StreamDecoder lives in its own arena.
const Decoder = union(Compat) {
    openai: openai_compat.StreamDecoder,
    anthropic: anthropic.StreamDecoder,

    fn init(compat: Compat, arena: *std.heap.ArenaAllocator) Decoder {
        return switch (compat) {
            .openai => .{ .openai = openai_compat.StreamDecoder.init(arena) },
            .anthropic => .{ .anthropic = anthropic.StreamDecoder.init(arena) },
        };
    }

    fn deinit(self: *Decoder) void {
        switch (self.*) {
            .openai => |*d| d.deinit(),
            .anthropic => |*d| d.deinit(),
        }
    }

    fn feed(self: *Decoder, chunk: []const u8, out: *std.ArrayList(types.Delta)) !void {
        switch (self.*) {
            .openai => |*d| try d.feed(chunk, out),
            .anthropic => |*d| try d.feed(chunk, out),
        }
    }

    fn finalize(self: *Decoder, out: *std.ArrayList(types.Delta)) !void {
        switch (self.*) {
            .openai => |*d| try d.finalize(out),
            .anthropic => |*d| try d.finalize(out),
        }
    }
};

// ────────────────────────────────────────────────────────────────────
// Per-worker state
// ────────────────────────────────────────────────────────────────────

const RunMode = enum {
    /// Single model: stream text directly to stdout (or buffer for json).
    single_live,
    /// Multi model, text mode: buffer per worker, print after with header.
    multi_buffered,
    /// ndjson with N>1: stream to stdout with worker_id, mutex-guarded.
    multi_ndjson,
};

const WorkerCtx = struct {
    arena: *std.heap.ArenaAllocator,
    decoder: *Decoder,
    output: cli.OutputFormat,
    mode: RunMode,
    worker_id: u32,
    /// Provider/model identifiers for output.
    provider_name: []const u8,
    model: []const u8,

    /// Live writer (stdout) for single_live & multi_ndjson.
    stdout: *Io.Writer,
    /// Mutex for concurrent multi_ndjson (placeholder for P3).
    stdout_mu: ?*anyopaque,

    /// In single_live: holds buffered content if --buffer or output==json.
    /// In multi_buffered: always populated.
    /// In multi_ndjson: unused.
    collected: std.ArrayList(u8) = .empty,

    /// Whether stdout streaming is happening live (text mode without buffer, single).
    live_text_stream: bool,

    final_usage: types.Usage = .{},
    final_finish: types.FinishReason = .unknown,
    bytes_in: usize = 0,
};

const WorkerResult = struct {
    worker_id: u32,
    provider: []const u8,
    model: []const u8,
    content: []const u8,
    usage: types.Usage,
    finish_reason: types.FinishReason,
    latency_ms: i64,
    bytes_in: usize,
    err: ?ErrInfo = null,
};

const ErrInfo = struct {
    code: types.ErrorCode,
    message: []const u8,
    status: ?u16,
};

// ────────────────────────────────────────────────────────────────────
// Streaming callbacks
// ────────────────────────────────────────────────────────────────────

fn onChunk(ctx_opaque: *anyopaque, chunk: []const u8) anyerror!void {
    const w: *WorkerCtx = @ptrCast(@alignCast(ctx_opaque));
    w.bytes_in += chunk.len;

    var deltas: std.ArrayList(types.Delta) = .empty;
    const gpa = w.arena.allocator();
    defer deltas.deinit(gpa);

    try w.decoder.feed(chunk, &deltas);
    for (deltas.items) |d| try emitDelta(w, d);
}

fn emitDelta(w: *WorkerCtx, d: types.Delta) !void {
    const gpa = w.arena.allocator();
    switch (d) {
        .text => |t| {
            switch (w.output) {
                .text => {
                    // Always collect so r.content is available for session saves and JSON.
                    try w.collected.appendSlice(gpa, t);
                    if (w.live_text_stream) {
                        try w.stdout.writeAll(t);
                        try w.stdout.flush();
                    }
                },
                .json => {
                    try w.collected.appendSlice(gpa, t);
                },
                .ndjson => {
                    try writeNdjsonText(w.stdout, "text", t, w.mode == .multi_ndjson, w.worker_id);
                    try w.stdout.flush();
                    // Also collect for verbose summary if needed.
                    try w.collected.appendSlice(gpa, t);
                },
            }
        },
        .thinking => |t| {
            if (w.output == .ndjson) {
                try writeNdjsonText(w.stdout, "thinking", t, w.mode == .multi_ndjson, w.worker_id);
                try w.stdout.flush();
            }
        },
        .usage_update => |u| {
            w.final_usage.merge(u);
            if (w.output == .ndjson) {
                try writeNdjsonUsage(w.stdout, "usage", u, w.mode == .multi_ndjson, w.worker_id);
                try w.stdout.flush();
            }
        },
        .finish => |f| {
            w.final_finish = f.reason;
            w.final_usage.merge(f.usage);
            if (w.output == .ndjson) {
                try writeNdjsonFinish(w.stdout, f.reason, f.usage, w.mode == .multi_ndjson, w.worker_id);
                try w.stdout.flush();
            }
        },
        else => {},
    }
}

// ────────────────────────────────────────────────────────────────────
// NDJSON writers
// ────────────────────────────────────────────────────────────────────

fn writeNdjsonText(wr: *Io.Writer, t: []const u8, text: []const u8, with_id: bool, id: u32) !void {
    var s: std.json.Stringify = .{ .writer = wr };
    try s.beginObject();
    try s.objectField("type");
    try s.write(t);
    if (with_id) {
        try s.objectField("worker_id");
        try s.write(id);
    }
    try s.objectField("text");
    try s.write(text);
    try s.endObject();
    try wr.writeAll("\n");
}

fn writeNdjsonUsage(wr: *Io.Writer, t: []const u8, u: types.Usage, with_id: bool, id: u32) !void {
    var s: std.json.Stringify = .{ .writer = wr };
    try s.beginObject();
    try s.objectField("type");
    try s.write(t);
    if (with_id) {
        try s.objectField("worker_id");
        try s.write(id);
    }
    try s.objectField("input_tokens");
    try s.write(u.input_tokens);
    try s.objectField("output_tokens");
    try s.write(u.output_tokens);
    try s.endObject();
    try wr.writeAll("\n");
}

fn writeNdjsonFinish(wr: *Io.Writer, reason: types.FinishReason, u: types.Usage, with_id: bool, id: u32) !void {
    var s: std.json.Stringify = .{ .writer = wr };
    try s.beginObject();
    try s.objectField("type");
    try s.write("finish");
    if (with_id) {
        try s.objectField("worker_id");
        try s.write(id);
    }
    try s.objectField("reason");
    try s.write(reason.toString());
    try s.objectField("usage");
    try s.beginObject();
    try s.objectField("input_tokens");
    try s.write(u.input_tokens);
    try s.objectField("output_tokens");
    try s.write(u.output_tokens);
    try s.endObject();
    try s.endObject();
    try wr.writeAll("\n");
}

fn writeNdjsonStart(wr: *Io.Writer, provider: []const u8, model: []const u8, with_id: bool, id: u32) !void {
    var s: std.json.Stringify = .{ .writer = wr };
    try s.beginObject();
    try s.objectField("type");
    try s.write("start");
    if (with_id) {
        try s.objectField("worker_id");
        try s.write(id);
    }
    try s.objectField("provider");
    try s.write(provider);
    try s.objectField("model");
    try s.write(model);
    try s.endObject();
    try wr.writeAll("\n");
}

fn writeNdjsonEnd(wr: *Io.Writer, success: bool) !void {
    var s: std.json.Stringify = .{ .writer = wr };
    try s.beginObject();
    try s.objectField("type");
    try s.write("end");
    try s.objectField("schema_version");
    try s.write(1);
    try s.objectField("success");
    try s.write(success);
    try s.endObject();
    try wr.writeAll("\n");
}

// ────────────────────────────────────────────────────────────────────
// JSON aggregate writers
// ────────────────────────────────────────────────────────────────────

fn writeOneJsonResult(s: *std.json.Stringify, r: WorkerResult) !void {
    try s.beginObject();
    try s.objectField("worker_id");
    try s.write(r.worker_id);
    try s.objectField("provider");
    try s.write(r.provider);
    try s.objectField("model");
    try s.write(r.model);
    if (r.err) |e| {
        try s.objectField("success");
        try s.write(false);
        try s.objectField("error");
        try s.beginObject();
        try s.objectField("code");
        try s.write(e.code.toString());
        try s.objectField("message");
        try s.write(e.message);
        if (e.status) |st| {
            try s.objectField("status");
            try s.write(st);
        }
        try s.endObject();
    } else {
        try s.objectField("success");
        try s.write(true);
        try s.objectField("content");
        try s.write(r.content);
        try s.objectField("usage");
        try s.beginObject();
        try s.objectField("input_tokens");
        try s.write(r.usage.input_tokens);
        try s.objectField("output_tokens");
        try s.write(r.usage.output_tokens);
        try s.objectField("total_tokens");
        try s.write(r.usage.total());
        try s.endObject();
        try s.objectField("latency_ms");
        try s.write(r.latency_ms);
        try s.objectField("finish_reason");
        try s.write(r.finish_reason.toString());
    }
    try s.endObject();
}

fn writeJsonSingle(wr: *Io.Writer, r: WorkerResult) !void {
    var s: std.json.Stringify = .{ .writer = wr };
    try s.beginObject();
    try s.objectField("schema_version");
    try s.write(1);
    if (r.err) |e| {
        try s.objectField("success");
        try s.write(false);
        try s.objectField("provider");
        try s.write(r.provider);
        try s.objectField("model");
        try s.write(r.model);
        try s.objectField("error");
        try s.beginObject();
        try s.objectField("code");
        try s.write(e.code.toString());
        try s.objectField("message");
        try s.write(e.message);
        if (e.status) |st| {
            try s.objectField("status");
            try s.write(st);
        }
        try s.endObject();
    } else {
        try s.objectField("success");
        try s.write(true);
        try s.objectField("provider");
        try s.write(r.provider);
        try s.objectField("model");
        try s.write(r.model);
        try s.objectField("content");
        try s.write(r.content);
        try s.objectField("usage");
        try s.beginObject();
        try s.objectField("input_tokens");
        try s.write(r.usage.input_tokens);
        try s.objectField("output_tokens");
        try s.write(r.usage.output_tokens);
        try s.objectField("total_tokens");
        try s.write(r.usage.total());
        try s.endObject();
        try s.objectField("latency_ms");
        try s.write(r.latency_ms);
        try s.objectField("finish_reason");
        try s.write(r.finish_reason.toString());
    }
    try s.endObject();
    try wr.writeAll("\n");
}

fn writeJsonMulti(wr: *Io.Writer, results: []const WorkerResult) !void {
    var s: std.json.Stringify = .{ .writer = wr };
    try s.beginObject();
    try s.objectField("schema_version");
    try s.write(1);
    var any_ok = false;
    for (results) |r| if (r.err == null) {
        any_ok = true;
        break;
    };
    try s.objectField("success");
    try s.write(any_ok);
    try s.objectField("results");
    try s.beginArray();
    for (results) |r| try writeOneJsonResult(&s, r);
    try s.endArray();
    try s.endObject();
    try wr.writeAll("\n");
}

// ────────────────────────────────────────────────────────────────────
// Reading helpers
// ────────────────────────────────────────────────────────────────────

fn readAllFromReader(arena: std.mem.Allocator, reader: *Io.Reader) ![]u8 {
    var collected: std.ArrayList(u8) = .empty;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&buf);
        if (n == 0) break;
        try collected.appendSlice(arena, buf[0..n]);
    }
    return collected.items;
}

fn readSystemPrompt(arena: std.mem.Allocator, io: Io, raw: []const u8) ![]const u8 {
    if (raw.len > 0 and raw[0] == '@') {
        const path = raw[1..];
        const file = try Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        var read_buf: [8192]u8 = undefined;
        var fr: Io.File.Reader = .init(file, io, &read_buf);
        return readAllFromReader(arena, &fr.interface);
    }
    return raw;
}

fn readStdin(arena: std.mem.Allocator, io: Io) !?[]const u8 {
    const stdin_file = Io.File.stdin();
    if (stdin_file.isTty(io) catch true) return null;
    var buf: [8192]u8 = undefined;
    var fr: Io.File.Reader = .init(stdin_file, io, &buf);
    const collected = try readAllFromReader(arena, &fr.interface);
    if (collected.len == 0) return null;
    var s = collected;
    while (s.len > 0 and (s[s.len - 1] == '\n' or s[s.len - 1] == '\r')) s.len -= 1;
    return s;
}

fn buildPrompt(arena: std.mem.Allocator, argv_prompt: ?[]const u8, stdin_text: ?[]const u8) !?[]const u8 {
    if (argv_prompt) |a| {
        if (stdin_text) |s| {
            return try std.fmt.allocPrint(arena, "{s}\n\n{s}", .{ a, s });
        }
        return a;
    }
    return stdin_text;
}

fn resolveAuth(env: *std.process.Environ.Map, prov: ProviderConfig) types.Auth {
    switch (prov.auth_kind) {
        .none => return .none,
        .bearer => {
            if (env.get("LLMCTL_API_KEY")) |v| if (v.len > 0) return .{ .bearer = v };
            if (prov.auth_env.len > 0) {
                if (env.get(prov.auth_env)) |v| if (v.len > 0) return .{ .bearer = v };
            }
            return .none;
        },
    }
}

// ────────────────────────────────────────────────────────────────────
// Per-model run
// ────────────────────────────────────────────────────────────────────

const RunSpec = struct {
    worker_id: u32,
    provider: ProviderConfig,
    auth: types.Auth,
    model: []const u8,
    messages: []const types.Message,
    system: ?[]const u8,
    args: cli.Args,
    output: cli.OutputFormat,
    mode: RunMode,
    stdout: *Io.Writer,
    stdout_mu: ?*anyopaque,
};

fn runOne(
    gpa: std.mem.Allocator,
    io: Io,
    arena: *std.heap.ArenaAllocator,
    spec: RunSpec,
) !WorkerResult {
    const arena_alloc = arena.allocator();
    const max_tok = spec.args.max_tokens orelse 4096;

    const want_stream = switch (spec.output) {
        .text, .json => true,
        .ndjson => true,
    };

    const req_opts = types.RequestOptions{
        .model = spec.model,
        .messages = spec.messages,
        .system = spec.system,
        .temperature = spec.args.temperature,
        .max_tokens = max_tok,
        .top_p = spec.args.top_p,
        .stream = want_stream,
        .extra = spec.args.extra,
    };

    const req = try dispatchBuild(arena_alloc, spec.provider, spec.auth, req_opts);

    var decoder = Decoder.init(spec.provider.compat, arena);
    defer decoder.deinit();

    const live_text = (spec.mode == .single_live) and spec.output == .text and !spec.args.buffer;

    var ctx = WorkerCtx{
        .arena = arena,
        .decoder = &decoder,
        .output = spec.output,
        .mode = spec.mode,
        .worker_id = spec.worker_id,
        .provider_name = spec.provider.name,
        .model = spec.model,
        .stdout = spec.stdout,
        .stdout_mu = spec.stdout_mu,
        .live_text_stream = live_text,
    };

    // ndjson: start event
    if (spec.output == .ndjson) {
        try writeNdjsonStart(spec.stdout, spec.provider.name, spec.model, spec.mode == .multi_ndjson, spec.worker_id);
        try spec.stdout.flush();
    }

    const start_ts = Io.Clock.awake.now(io);
    const result = http.stream(gpa, io, arena_alloc, .{
        .url = req.url,
        .body = req.body,
        .headers = req.headers,
        .on_chunk = onChunk,
        .ctx = @ptrCast(&ctx),
    }) catch |e| {
        const msg = try std.fmt.allocPrint(arena_alloc, "{s}", .{@errorName(e)});
        return .{
            .worker_id = spec.worker_id,
            .provider = spec.provider.name,
            .model = spec.model,
            .content = "",
            .usage = .{},
            .finish_reason = .unknown,
            .latency_ms = 0,
            .bytes_in = 0,
            .err = .{ .code = .network_error, .message = msg, .status = null },
        };
    };

    var tail: std.ArrayList(types.Delta) = .empty;
    defer tail.deinit(arena_alloc);
    try decoder.finalize(&tail);
    for (tail.items) |d| try emitDelta(&ctx, d);

    const latency_ns = start_ts.untilNow(io, .awake).nanoseconds;
    const latency_ms: i64 = @intCast(@divTrunc(latency_ns, std.time.ns_per_ms));

    if (result.status >= 400) {
        const extracted = try error_body.extractMessage(arena_alloc, result.error_body);
        const safe_msg = try redact.redact(arena_alloc, extracted);
        const code: types.ErrorCode = switch (result.status) {
            401, 403 => .provider_auth_failed,
            429 => .provider_rate_limited,
            404 => .unsupported,
            else => .provider_api_error,
        };
        return .{
            .worker_id = spec.worker_id,
            .provider = spec.provider.name,
            .model = spec.model,
            .content = "",
            .usage = .{},
            .finish_reason = .unknown,
            .latency_ms = latency_ms,
            .bytes_in = ctx.bytes_in,
            .err = .{ .code = code, .message = safe_msg, .status = result.status },
        };
    }

    return .{
        .worker_id = spec.worker_id,
        .provider = spec.provider.name,
        .model = spec.model,
        .content = ctx.collected.items,
        .usage = ctx.final_usage,
        .finish_reason = ctx.final_finish,
        .latency_ms = latency_ms,
        .bytes_in = ctx.bytes_in,
        .err = null,
    };
}

// ────────────────────────────────────────────────────────────────────
// REPL trampoline
// ────────────────────────────────────────────────────────────────────

const ReplTurnCtx = struct {
    gpa: std.mem.Allocator,
    io: Io,
    arena_alloc: std.mem.Allocator,
    provider: ProviderConfig,
    auth: types.Auth,
    args: cli.Args,
    stdout: *Io.Writer,
};

fn replRunTurn(
    ctx_opaque: *anyopaque,
    messages: []const types.Message,
    system_prompt: ?[]const u8,
    model: []const u8,
) anyerror!llmctl.repl.TurnResult {
    const ctx: *ReplTurnCtx = @ptrCast(@alignCast(ctx_opaque));
    var worker_arena = std.heap.ArenaAllocator.init(ctx.gpa);
    defer worker_arena.deinit();

    const r = try runOne(ctx.gpa, ctx.io, &worker_arena, .{
        .worker_id = 0,
        .provider = ctx.provider,
        .auth = ctx.auth,
        .model = model,
        .messages = messages,
        .system = system_prompt,
        .args = ctx.args,
        .output = .text,
        .mode = .single_live,
        .stdout = ctx.stdout,
        .stdout_mu = null,
    });

    return .{
        .content = try ctx.arena_alloc.dupe(u8, r.content),
        .usage = r.usage,
        .finish_reason = r.finish_reason,
        .err_message = if (r.err) |e| try ctx.arena_alloc.dupe(u8, e.message) else null,
    };
}

/// Copy a WorkerResult's heap-borrowed slices into `out_arena`. Caller's worker
/// arena can then be safely freed.
fn dupeWorkerResult(out_arena: std.mem.Allocator, r: WorkerResult) !WorkerResult {
    const content_owned = try out_arena.dupe(u8, r.content);
    const provider_owned = try out_arena.dupe(u8, r.provider);
    const model_owned = try out_arena.dupe(u8, r.model);
    const err_owned: ?ErrInfo = if (r.err) |e| .{
        .code = e.code,
        .message = try out_arena.dupe(u8, e.message),
        .status = e.status,
    } else null;
    return .{
        .worker_id = r.worker_id,
        .provider = provider_owned,
        .model = model_owned,
        .content = content_owned,
        .usage = r.usage,
        .finish_reason = r.finish_reason,
        .latency_ms = r.latency_ms,
        .bytes_in = r.bytes_in,
        .err = err_owned,
    };
}

// ────────────────────────────────────────────────────────────────────
// Main
// ────────────────────────────────────────────────────────────────────

pub fn main(init: std.process.Init) !void {
    const arena_alloc = init.arena.allocator();
    const gpa = init.gpa;
    const io = init.io;
    const env = init.environ_map;

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const stdout_w = &stdout_fw.interface;
    const stderr_w = &stderr_fw.interface;

    const argv = try init.minimal.args.toSlice(arena_alloc);

    // Early dispatch: `llmctl config <sub> [args...]` is a non-LLM subcommand.
    if (argv.len >= 2 and std.mem.eql(u8, argv[1], "config")) {
        const sub_args = argv[2..];
        const r = try config_cmd.run(arena_alloc, io, env, sub_args, stdout_w, stderr_w);
        try stdout_w.flush();
        try stderr_w.flush();
        if (r.exit_code != 0) std.process.exit(r.exit_code);
        return;
    }

    const args_parsed = cli.parse(arena_alloc, argv) catch |e| {
        try stderr_w.print("error: {s}\n", .{@errorName(e)});
        try stderr_w.flush();
        std.process.exit(types.ErrorCode.invalid_args.exitCode());
    };

    if (args_parsed.show_help) {
        try stdout_w.writeAll(cli.helpText());
        try stdout_w.flush();
        return;
    }
    if (args_parsed.show_version) {
        try stdout_w.print("llmctl {s}\n", .{version});
        try stdout_w.flush();
        return;
    }

    // ── Load defaults file and merge into args (CLI wins) ──
    const defaults_loaded = defaults_mod.load(arena_alloc, io, env) catch |e| blk: {
        try stderr_w.print("warn: defaults load failed: {s}\n", .{@errorName(e)});
        try stderr_w.flush();
        break :blk defaults_mod.Defaults{};
    };

    var args = args_parsed;
    if (args.provider == null) args.provider = defaults_loaded.provider;
    // base_url and model from defaults only apply when the active provider matches
    // defaults.provider — otherwise switching `--provider` would inherit the wrong URL.
    const provider_matches_defaults = blk: {
        if (defaults_loaded.provider == null) break :blk true;
        if (args.provider == null) break :blk true;
        break :blk std.mem.eql(u8, args.provider.?, defaults_loaded.provider.?);
    };
    if (provider_matches_defaults) {
        if (args.base_url == null) args.base_url = defaults_loaded.base_url;
        if (args.models.items.len == 0) {
            if (defaults_loaded.model) |m| try args.models.append(arena_alloc, m);
        }
    }
    if (args.system == null) args.system = defaults_loaded.system;
    if (args.max_tokens == null) args.max_tokens = defaults_loaded.max_tokens;
    if (args.temperature == null) args.temperature = defaults_loaded.temperature;
    if (args.top_p == null) args.top_p = defaults_loaded.top_p;

    // ── Resolve provider ──
    const provider_name = args.provider orelse "local";
    var prov = builtinProvider(provider_name) orelse {
        try stderr_w.print("error: unknown provider '{s}'\n", .{provider_name});
        try stderr_w.flush();
        std.process.exit(types.ErrorCode.invalid_args.exitCode());
    };
    if (args.base_url) |b| prov.base_url = b;
    if (prov.base_url.len == 0) {
        try stderr_w.print("error: provider '{s}' requires --base-url\n", .{provider_name});
        try stderr_w.flush();
        std.process.exit(types.ErrorCode.invalid_config.exitCode());
    }

    // ── Resolve models ──
    if (args.models.items.len == 0) {
        try stderr_w.writeAll("error: --model required (or set 'model = ...' in ~/.config/llmctl/defaults)\n");
        try stderr_w.flush();
        std.process.exit(types.ErrorCode.invalid_args.exitCode());
    }
    const n_models = args.models.items.len;

    // ── Session: reject multi-model with --session/--save-session ──
    if ((args.session != null or args.save_session != null) and n_models > 1) {
        try stderr_w.writeAll("error: --session/--save-session requires a single --model\n");
        try stderr_w.flush();
        std.process.exit(types.ErrorCode.invalid_args.exitCode());
    }

    // ── Load existing session (if requested) ──
    var session_state: llmctl.session.Session = .{};
    if (args.session) |sp| {
        session_state = llmctl.session.load(arena_alloc, io, sp) catch |e| {
            try stderr_w.print("error: session load: {s}\n", .{@errorName(e)});
            try stderr_w.flush();
            std.process.exit(types.ErrorCode.file_error.exitCode());
        };
        // If session has a system prompt and CLI didn't override, use session's.
        if (args.system == null and session_state.system != null) {
            args.system = session_state.system;
        }
    }

    // ── Resolve auth & prompt ──
    const auth = resolveAuth(env, prov);
    const sys_prompt = if (args.system) |s| try readSystemPrompt(arena_alloc, io, s) else null;

    // ── Interactive REPL ──
    if (args.interactive) {
        if (n_models > 1) {
            try stderr_w.writeAll("error: --interactive requires a single --model\n");
            try stderr_w.flush();
            std.process.exit(types.ErrorCode.invalid_args.exitCode());
        }
        var stdin_buf: [8192]u8 = undefined;
        var stdin_fr: Io.File.Reader = .init(.stdin(), io, &stdin_buf);
        const stdin_reader = &stdin_fr.interface;

        var turn_ctx = ReplTurnCtx{
            .gpa = gpa,
            .io = io,
            .arena_alloc = arena_alloc,
            .provider = prov,
            .auth = auth,
            .args = args,
            .stdout = stdout_w,
        };

        try llmctl.repl.run(.{
            .arena = init.arena,
            .io = io,
            .stdin = stdin_reader,
            .stdout = stdout_w,
            .stderr = stderr_w,
            .initial_model = args.models.items[0],
            .initial_system = sys_prompt,
            .initial_session = session_state,
            .auto_save_path = args.save_session orelse args.session,
            .provider_name = prov.name,
            .run_turn = replRunTurn,
            .run_turn_ctx = @ptrCast(&turn_ctx),
        });
        return;
    }

    const stdin_text = try readStdin(arena_alloc, io);
    const prompt = try buildPrompt(arena_alloc, args.prompt, stdin_text);

    if (prompt == null) {
        try stdout_w.writeAll(cli.helpText());
        try stdout_w.flush();
        return;
    }

    // ── Compose messages: prior session history + current user turn ──
    var msgs_list: std.ArrayList(types.Message) = .empty;
    for (session_state.messages.items) |sm| {
        const role: types.Role = if (std.mem.eql(u8, sm.role, "assistant")) .assistant else .user;
        const parts = try arena_alloc.alloc(types.ContentPart, 1);
        parts[0] = .{ .text = sm.content };
        try msgs_list.append(arena_alloc, .{ .role = role, .content = parts });
    }
    {
        const parts = try arena_alloc.alloc(types.ContentPart, 1);
        parts[0] = .{ .text = prompt.? };
        try msgs_list.append(arena_alloc, .{ .role = .user, .content = parts });
    }
    const messages = msgs_list.items;

    // ── --dry-run: print only the first model's request ──
    if (args.dry_run) {
        const req_opts = types.RequestOptions{
            .model = args.models.items[0],
            .messages = messages,
            .system = sys_prompt,
            .temperature = args.temperature,
            .max_tokens = args.max_tokens orelse 4096,
            .top_p = args.top_p,
            .stream = true,
            .extra = args.extra,
        };
        const req = try dispatchBuild(arena_alloc, prov, auth, req_opts);
        try stdout_w.print("POST {s}\n", .{req.url});
        for (req.headers) |h| {
            const safe = try redact.redact(arena_alloc, h.value);
            try stdout_w.print("{s}: {s}\n", .{ h.name, safe });
        }
        try stdout_w.writeAll("\n");
        try stdout_w.writeAll(req.body);
        try stdout_w.writeAll("\n");
        try stdout_w.flush();
        return;
    }

    if (args.verbose) {
        try stderr_w.print("» provider: {s}\n", .{prov.name});
        try stderr_w.print("» url:      {s}\n", .{prov.base_url});
        try stderr_w.print("» models:   {d}\n", .{n_models});
        try stderr_w.flush();
    }

    // ── Determine run mode ──
    const mode: RunMode = if (n_models == 1) .single_live else if (args.output == .ndjson) .multi_ndjson else .multi_buffered;

    var results: std.ArrayList(WorkerResult) = .empty;

    if (n_models == 1) {
        // ── Single-model fast path: live streaming directly to stdout ──
        var worker_arena = std.heap.ArenaAllocator.init(gpa);
        defer worker_arena.deinit();
        const model = args.models.items[0];

        const r = try runOne(gpa, io, &worker_arena, .{
            .worker_id = 0,
            .provider = prov,
            .auth = auth,
            .model = model,
            .messages = messages,
            .system = sys_prompt,
            .args = args,
            .output = args.output,
            .mode = mode,
            .stdout = stdout_w,
            .stdout_mu = null,
        });

        const r_owned = try dupeWorkerResult(arena_alloc, r);
        try results.append(arena_alloc, r_owned);

        if (args.verbose) {
            try stderr_w.print("» [{s}] latency: {} ms · in={} out={} · finish={s}\n", .{
                model,
                r.latency_ms,
                r.usage.input_tokens,
                r.usage.output_tokens,
                r.finish_reason.toString(),
            });
            try stderr_w.flush();
        }
    } else {
        // ── Multi-model concurrent path ──
        const ThreadCtx = struct {
            spec: RunSpec,
            gpa_alloc: std.mem.Allocator,
            io_inst: Io,
            arena: *std.heap.ArenaAllocator,
            sink_alloc: *std.Io.Writer.Allocating,
            result: ?WorkerResult = null,
            spawn_err: ?anyerror = null,

            fn run(tc: *@This()) void {
                const r = runOne(tc.gpa_alloc, tc.io_inst, tc.arena, tc.spec) catch |e| {
                    tc.spawn_err = e;
                    return;
                };
                tc.result = r;
            }
        };

        const ctxs = try arena_alloc.alloc(ThreadCtx, n_models);
        const arenas = try arena_alloc.alloc(std.heap.ArenaAllocator, n_models);
        const sinks = try arena_alloc.alloc(std.Io.Writer.Allocating, n_models);
        const threads = try arena_alloc.alloc(std.Thread, n_models);

        var k: u32 = 0;
        while (k < n_models) : (k += 1) {
            arenas[k] = std.heap.ArenaAllocator.init(gpa);
            sinks[k] = std.Io.Writer.Allocating.init(arenas[k].allocator());
            ctxs[k] = .{
                .gpa_alloc = gpa,
                .io_inst = io,
                .arena = &arenas[k],
                .sink_alloc = &sinks[k],
                .spec = .{
                    .worker_id = k,
                    .provider = prov,
                    .auth = auth,
                    .model = args.models.items[k],
                    .messages = messages,
                    .system = sys_prompt,
                    .args = args,
                    .output = args.output,
                    .mode = mode,
                    .stdout = &sinks[k].writer, // per-worker buffer, not real stdout
                    .stdout_mu = null,
                },
            };
            threads[k] = try std.Thread.spawn(.{}, ThreadCtx.run, .{&ctxs[k]});
        }

        // Wait for all workers, then emit in worker_id order.
        k = 0;
        while (k < n_models) : (k += 1) {
            threads[k].join();
        }

        k = 0;
        while (k < n_models) : (k += 1) {
            const tc = &ctxs[k];
            if (tc.spawn_err) |e| {
                try stderr_w.print("error: worker {} panicked: {s}\n", .{ k, @errorName(e) });
                try stderr_w.flush();
                continue;
            }
            const r = tc.result.?;
            const r_owned = try dupeWorkerResult(arena_alloc, r);
            try results.append(arena_alloc, r_owned);

            if (mode == .multi_buffered and args.output == .text) {
                try stdout_w.print("── {s}/{s} ──\n", .{ prov.name, args.models.items[k] });
                if (r.err) |e| {
                    try stdout_w.print("(error: {s})\n", .{e.message});
                } else {
                    try stdout_w.writeAll(r_owned.content);
                    if (r_owned.content.len == 0 or r_owned.content[r_owned.content.len - 1] != '\n') {
                        try stdout_w.writeAll("\n");
                    }
                }
                try stdout_w.flush();
            } else if (mode == .multi_ndjson) {
                // Dump per-worker ndjson lines.
                try stdout_w.writeAll(sinks[k].written());
                try stdout_w.flush();
            }

            if (args.verbose) {
                try stderr_w.print("» [{s}] latency: {} ms · in={} out={} · finish={s}\n", .{
                    args.models.items[k],
                    r.latency_ms,
                    r.usage.input_tokens,
                    r.usage.output_tokens,
                    r.finish_reason.toString(),
                });
                try stderr_w.flush();
            }
        }

        // Free per-worker arenas. Result content was duped out via dupeWorkerResult above.
        k = 0;
        while (k < n_models) : (k += 1) {
            arenas[k].deinit();
        }
    }

    // ── Final output dispatch ──
    var any_err = false;
    var worst_code: types.ErrorCode = .internal;
    var worst_set = false;
    for (results.items) |r| if (r.err) |e| {
        any_err = true;
        if (!worst_set or e.code.exitCode() > worst_code.exitCode()) {
            worst_code = e.code;
            worst_set = true;
        }
    };

    switch (args.output) {
        .text => {
            if (mode == .single_live) {
                const r = results.items[0];
                if (r.err) |e| {
                    try stderr_w.print("error: HTTP {?} {s}: {s}\n", .{ e.status, e.code.toString(), e.message });
                    try stderr_w.flush();
                } else {
                    if (args.buffer) {
                        try stdout_w.writeAll(r.content);
                    }
                    try stdout_w.writeAll("\n");
                    try stdout_w.flush();
                }
            }
            // multi_buffered already printed inside the loop.
        },
        .json => {
            if (n_models == 1) {
                try writeJsonSingle(stdout_w, results.items[0]);
            } else {
                try writeJsonMulti(stdout_w, results.items);
            }
            try stdout_w.flush();
        },
        .ndjson => {
            try writeNdjsonEnd(stdout_w, !any_err);
            try stdout_w.flush();
        },
    }

    // ── Persist session ──
    // --session implies save-back to same path; --save-session forks/specifies an explicit target.
    const save_path: ?[]const u8 = args.save_session orelse args.session;
    if (save_path) |sp| if (!any_err and results.items.len > 0) {
        const r = results.items[0];
        // Append the new user turn + assistant reply to the loaded history.
        try session_state.messages.append(arena_alloc, .{
            .role = "user",
            .content = try arena_alloc.dupe(u8, prompt.?),
        });
        try session_state.messages.append(arena_alloc, .{
            .role = "assistant",
            .content = try arena_alloc.dupe(u8, r.content),
        });
        session_state.provider = prov.name;
        session_state.model = r.model;
        if (sys_prompt) |s| session_state.system = s;
        session_state.total_input_tokens += r.usage.input_tokens;
        session_state.total_output_tokens += r.usage.output_tokens;
        session_state.version = llmctl.session.SCHEMA_VERSION;
        llmctl.session.save(arena_alloc, io, sp, session_state) catch |e| {
            try stderr_w.print("warn: session save failed: {s}\n", .{@errorName(e)});
            try stderr_w.flush();
        };
    };

    if (worst_set) std.process.exit(worst_code.exitCode());
}
