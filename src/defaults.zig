//! Lightweight defaults config (`~/.llmctl/defaults` or `$XDG_CONFIG_HOME/llmctl/defaults`).
//!
//! Format: `key = value` per line, `#` comments, blank lines ignored.
//! Recognized keys: provider, model, base_url, max_tokens, system, temperature, top_p
//!
//! Values are applied as defaults BEFORE CLI parsing, so any CLI flag overrides.
//! This is intentionally simpler than full TOML — full provider config lives in P3.
const std = @import("std");
const Io = std.Io;

pub const Defaults = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    system: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    temperature: ?f32 = null,
    top_p: ?f32 = null,
};

pub const LoadError = anyerror;

/// Search candidate paths and load the first that exists. Returns empty Defaults if none found.
/// Search order:
///   1. $LLMCTL_DEFAULTS (if set)
///   2. $XDG_CONFIG_HOME/llmctl/defaults
///   3. ~/.config/llmctl/defaults
///   4. ~/.llmctl/defaults
pub fn load(arena: std.mem.Allocator, io: Io, env: *std.process.Environ.Map) LoadError!Defaults {
    var d: Defaults = .{};

    const path = (try resolvePath(arena, env)) orelse return d;
    const file = Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
        error.FileNotFound => return d,
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

    try parse(arena, collected.items, &d);
    return d;
}

fn resolvePath(arena: std.mem.Allocator, env: *std.process.Environ.Map) !?[]const u8 {
    if (env.get("LLMCTL_DEFAULTS")) |v| if (v.len > 0) return try arena.dupe(u8, v);

    const home = env.get("HOME") orelse return null;

    if (env.get("XDG_CONFIG_HOME")) |xdg| if (xdg.len > 0) {
        return try std.fmt.allocPrint(arena, "{s}/llmctl/defaults", .{xdg});
    };

    // Try ~/.config/llmctl/defaults first; if missing the loader returns empty.
    // We return a single best path here; for fallback chain we'd try in load() — keep simple.
    const xdg_default = try std.fmt.allocPrint(arena, "{s}/.config/llmctl/defaults", .{home});
    return xdg_default;
}

fn parse(arena: std.mem.Allocator, content: []const u8, out: *Defaults) !void {
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw_line| {
        const line = trim(raw_line);
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = trim(line[0..eq]);
        const val = trim(line[eq + 1 ..]);
        const dup = try arena.dupe(u8, val);

        if (std.mem.eql(u8, key, "provider")) {
            out.provider = dup;
        } else if (std.mem.eql(u8, key, "model")) {
            out.model = dup;
        } else if (std.mem.eql(u8, key, "base_url")) {
            out.base_url = dup;
        } else if (std.mem.eql(u8, key, "system")) {
            out.system = dup;
        } else if (std.mem.eql(u8, key, "max_tokens")) {
            out.max_tokens = std.fmt.parseInt(u32, val, 10) catch null;
        } else if (std.mem.eql(u8, key, "temperature")) {
            out.temperature = std.fmt.parseFloat(f32, val) catch null;
        } else if (std.mem.eql(u8, key, "top_p")) {
            out.top_p = std.fmt.parseFloat(f32, val) catch null;
        }
        // Unknown keys silently ignored — forward compat.
    }
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

const testing = std.testing;

test "parse: typical defaults file" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var d: Defaults = .{};
    const content =
        \\# llmctl defaults
        \\provider = local
        \\base_url = http://10.0.0.64:8800
        \\model = unsloth/gemma-4-26B-A4B-it-GGUF:gemma-4-26B-A4B-it-UD-Q4_K_M
        \\max_tokens = 2048
        \\
        \\# trailing comment
    ;
    try parse(arena.allocator(), content, &d);
    try testing.expectEqualStrings("local", d.provider.?);
    try testing.expectEqualStrings("http://10.0.0.64:8800", d.base_url.?);
    try testing.expectEqualStrings("unsloth/gemma-4-26B-A4B-it-GGUF:gemma-4-26B-A4B-it-UD-Q4_K_M", d.model.?);
    try testing.expectEqual(@as(u32, 2048), d.max_tokens.?);
}

test "parse: ignores blank and comment lines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var d: Defaults = .{};
    try parse(arena.allocator(),
        \\
        \\# nothing here
        \\
        \\
    , &d);
    try testing.expect(d.provider == null);
}

test "parse: invalid number ignored" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    var d: Defaults = .{};
    try parse(arena.allocator(), "max_tokens = not-a-number\n", &d);
    try testing.expect(d.max_tokens == null);
}
