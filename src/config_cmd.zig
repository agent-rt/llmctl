//! `llmctl config <get|set|unset|list|path>` subcommand.
//!
//! Reads/writes the same `key=value` defaults file that `defaults.zig` parses.
//! Set/unset preserve comments and blank lines and write atomically via tmp+rename.
const std = @import("std");
const Io = std.Io;
const defaults_mod = @import("defaults.zig");

pub const known_keys = [_][]const u8{
    "provider", "model", "base_url", "system", "max_tokens", "temperature", "top_p",
};

pub const Error = error{
    UnknownSubcommand,
    MissingArg,
    UnknownKey,
    EmptyValue,
};

fn isKnownKey(key: []const u8) bool {
    for (known_keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

/// Resolve the path to write defaults to. Order:
///   1. $LLMCTL_DEFAULTS
///   2. $XDG_CONFIG_HOME/llmctl/defaults
///   3. ~/.config/llmctl/defaults
fn resolveWritePath(arena: std.mem.Allocator, env: *std.process.Environ.Map) !?[]const u8 {
    if (env.get("LLMCTL_DEFAULTS")) |v| if (v.len > 0) return try arena.dupe(u8, v);
    if (env.get("XDG_CONFIG_HOME")) |xdg| if (xdg.len > 0) {
        return try std.fmt.allocPrint(arena, "{s}/llmctl/defaults", .{xdg});
    };
    const home = env.get("HOME") orelse return null;
    return try std.fmt.allocPrint(arena, "{s}/.config/llmctl/defaults", .{home});
}

fn parentDir(path: []const u8) []const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, path, '/') orelse return ".";
    if (idx == 0) return "/";
    return path[0..idx];
}

fn readAll(arena: std.mem.Allocator, io: Io, path: []const u8) !?[]const u8 {
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };
    defer file.close(io);
    var read_buf: [8192]u8 = undefined;
    var fr: Io.File.Reader = .init(file, io, &read_buf);
    var collected: std.ArrayList(u8) = .empty;
    while (true) {
        const n = try fr.interface.readSliceShort(&read_buf);
        if (n == 0) break;
        try collected.appendSlice(arena, read_buf[0..n]);
    }
    return try collected.toOwnedSlice(arena);
}

fn writeAtomic(arena: std.mem.Allocator, io: Io, path: []const u8, contents: []const u8) !void {
    const cwd = Io.Dir.cwd();
    const dir = parentDir(path);
    // mkdir -p; ignore "exists" / "not a dir" (e.g. /tmp symlink on macOS).
    cwd.createDirPath(io, dir) catch {};
    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    const tmp = try cwd.createFile(io, tmp_path, .{ .truncate = true });
    {
        defer tmp.close(io);
        var write_buf: [4096]u8 = undefined;
        var fw: Io.File.Writer = .init(tmp, io, &write_buf);
        try fw.interface.writeAll(contents);
        try fw.interface.flush();
    }
    try cwd.rename(tmp_path, cwd, path, io);
}

fn lineKey(line: []const u8) ?[]const u8 {
    const stripped = std.mem.trim(u8, line, " \t\r");
    if (stripped.len == 0 or stripped[0] == '#') return null;
    const eq = std.mem.indexOfScalar(u8, stripped, '=') orelse return null;
    return std.mem.trim(u8, stripped[0..eq], " \t\r");
}

/// Replace the value for `key` in `existing` (preserving order/comments), or append a new
/// `key = value` line. Returns an arena-allocated string.
fn editSet(arena: std.mem.Allocator, existing: []const u8, key: []const u8, value: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var found = false;
    var iter = std.mem.splitScalar(u8, existing, '\n');
    var first_line = true;
    while (iter.next()) |line| {
        if (!first_line) try out.append(arena, '\n');
        first_line = false;
        const lk = lineKey(line);
        if (lk != null and std.mem.eql(u8, lk.?, key)) {
            found = true;
            const replacement = try std.fmt.allocPrint(arena, "{s} = {s}", .{ key, value });
            try out.appendSlice(arena, replacement);
        } else {
            try out.appendSlice(arena, line);
        }
    }
    if (!found) {
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(arena, '\n');
        const appended = try std.fmt.allocPrint(arena, "{s} = {s}\n", .{ key, value });
        try out.appendSlice(arena, appended);
    }
    return out.toOwnedSlice(arena);
}

/// Drop any line that defines `key`. Returns null if nothing changed.
fn editUnset(arena: std.mem.Allocator, existing: []const u8, key: []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var iter = std.mem.splitScalar(u8, existing, '\n');
    var first = true;
    var changed = false;
    while (iter.next()) |line| {
        const lk = lineKey(line);
        if (lk != null and std.mem.eql(u8, lk.?, key)) {
            changed = true;
            continue;
        }
        if (!first) try out.append(arena, '\n');
        first = false;
        try out.appendSlice(arena, line);
    }
    if (!changed) return null;
    return try out.toOwnedSlice(arena);
}

pub const RunResult = struct { exit_code: u8 };

pub fn run(
    arena: std.mem.Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    sub_args: []const []const u8,
    stdout: *Io.Writer,
    stderr: *Io.Writer,
) !RunResult {
    if (sub_args.len == 0) {
        try stderr.writeAll("error: missing config subcommand. Try: list | get <k> | set <k> <v> | unset <k> | path\n");
        return .{ .exit_code = 2 };
    }

    const sub = sub_args[0];

    if (std.mem.eql(u8, sub, "path")) {
        const path = (try resolveWritePath(arena, env)) orelse {
            try stderr.writeAll("error: cannot resolve config path (HOME/XDG_CONFIG_HOME/LLMCTL_DEFAULTS all unset)\n");
            return .{ .exit_code = 1 };
        };
        try stdout.print("{s}\n", .{path});
        return .{ .exit_code = 0 };
    }

    if (std.mem.eql(u8, sub, "list")) {
        const d = defaults_mod.load(arena, io, env) catch |e| {
            try stderr.print("error: load failed: {s}\n", .{@errorName(e)});
            return .{ .exit_code = 1 };
        };
        if (d.provider) |v| try stdout.print("provider = {s}\n", .{v});
        if (d.model) |v| try stdout.print("model = {s}\n", .{v});
        if (d.base_url) |v| try stdout.print("base_url = {s}\n", .{v});
        if (d.system) |v| try stdout.print("system = {s}\n", .{v});
        if (d.max_tokens) |v| try stdout.print("max_tokens = {d}\n", .{v});
        if (d.temperature) |v| try stdout.print("temperature = {d}\n", .{v});
        if (d.top_p) |v| try stdout.print("top_p = {d}\n", .{v});
        return .{ .exit_code = 0 };
    }

    if (std.mem.eql(u8, sub, "get")) {
        if (sub_args.len < 2) {
            try stderr.writeAll("error: config get <key>\n");
            return .{ .exit_code = 2 };
        }
        const key = sub_args[1];
        if (!isKnownKey(key)) {
            try stderr.print("error: unknown key '{s}'. Known: provider, model, base_url, system, max_tokens, temperature, top_p\n", .{key});
            return .{ .exit_code = 2 };
        }
        const d = try defaults_mod.load(arena, io, env);
        if (std.mem.eql(u8, key, "provider")) {
            if (d.provider) |v| try stdout.print("{s}\n", .{v});
        } else if (std.mem.eql(u8, key, "model")) {
            if (d.model) |v| try stdout.print("{s}\n", .{v});
        } else if (std.mem.eql(u8, key, "base_url")) {
            if (d.base_url) |v| try stdout.print("{s}\n", .{v});
        } else if (std.mem.eql(u8, key, "system")) {
            if (d.system) |v| try stdout.print("{s}\n", .{v});
        } else if (std.mem.eql(u8, key, "max_tokens")) {
            if (d.max_tokens) |v| try stdout.print("{d}\n", .{v});
        } else if (std.mem.eql(u8, key, "temperature")) {
            if (d.temperature) |v| try stdout.print("{d}\n", .{v});
        } else if (std.mem.eql(u8, key, "top_p")) {
            if (d.top_p) |v| try stdout.print("{d}\n", .{v});
        }
        return .{ .exit_code = 0 };
    }

    if (std.mem.eql(u8, sub, "set")) {
        if (sub_args.len < 3) {
            try stderr.writeAll("error: config set <key> <value>\n");
            return .{ .exit_code = 2 };
        }
        const key = sub_args[1];
        const value = sub_args[2];
        if (!isKnownKey(key)) {
            try stderr.print("error: unknown key '{s}'\n", .{key});
            return .{ .exit_code = 2 };
        }
        if (value.len == 0) {
            try stderr.writeAll("error: empty value (use 'config unset' to remove)\n");
            return .{ .exit_code = 2 };
        }
        const path = (try resolveWritePath(arena, env)) orelse {
            try stderr.writeAll("error: cannot resolve config path\n");
            return .{ .exit_code = 1 };
        };
        const existing = (try readAll(arena, io, path)) orelse "";
        const updated = try editSet(arena, existing, key, value);
        try writeAtomic(arena, io, path, updated);
        try stdout.print("{s} = {s}\n", .{ key, value });
        return .{ .exit_code = 0 };
    }

    if (std.mem.eql(u8, sub, "unset")) {
        if (sub_args.len < 2) {
            try stderr.writeAll("error: config unset <key>\n");
            return .{ .exit_code = 2 };
        }
        const key = sub_args[1];
        if (!isKnownKey(key)) {
            try stderr.print("error: unknown key '{s}'\n", .{key});
            return .{ .exit_code = 2 };
        }
        const path = (try resolveWritePath(arena, env)) orelse {
            try stderr.writeAll("error: cannot resolve config path\n");
            return .{ .exit_code = 1 };
        };
        const existing = (try readAll(arena, io, path)) orelse {
            return .{ .exit_code = 0 };
        };
        const updated = (try editUnset(arena, existing, key)) orelse {
            return .{ .exit_code = 0 };
        };
        try writeAtomic(arena, io, path, updated);
        return .{ .exit_code = 0 };
    }

    try stderr.print("error: unknown config subcommand '{s}'\n", .{sub});
    return .{ .exit_code = 2 };
}

const testing = std.testing;

test "editSet: updates existing key, preserves comments" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\# llmctl defaults
        \\provider = local
        \\model = gemma
        \\
        \\# end
    ;
    const out = try editSet(a, input, "model", "qwen3");
    try testing.expect(std.mem.indexOf(u8, out, "model = qwen3") != null);
    try testing.expect(std.mem.indexOf(u8, out, "# llmctl defaults") != null);
    try testing.expect(std.mem.indexOf(u8, out, "# end") != null);
    try testing.expect(std.mem.indexOf(u8, out, "provider = local") != null);
    // Old value should be replaced, not duplicated.
    try testing.expect(std.mem.indexOf(u8, out, "model = gemma") == null);
}

test "editSet: appends new key to empty content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try editSet(a, "", "provider", "openai");
    try testing.expectEqualStrings("provider = openai\n", out);
}

test "editSet: appends when key not present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input = "provider = local\n";
    const out = try editSet(a, input, "model", "gemma");
    try testing.expect(std.mem.indexOf(u8, out, "provider = local") != null);
    try testing.expect(std.mem.indexOf(u8, out, "model = gemma") != null);
}

test "editUnset: removes matching line" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const input =
        \\provider = local
        \\model = gemma
        \\max_tokens = 2048
    ;
    const out = (try editUnset(a, input, "model")).?;
    try testing.expect(std.mem.indexOf(u8, out, "model") == null);
    try testing.expect(std.mem.indexOf(u8, out, "provider = local") != null);
    try testing.expect(std.mem.indexOf(u8, out, "max_tokens = 2048") != null);
}

test "editUnset: returns null when key not present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try editUnset(a, "provider = local\n", "model");
    try testing.expect(out == null);
}

test "isKnownKey" {
    try testing.expect(isKnownKey("provider"));
    try testing.expect(isKnownKey("max_tokens"));
    try testing.expect(!isKnownKey("frobnicator"));
}
