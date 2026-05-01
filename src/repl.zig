//! Interactive REPL for multi-turn debugging.
//! Slash commands: /help /exit /quit /q /clear /system /model /save /load /tokens /verbose /dry-run
//!
//! Designed to layer on top of the same single-model run path as one-shot mode,
//! so `/system` and `/model` mid-session are just state mutations between turns.
const std = @import("std");
const Io = std.Io;
const types = @import("types.zig");
const session = @import("session.zig");

const Allocator = std.mem.Allocator;

/// Trampoline interface: REPL doesn't know about main's runOne signature.
/// Caller passes a function that runs one turn and returns the assistant's content.
pub const RunTurnFn = *const fn (
    ctx: *anyopaque,
    messages: []const types.Message,
    system_prompt: ?[]const u8,
    model: []const u8,
) anyerror!TurnResult;

pub const TurnResult = struct {
    content: []const u8,
    usage: types.Usage,
    finish_reason: types.FinishReason,
    err_message: ?[]const u8 = null,
};

pub const ReplOptions = struct {
    arena: *std.heap.ArenaAllocator,
    io: Io,
    stdin: *Io.Reader,
    stdout: *Io.Writer,
    stderr: *Io.Writer,

    /// Initial state.
    initial_model: []const u8,
    initial_system: ?[]const u8,
    initial_session: session.Session = .{},

    /// Auto-save path, if --save-session was passed.
    auto_save_path: ?[]const u8,

    /// Provider name (display only).
    provider_name: []const u8,

    /// Caller-supplied turn runner.
    run_turn: RunTurnFn,
    run_turn_ctx: *anyopaque,
    /// Callback to update the model selection (e.g. validate against caller's allowed list).
    /// Returns false if model name unknown/invalid.
    set_model_ok: ?*const fn (ctx: *anyopaque, model: []const u8) bool = null,
};

pub fn run(opts: ReplOptions) !void {
    const out = opts.stdout;
    const err = opts.stderr;
    const arena = opts.arena.allocator();

    // Mutable state that evolves across turns.
    var sess = opts.initial_session;
    var current_model: []const u8 = try arena.dupe(u8, opts.initial_model);
    var current_system: ?[]const u8 = if (opts.initial_system) |s| try arena.dupe(u8, s) else null;

    try out.print("llmctl interactive — provider: {s}, model: {s}\n", .{ opts.provider_name, current_model });
    try out.writeAll("type /help for commands, /exit or Ctrl+D to quit\n\n");
    try out.flush();

    var line_buf: std.ArrayList(u8) = .empty;
    defer line_buf.deinit(arena);

    while (true) {
        try out.writeAll(">>> ");
        try out.flush();

        // Read a line from stdin.
        line_buf.clearRetainingCapacity();
        const got = readLine(arena, opts.stdin, &line_buf) catch |e| switch (e) {
            error.EndOfStream => {
                try out.writeAll("\n");
                try out.flush();
                break;
            },
            else => return e,
        };
        if (!got) {
            // EOF
            try out.writeAll("\n");
            try out.flush();
            break;
        }

        const input = std.mem.trim(u8, line_buf.items, " \t\r");
        if (input.len == 0) continue;

        // ── Slash commands ──
        if (input[0] == '/') {
            const stop = try handleCommand(input, .{
                .arena = arena,
                .io = opts.io,
                .out = out,
                .err = err,
                .session = &sess,
                .auto_save_path = opts.auto_save_path,
                .current_model = &current_model,
                .current_system = &current_system,
                .provider_name = opts.provider_name,
                .set_model_ok = opts.set_model_ok,
                .set_model_ctx = opts.run_turn_ctx,
            });
            if (stop) break;
            continue;
        }

        // ── Regular turn ──
        // Compose messages: prior history + this user input.
        var msgs: std.ArrayList(types.Message) = .empty;
        for (sess.messages.items) |m| {
            const role: types.Role = if (std.mem.eql(u8, m.role, "assistant")) .assistant else .user;
            const parts = try arena.alloc(types.ContentPart, 1);
            parts[0] = .{ .text = m.content };
            try msgs.append(arena, .{ .role = role, .content = parts });
        }
        const user_text_owned = try arena.dupe(u8, input);
        {
            const parts = try arena.alloc(types.ContentPart, 1);
            parts[0] = .{ .text = user_text_owned };
            try msgs.append(arena, .{ .role = .user, .content = parts });
        }

        const result = opts.run_turn(opts.run_turn_ctx, msgs.items, current_system, current_model) catch |e| {
            try err.print("error: {s}\n", .{@errorName(e)});
            try err.flush();
            continue;
        };

        // Newline after streamed response, before next prompt.
        try out.writeAll("\n\n");
        try out.flush();

        if (result.err_message) |em| {
            try err.print("error: {s}\n", .{em});
            try err.flush();
            continue;
        }

        // Append turn to session history.
        try sess.messages.append(arena, .{ .role = "user", .content = user_text_owned });
        try sess.messages.append(arena, .{ .role = "assistant", .content = try arena.dupe(u8, result.content) });
        sess.total_input_tokens += result.usage.input_tokens;
        sess.total_output_tokens += result.usage.output_tokens;
        sess.provider = opts.provider_name;
        sess.model = current_model;
        if (current_system) |s| sess.system = s;
        sess.version = session.SCHEMA_VERSION;

        // Auto-save if path provided.
        if (opts.auto_save_path) |sp| {
            session.save(arena, opts.io, sp, sess) catch |e| {
                try err.print("warn: auto-save failed: {s}\n", .{@errorName(e)});
                try err.flush();
            };
        }
    }

    try out.writeAll("bye!\n");
    try out.flush();
}

fn readLine(arena: Allocator, r: *Io.Reader, out: *std.ArrayList(u8)) !bool {
    // takeDelimiterInclusive returns the slice including '\n' AND advances past it.
    // (takeDelimiterExclusive omits the delimiter from the slice but doesn't consume it,
    // which would loop forever.)
    while (true) {
        const slice = r.takeDelimiterInclusive('\n') catch |e| switch (e) {
            error.EndOfStream => {
                // EOF: take whatever's buffered as a final unterminated line.
                const buf = r.buffered();
                if (buf.len == 0 and out.items.len == 0) return false;
                if (buf.len > 0) {
                    try out.appendSlice(arena, buf);
                    r.tossBuffered();
                }
                return out.items.len > 0;
            },
            error.StreamTooLong => {
                const buf = r.buffered();
                try out.appendSlice(arena, buf);
                r.tossBuffered();
                continue;
            },
            else => return e,
        };
        // Strip trailing \n.
        const line = if (slice.len > 0 and slice[slice.len - 1] == '\n') slice[0 .. slice.len - 1] else slice;
        try out.appendSlice(arena, line);
        return true;
    }
}

const CmdCtx = struct {
    arena: Allocator,
    io: Io,
    out: *Io.Writer,
    err: *Io.Writer,
    session: *session.Session,
    auto_save_path: ?[]const u8,
    current_model: *[]const u8,
    current_system: *?[]const u8,
    provider_name: []const u8,
    set_model_ok: ?*const fn (ctx: *anyopaque, model: []const u8) bool,
    set_model_ctx: *anyopaque,
};

/// Returns true if the REPL should exit.
fn handleCommand(input: []const u8, c: CmdCtx) !bool {
    const space = std.mem.indexOfScalar(u8, input, ' ');
    const cmd = if (space) |s| input[0..s] else input;
    const rest_raw = if (space) |s| input[s + 1 ..] else "";
    const rest = std.mem.trim(u8, rest_raw, " \t");

    if (std.mem.eql(u8, cmd, "/exit") or std.mem.eql(u8, cmd, "/quit") or std.mem.eql(u8, cmd, "/q")) {
        return true;
    } else if (std.mem.eql(u8, cmd, "/help") or std.mem.eql(u8, cmd, "/?")) {
        try c.out.writeAll(
            \\Commands:
            \\  /help                    show this help
            \\  /exit, /quit, /q         leave the REPL
            \\  /clear                   clear conversation history (keep system)
            \\  /system [<text>]         show or set system prompt
            \\  /model [<name>]          show or switch model
            \\  /tokens                  show accumulated token usage
            \\  /save <path>             save session to JSON
            \\  /load <path>             load session, replacing current history
            \\  /history                 list current messages
            \\  /info                    show provider/model/auto-save status
            \\
        );
        try c.out.flush();
    } else if (std.mem.eql(u8, cmd, "/clear")) {
        c.session.messages.clearRetainingCapacity();
        c.session.total_input_tokens = 0;
        c.session.total_output_tokens = 0;
        try c.out.writeAll("history cleared.\n");
        try c.out.flush();
    } else if (std.mem.eql(u8, cmd, "/system")) {
        if (rest.len == 0) {
            if (c.current_system.*) |s| {
                try c.out.print("system: {s}\n", .{s});
            } else {
                try c.out.writeAll("system: (none)\n");
            }
            try c.out.flush();
        } else {
            c.current_system.* = try c.arena.dupe(u8, rest);
            try c.out.writeAll("system prompt updated.\n");
            try c.out.flush();
        }
    } else if (std.mem.eql(u8, cmd, "/model")) {
        if (rest.len == 0) {
            try c.out.print("model: {s}\n", .{c.current_model.*});
            try c.out.flush();
        } else {
            const dup = try c.arena.dupe(u8, rest);
            if (c.set_model_ok) |fp| {
                if (!fp(c.set_model_ctx, dup)) {
                    try c.err.print("warn: model '{s}' not validated; using anyway\n", .{dup});
                    try c.err.flush();
                }
            }
            c.current_model.* = dup;
            try c.out.print("model: {s}\n", .{dup});
            try c.out.flush();
        }
    } else if (std.mem.eql(u8, cmd, "/tokens")) {
        try c.out.print("input: {} · output: {} · total: {}\n", .{
            c.session.total_input_tokens,
            c.session.total_output_tokens,
            c.session.total_input_tokens + c.session.total_output_tokens,
        });
        try c.out.flush();
    } else if (std.mem.eql(u8, cmd, "/save")) {
        const path = if (rest.len > 0) rest else c.auto_save_path orelse {
            try c.err.writeAll("usage: /save <path>\n");
            try c.err.flush();
            return false;
        };
        c.session.provider = c.provider_name;
        c.session.model = c.current_model.*;
        if (c.current_system.*) |s| c.session.system = s;
        c.session.version = session.SCHEMA_VERSION;
        session.save(c.arena, c.io, path, c.session.*) catch |e| {
            try c.err.print("save failed: {s}\n", .{@errorName(e)});
            try c.err.flush();
            return false;
        };
        try c.out.print("saved to {s}\n", .{path});
        try c.out.flush();
    } else if (std.mem.eql(u8, cmd, "/load")) {
        if (rest.len == 0) {
            try c.err.writeAll("usage: /load <path>\n");
            try c.err.flush();
            return false;
        }
        const loaded = session.load(c.arena, c.io, rest) catch |e| {
            try c.err.print("load failed: {s}\n", .{@errorName(e)});
            try c.err.flush();
            return false;
        };
        c.session.* = loaded;
        if (loaded.model) |m| c.current_model.* = m;
        if (loaded.system) |s| c.current_system.* = s;
        try c.out.print("loaded {s} ({} messages)\n", .{ rest, c.session.messages.items.len });
        try c.out.flush();
    } else if (std.mem.eql(u8, cmd, "/history")) {
        for (c.session.messages.items, 0..) |m, idx| {
            try c.out.print("[{d}] {s}: {s}\n", .{ idx, m.role, m.content });
        }
        try c.out.flush();
    } else if (std.mem.eql(u8, cmd, "/info")) {
        try c.out.print("provider:  {s}\nmodel:     {s}\nsystem:    {s}\nauto-save: {s}\nmessages:  {}\n", .{
            c.provider_name,
            c.current_model.*,
            if (c.current_system.*) |s| s else "(none)",
            if (c.auto_save_path) |p| p else "(off)",
            c.session.messages.items.len,
        });
        try c.out.flush();
    } else {
        try c.err.print("unknown command: {s}  (try /help)\n", .{cmd});
        try c.err.flush();
    }
    return false;
}
