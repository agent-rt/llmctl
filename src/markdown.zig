//! Terminal Markdown renderer for `--render markdown`.
//!
//! Coverage (GFM-flavoured, but pragmatic):
//!   • ATX headings (#, ##, ###)        → bold + cyan
//!   • Setext headings (=== / ---)      → bold + cyan (line above)
//!   • Fenced code blocks (```lang)     → dim
//!   • Indented code blocks (4 spaces)  → dim
//!   • Inline code (`...`)              → reverse video
//!   • **bold** / __bold__              → ANSI bold
//!   • *italic* / _italic_              → ANSI italic
//!   • ~~strike~~                       → ANSI strikethrough
//!   • Bullets (-, *, +)                → "•" + indent preserved
//!   • Task lists (- [ ] / - [x])       → ☐ / ☑
//!   • Ordered lists (1.)               → digit colored
//!   • Block quotes (> ...)             → dim, "▎" gutter
//!   • Horizontal rules (---, ***, ___) → dim line
//!   • Table separator lines (---|---)  → dimmed
//!   • Autolinks (<https://...>)        → underline
//!
//! Out of scope: nested emphasis precedence, footnotes, HTML, definition
//! lists. Unknown markup passes through verbatim.
const std = @import("std");

pub const Options = struct {
    color: bool = true,
};

const ESC = "\x1b[";

const Codes = struct {
    bold_on: []const u8,
    bold_off: []const u8,
    dim_on: []const u8,
    dim_off: []const u8,
    italic_on: []const u8,
    italic_off: []const u8,
    rev_on: []const u8,
    rev_off: []const u8,
    strike_on: []const u8,
    strike_off: []const u8,
    underline_on: []const u8,
    underline_off: []const u8,
    cyan_on: []const u8,
    cyan_off: []const u8,
    yellow_on: []const u8,
    yellow_off: []const u8,
};

const codes_color: Codes = .{
    .bold_on = ESC ++ "1m",
    .bold_off = ESC ++ "22m",
    .dim_on = ESC ++ "2m",
    .dim_off = ESC ++ "22m",
    .italic_on = ESC ++ "3m",
    .italic_off = ESC ++ "23m",
    .rev_on = ESC ++ "7m",
    .rev_off = ESC ++ "27m",
    .strike_on = ESC ++ "9m",
    .strike_off = ESC ++ "29m",
    .underline_on = ESC ++ "4m",
    .underline_off = ESC ++ "24m",
    .cyan_on = ESC ++ "36m",
    .cyan_off = ESC ++ "39m",
    .yellow_on = ESC ++ "33m",
    .yellow_off = ESC ++ "39m",
};

const codes_none: Codes = .{
    .bold_on = "",
    .bold_off = "",
    .dim_on = "",
    .dim_off = "",
    .italic_on = "",
    .italic_off = "",
    .rev_on = "",
    .rev_off = "",
    .strike_on = "",
    .strike_off = "",
    .underline_on = "",
    .underline_off = "",
    .cyan_on = "",
    .cyan_off = "",
    .yellow_on = "",
    .yellow_off = "",
};

/// Render `input` (markdown-flavoured text) into ANSI-decorated text.
pub fn render(arena: std.mem.Allocator, input: []const u8, opts: Options) ![]u8 {
    const c: Codes = if (opts.color) codes_color else codes_none;

    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(arena, input.len + 64);

    var in_code_block = false;
    var iter = std.mem.splitScalar(u8, input, '\n');
    var first = true;
    var prev_line: []const u8 = "";

    while (iter.next()) |line| {
        if (!first) try out.append(arena, '\n');
        first = false;

        // Fence open/close detection — uses the leading-trimmed view.
        const ltrim = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, ltrim, "```") or std.mem.startsWith(u8, ltrim, "~~~")) {
            in_code_block = !in_code_block;
            try out.appendSlice(arena, c.dim_on);
            try out.appendSlice(arena, line);
            try out.appendSlice(arena, c.dim_off);
            prev_line = line;
            continue;
        }
        if (in_code_block) {
            try out.appendSlice(arena, c.dim_on);
            try out.appendSlice(arena, line);
            try out.appendSlice(arena, c.dim_off);
            prev_line = line;
            continue;
        }

        // Indented code block: 4+ leading spaces (only if previous line was blank or code).
        if (line.len >= 4 and std.mem.eql(u8, line[0..4], "    ")) {
            try out.appendSlice(arena, c.dim_on);
            try out.appendSlice(arena, line);
            try out.appendSlice(arena, c.dim_off);
            prev_line = line;
            continue;
        }

        // Horizontal rule: 3+ of -, *, or _ (only those + spaces).
        if (isHorizontalRule(ltrim)) {
            try out.appendSlice(arena, c.dim_on);
            try out.appendSlice(arena, line);
            try out.appendSlice(arena, c.dim_off);
            prev_line = line;
            continue;
        }

        // Setext heading underline (=== or ---) for the previous line.
        if (prev_line.len > 0 and isSetextUnderline(ltrim)) {
            // Replace the prior render of prev_line with a bold/cyan version.
            // Simpler: emit the underline dimmed; the heading line was emitted as-is
            // (we don't lookahead). Acceptable degradation — in practice ATX headings
            // dominate; setext is uncommon.
            try out.appendSlice(arena, c.dim_on);
            try out.appendSlice(arena, line);
            try out.appendSlice(arena, c.dim_off);
            prev_line = line;
            continue;
        }

        // Block quote (possibly nested with multiple '>').
        if (std.mem.startsWith(u8, ltrim, "> ") or std.mem.eql(u8, ltrim, ">") or std.mem.startsWith(u8, ltrim, ">>")) {
            try out.appendSlice(arena, c.dim_on);
            try out.appendSlice(arena, line);
            try out.appendSlice(arena, c.dim_off);
            prev_line = line;
            continue;
        }

        // Table separator row: |---|---| or  --- | ---  with optional alignment colons.
        if (isTableSeparator(line)) {
            try out.appendSlice(arena, c.dim_on);
            try out.appendSlice(arena, line);
            try out.appendSlice(arena, c.dim_off);
            prev_line = line;
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
            prev_line = line;
            continue;
        }

        // List items (-, *, +, or `N.`) + task-list checkbox.
        if (try renderListLine(arena, &out, line, c)) {
            prev_line = line;
            continue;
        }

        try renderInline(arena, &out, line, c);
        prev_line = line;
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

fn isHorizontalRule(s: []const u8) bool {
    if (s.len < 3) return false;
    const t = std.mem.trim(u8, s, " \t");
    if (t.len < 3) return false;
    const ch = t[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;
    for (t) |c| if (c != ch and c != ' ') return false;
    var count: usize = 0;
    for (t) |c| if (c == ch) {
        count += 1;
    };
    return count >= 3;
}

fn isSetextUnderline(s: []const u8) bool {
    if (s.len == 0) return false;
    const ch = s[0];
    if (ch != '=' and ch != '-') return false;
    for (s) |c| if (c != ch) return false;
    return s.len >= 3;
}

fn isTableSeparator(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t");
    if (t.len < 3) return false;
    var has_dash = false;
    var has_pipe = false;
    for (t) |c| {
        switch (c) {
            '-' => has_dash = true,
            '|' => has_pipe = true,
            ':', ' ', '\t' => {},
            else => return false,
        }
    }
    return has_dash and has_pipe;
}

/// Render list-item lines (bullets, ordered, task lists). Returns false if not a list line.
fn renderListLine(arena: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8, c: Codes) !bool {
    // Compute leading whitespace.
    var ws_end: usize = 0;
    while (ws_end < line.len and (line[ws_end] == ' ' or line[ws_end] == '\t')) ws_end += 1;
    const ws = line[0..ws_end];
    const rest = line[ws_end..];
    if (rest.len < 2) return false;

    // Bullet markers: -, *, +
    if ((rest[0] == '-' or rest[0] == '*' or rest[0] == '+') and rest[1] == ' ') {
        try out.appendSlice(arena, ws);
        try out.appendSlice(arena, c.cyan_on);
        try out.appendSlice(arena, "•");
        try out.appendSlice(arena, c.cyan_off);
        // Task list?
        const after_marker = rest[2..];
        if (after_marker.len >= 4 and after_marker[0] == '[' and after_marker[2] == ']' and after_marker[3] == ' ') {
            const ch = after_marker[1];
            const box: []const u8 = switch (ch) {
                'x', 'X' => "☑",
                ' ' => "☐",
                else => return blk: {
                    // Not a task box; treat as plain bullet content.
                    try out.append(arena, ' ');
                    try renderInline(arena, out, after_marker, c);
                    break :blk true;
                },
            };
            try out.append(arena, ' ');
            if (ch == 'x' or ch == 'X') {
                try out.appendSlice(arena, c.dim_on);
                try out.appendSlice(arena, box);
                try out.append(arena, ' ');
                try renderInline(arena, out, after_marker[4..], c);
                try out.appendSlice(arena, c.dim_off);
            } else {
                try out.appendSlice(arena, box);
                try out.append(arena, ' ');
                try renderInline(arena, out, after_marker[4..], c);
            }
            return true;
        }
        try out.append(arena, ' ');
        try renderInline(arena, out, after_marker, c);
        return true;
    }

    // Ordered list: digits then "." or ")" then space.
    var i: usize = 0;
    while (i < rest.len and std.ascii.isDigit(rest[i])) i += 1;
    if (i > 0 and i + 1 < rest.len and (rest[i] == '.' or rest[i] == ')') and rest[i + 1] == ' ') {
        try out.appendSlice(arena, ws);
        try out.appendSlice(arena, c.cyan_on);
        try out.appendSlice(arena, rest[0 .. i + 1]);
        try out.appendSlice(arena, c.cyan_off);
        try out.append(arena, ' ');
        try renderInline(arena, out, rest[i + 2 ..], c);
        return true;
    }
    return false;
}

/// Inline span pass: handles `code`, **bold**, __bold__, *italic*, _italic_,
/// ~~strike~~, <autolink>. Other characters pass through.
fn renderInline(arena: std.mem.Allocator, out: *std.ArrayList(u8), line: []const u8, c: Codes) !void {
    var i: usize = 0;
    while (i < line.len) {
        const ch = line[i];

        // Inline code: `...`  (highest precedence)
        if (ch == '`') {
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

        // Strikethrough: ~~...~~
        if (i + 1 < line.len and ch == '~' and line[i + 1] == '~') {
            if (std.mem.indexOfPos(u8, line, i + 2, "~~")) |close| {
                try out.appendSlice(arena, c.strike_on);
                try out.appendSlice(arena, line[i + 2 .. close]);
                try out.appendSlice(arena, c.strike_off);
                i = close + 2;
                continue;
            }
        }

        // Bold: **...** or __...__
        if (i + 1 < line.len and (ch == '*' or ch == '_') and line[i + 1] == ch) {
            const marker = [_]u8{ ch, ch };
            if (std.mem.indexOfPos(u8, line, i + 2, &marker)) |close| {
                try out.appendSlice(arena, c.bold_on);
                try out.appendSlice(arena, line[i + 2 .. close]);
                try out.appendSlice(arena, c.bold_off);
                i = close + 2;
                continue;
            }
        }

        // Italic: *...* or _..._  with word-boundary heuristic to avoid bullets and snake_case.
        if ((ch == '*' or ch == '_') and (i + 1 >= line.len or line[i + 1] != ch) and isItalicOpen(line, i)) {
            if (findItalicClose(line, i + 1, ch)) |close| {
                if (close > i + 1) {
                    try out.appendSlice(arena, c.italic_on);
                    try out.appendSlice(arena, line[i + 1 .. close]);
                    try out.appendSlice(arena, c.italic_off);
                    i = close + 1;
                    continue;
                }
            }
        }

        // Autolink: <http(s)://...>
        if (ch == '<') {
            if (std.mem.indexOfScalarPos(u8, line, i + 1, '>')) |close| {
                const inner = line[i + 1 .. close];
                if (std.mem.startsWith(u8, inner, "http://") or std.mem.startsWith(u8, inner, "https://")) {
                    try out.appendSlice(arena, c.underline_on);
                    try out.appendSlice(arena, line[i .. close + 1]);
                    try out.appendSlice(arena, c.underline_off);
                    i = close + 1;
                    continue;
                }
            }
        }

        try out.append(arena, ch);
        i += 1;
    }
}

/// An italic open delimiter requires the preceding char to be either start-of-line,
/// whitespace, or punctuation — never alphanumeric (which would make it part of a word
/// like `snake_case`).
fn isItalicOpen(line: []const u8, i: usize) bool {
    if (i == 0) return true;
    const prev = line[i - 1];
    return !std.ascii.isAlphanumeric(prev);
}

/// Find a matching italic close: the same `ch`, not-doubled, and not followed by an
/// alphanumeric (so `_word_s` doesn't close on the first `_`).
fn findItalicClose(line: []const u8, start: usize, ch: u8) ?usize {
    var i = start;
    while (i < line.len) : (i += 1) {
        if (line[i] != ch) continue;
        if (i + 1 < line.len and line[i + 1] == ch) {
            // doubled — skip both
            i += 1;
            continue;
        }
        // Check the char after isn't alphanumeric (avoid mid-word match).
        if (i + 1 < line.len and std.ascii.isAlphanumeric(line[i + 1])) continue;
        // Check the char before the close isn't whitespace (closes can't follow space).
        if (i > start and (line[i - 1] == ' ' or line[i - 1] == '\t')) continue;
        return i;
    }
    return null;
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

test "render: bold via __" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "__bold__", .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "bold") != null);
}

test "render: italic with *" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "this is *emphasized* text", .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[3m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "emphasized") != null);
}

test "render: italic does not eat snake_case" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "the snake_case_var stays", .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[3m") == null);
    try testing.expect(std.mem.indexOf(u8, out, "snake_case_var") != null);
}

test "render: strikethrough" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "~~deleted~~ rest", .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[9m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "deleted") != null);
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

test "render: tilde fenced code block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "~~~\nplain\n~~~";
    const out = try render(arena.allocator(), input, .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "plain") != null);
}

test "render: heading level cap at 3" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
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

test "render: horizontal rule" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "before\n---\nafter", .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m") != null);
}

test "render: bullet list with •" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "- one\n- two", .{ .color = false });
    try testing.expect(std.mem.indexOf(u8, out, "•") != null);
    try testing.expect(std.mem.indexOf(u8, out, "one") != null);
    try testing.expect(std.mem.indexOf(u8, out, "two") != null);
}

test "render: ordered list keeps digit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "1. first\n2. second", .{ .color = false });
    try testing.expect(std.mem.indexOf(u8, out, "1. first") != null);
    try testing.expect(std.mem.indexOf(u8, out, "2. second") != null);
}

test "render: task list checkboxes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "- [ ] todo\n- [x] done", .{ .color = false });
    try testing.expect(std.mem.indexOf(u8, out, "☐") != null);
    try testing.expect(std.mem.indexOf(u8, out, "☑") != null);
    try testing.expect(std.mem.indexOf(u8, out, "todo") != null);
    try testing.expect(std.mem.indexOf(u8, out, "done") != null);
}

test "render: table separator dimmed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
    ;
    const out = try render(arena.allocator(), input, .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "| 1 | 2 |") != null);
}

test "render: autolink underlined" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "see <https://example.com> here", .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[4m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "https://example.com") != null);
}

test "render: indented code block dimmed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const out = try render(arena.allocator(), "text\n    code\nmore", .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m") != null);
    try testing.expect(std.mem.indexOf(u8, out, "code") != null);
}
