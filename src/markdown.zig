//! Minimal terminal Markdown renderer for `--render markdown`.
//!
//! Scope (deliberately small — this is a debugger, not a viewer):
//!   • ATX headings (#, ##, ###) → bold (+ cyan if color)
//!   • Fenced code blocks (```lang) → dim
//!   • Inline code (`...`)         → reverse video
//!   • **bold** spans              → ANSI bold
//!   • Block quotes (> ...)        → dim ">"
//!
//! Italic, links, tables, and HTML are intentionally out of scope. Unknown
//! markup passes through verbatim.
const std = @import("std");

pub const Options = struct {
    color: bool = true,
};

const ESC = "\x1b[";
const RESET_ALL = "\x1b[0m";

const Codes = struct {
    bold_on: []const u8,
    bold_off: []const u8,
    dim_on: []const u8,
    dim_off: []const u8,
    rev_on: []const u8,
    rev_off: []const u8,
    cyan_on: []const u8,
    cyan_off: []const u8,
};

const codes_color: Codes = .{
    .bold_on = ESC ++ "1m",
    .bold_off = ESC ++ "22m",
    .dim_on = ESC ++ "2m",
    .dim_off = ESC ++ "22m",
    .rev_on = ESC ++ "7m",
    .rev_off = ESC ++ "27m",
    .cyan_on = ESC ++ "36m",
    .cyan_off = ESC ++ "39m",
};

const codes_none: Codes = .{
    .bold_on = "",
    .bold_off = "",
    .dim_on = "",
    .dim_off = "",
    .rev_on = "",
    .rev_off = "",
    .cyan_on = "",
    .cyan_off = "",
};

/// Render `input` (markdown-flavoured text) into ANSI-decorated text.
/// Result is arena-allocated.
pub fn render(arena: std.mem.Allocator, input: []const u8, opts: Options) ![]u8 {
    const c: Codes = if (opts.color) codes_color else codes_none;

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, input.len + 32);

    var in_code_block = false;
    var iter = std.mem.splitScalar(u8, input, '\n');
    var first = true;
    while (iter.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;

        // Fenced code blocks: line starts with ``` (optionally followed by a lang).
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "```")) {
            in_code_block = !in_code_block;
            try out.appendSlice(arena, c.dim_on);
            try out.appendSlice(arena, line);
            try out.appendSlice(arena, c.dim_off);
            continue;
        }

        if (in_code_block) {
            try out.appendSlice(arena, c.dim_on);
            try out.appendSlice(arena, line);
            try out.appendSlice(arena, c.dim_off);
            continue;
        }

        // Block quote: leading "> ".
        if (std.mem.startsWith(u8, line, "> ") or std.mem.eql(u8, line, ">")) {
            try out.appendSlice(arena, c.dim_on);
            try out.appendSlice(arena, line);
            try out.appendSlice(arena, c.dim_off);
            continue;
        }

        // ATX heading: 1–3 leading '#' then space.
        const heading_level = headingLevel(line);
        if (heading_level > 0) {
            const after = line[heading_level + 1 ..];
            try out.appendSlice(arena, c.bold_on);
            try out.appendSlice(arena, c.cyan_on);
            try out.appendSlice(arena, line[0..heading_level]);
            try out.append(arena, ' ');
            try renderInline(arena, &out, after, c);
            try out.appendSlice(arena, c.cyan_off);
            try out.appendSlice(arena, c.bold_off);
            continue;
        }

        try renderInline(arena, &out, line, c);
    }

    return try out.toOwnedSlice(arena);
}

fn headingLevel(line: []const u8) usize {
    var n: usize = 0;
    while (n < line.len and n < 3 and line[n] == '#') n += 1;
    if (n == 0) return 0;
    if (n >= line.len or line[n] != ' ') return 0;
    return n;
}

/// Inline span pass: handles **bold** and `code`. Other characters pass through.
fn renderInline(arena: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8, c: Codes) !void {
    var i: usize = 0;
    while (i < line.len) {
        // Inline code: `...`
        if (line[i] == '`') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '`')) |close| {
                try out.appendSlice(arena, c.rev_on);
                try out.append(arena, '`');
                try out.appendSlice(arena, line[i + 1 .. close]);
                try out.append(arena, '`');
                try out.appendSlice(arena, c.rev_off);
                i = close + 1;
                continue;
            }
        }
        // Bold: **...**
        if (i + 1 < line.len and line[i] == '*' and line[i + 1] == '*') {
            if (std.mem.indexOfPos(u8, line, i + 2, "**")) |close| {
                try out.appendSlice(arena, c.bold_on);
                try out.appendSlice(arena, line[i + 2 .. close]);
                try out.appendSlice(arena, c.bold_off);
                i = close + 2;
                continue;
            }
        }
        try out.append(arena, line[i]);
        i += 1;
    }
}

const testing = std.testing;

test "render: plain text passes through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "hello world", .{ .color = false });
    try testing.expectEqualStrings("hello world", out);
}

test "render: heading without color" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "# Title\nbody", .{ .color = false });
    try testing.expectEqualStrings("# Title\nbody", out);
}

test "render: bold span with color" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "this is **bold** text", .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bold") != null);
}

test "render: inline code with color" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "use `cargo build` here", .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[7m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "`cargo build`") != null);
}

test "render: fenced code block dimmed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\before
        \\```rust
        \\fn main() {}
        \\```
        \\after
    ;
    const out = try render(arena.allocator(), input, .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "fn main()") != null);
    try testing.expect(std.mem.indexOf(u8, out, "before") != null);
    try testing.expect(std.mem.indexOf(u8, out, "after") != null);
}

test "render: heading level cap at 3" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    // Four #s should not be treated as a heading.
    const out = try render(arena.allocator(), "#### deep\n", .{ .color = false });
    try testing.expectEqualStrings("#### deep\n", out);
}

test "render: unbalanced bold passes through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "this **is unclosed", .{ .color = true });
    try testing.expectEqualStrings("this **is unclosed", out);
}

test "render: blockquote" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "> a quote", .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "a quote") != null);
}
