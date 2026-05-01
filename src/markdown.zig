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

    // Collect lines into an array so we can peek ahead (table block detection).
    var lines: std.ArrayList([]const u8) = .empty;
    {
        var iter = std.mem.splitScalar(u8, input, '\n');
        while (iter.next()) |line| try lines.append(arena, line);
    }

    var in_code_block = false;
    var prev_line: []const u8 = "";

    var idx: usize = 0;
    while (idx < lines.items.len) : (idx += 1) {
        const line = lines.items[idx];
        if (idx > 0) try out.append(arena, '\n');
        const next_line: []const u8 = if (idx + 1 < lines.items.len) lines.items[idx + 1] else "";
        const ltrim = std.mem.trimStart(u8, line, " \t");

        // Fence open/close detection — uses the leading-trimmed view.
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

        // ── Table block ── header line + separator next.
        if (isTableRowLine(line) and isTableSeparator(next_line)) {
            const consumed = try renderTableBlock(arena, &out, lines.items[idx..], c);
            // Skip past consumed lines (the loop's idx+=1 will advance one more).
            idx += consumed - 1;
            prev_line = line;
            continue;
        }

        // Indented code block: 4+ leading spaces.
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

fn isTableRowLine(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    if (t.len == 0 or t[0] != '|') return false;
    // Need at least one more '|' to form a cell.
    return std.mem.indexOfScalarPos(u8, t, 1, '|') != null;
}

const TableAlign = enum { left, right, center };

/// Render a complete GFM table block: header + separator + body rows.
/// Computes column widths for visible alignment, parses :--- / ---: / :---:
/// alignment markers, and emits cells with bold header / dim pipes / inline body.
/// Returns the number of lines consumed.
fn renderTableBlock(arena: std.mem.Allocator, out: *std.ArrayList(u8), lines: []const []const u8, c: Codes) !usize {
    if (lines.len < 2) return 0;

    // Collect contiguous table rows: header, separator, then body rows.
    var rows: std.ArrayList([][]const u8) = .empty;
    const header_cells = try splitRow(arena, lines[0]);
    try rows.append(arena, header_cells);

    var aligns: std.ArrayList(TableAlign) = .empty;
    {
        const sep_cells = try splitRow(arena, lines[1]);
        for (sep_cells) |cell| {
            const t = std.mem.trim(u8, cell, " \t");
            const left = t.len > 0 and t[0] == ':';
            const right = t.len > 0 and t[t.len - 1] == ':';
            const a: TableAlign = if (left and right) .center else if (right) .right else .left;
            try aligns.append(arena, a);
        }
        // Pad alignments to header column count if shorter.
        while (aligns.items.len < header_cells.len) try aligns.append(arena, .left);
    }

    var consumed: usize = 2; // header + separator
    while (consumed < lines.len) : (consumed += 1) {
        const ln = lines[consumed];
        if (!isTableRowLine(ln) or isTableSeparator(ln)) break;
        const body_cells = try splitRow(arena, ln);
        try rows.append(arena, body_cells);
    }

    // Compute max visible width per column (across header + body, excluding separator).
    const ncols = header_cells.len;
    var widths: std.ArrayList(usize) = .empty;
    for (0..ncols) |_| try widths.append(arena, 0);
    for (rows.items) |r| {
        for (r, 0..) |cell, ci| {
            if (ci >= ncols) break;
            const t = std.mem.trim(u8, cell, " \t");
            const w = visibleWidth(t);
            if (w > widths.items[ci]) widths.items[ci] = w;
        }
    }

    // Emit header row.
    try emitTableRow(arena, out, header_cells, widths.items, aligns.items, c, true);
    try out.append(arena, '\n');
    // Emit separator: dim, with same column widths so it visually matches.
    try emitSeparator(arena, out, widths.items, aligns.items, c);

    // Emit body rows.
    for (rows.items[1..]) |body| {
        try out.append(arena, '\n');
        try emitTableRow(arena, out, body, widths.items, aligns.items, c, false);
    }

    return consumed;
}

/// Split a `| a | b |` row into trimmed cell strings. Leading/trailing empty
/// cells from outer pipes are dropped.
fn splitRow(arena: std.mem.Allocator, line: []const u8) ![][]const u8 {
    var cells: std.ArrayList([]const u8) = .empty;
    const t = std.mem.trim(u8, line, " \t");
    var rest = t;
    if (rest.len > 0 and rest[0] == '|') rest = rest[1..];
    if (rest.len > 0 and rest[rest.len - 1] == '|') rest = rest[0 .. rest.len - 1];
    var iter = std.mem.splitScalar(u8, rest, '|');
    while (iter.next()) |cell| {
        try cells.append(arena, std.mem.trim(u8, cell, " \t"));
    }
    return cells.toOwnedSlice(arena);
}

fn emitTableRow(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cells: []const []const u8,
    widths: []const usize,
    aligns: []const TableAlign,
    c: Codes,
    header: bool,
) !void {
    try out.appendSlice(arena, c.dim_on);
    try out.append(arena, '|');
    try out.appendSlice(arena, c.dim_off);
    for (widths, 0..) |w, ci| {
        const cell = if (ci < cells.len) cells[ci] else "";
        const cw = visibleWidth(cell);
        const pad = if (w > cw) w - cw else 0;
        const al = if (ci < aligns.len) aligns[ci] else .left;
        var lpad: usize = 0;
        var rpad: usize = 0;
        switch (al) {
            .left => rpad = pad,
            .right => lpad = pad,
            .center => {
                lpad = pad / 2;
                rpad = pad - lpad;
            },
        }
        try out.append(arena, ' ');
        try appendSpaces(arena, out, lpad);
        if (header) try out.appendSlice(arena, c.bold_on);
        try renderInline(arena, out, cell, c);
        if (header) try out.appendSlice(arena, c.bold_off);
        try appendSpaces(arena, out, rpad);
        try out.append(arena, ' ');
        try out.appendSlice(arena, c.dim_on);
        try out.append(arena, '|');
        try out.appendSlice(arena, c.dim_off);
    }
}

fn emitSeparator(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    widths: []const usize,
    aligns: []const TableAlign,
    c: Codes,
) !void {
    try out.appendSlice(arena, c.dim_on);
    try out.append(arena, '|');
    for (widths, 0..) |w, ci| {
        const al = if (ci < aligns.len) aligns[ci] else .left;
        try out.append(arena, ' ');
        const left_marker: u8 = if (al == .center or al == .left) ':' else '-';
        const right_marker: u8 = if (al == .center or al == .right) ':' else '-';
        try out.append(arena, left_marker);
        // dashes for the visible width minus the two markers (min 1 dash)
        var dash_count: usize = if (w >= 2) w - 2 else 1;
        if (dash_count < 1) dash_count = 1;
        for (0..dash_count) |_| try out.append(arena, '-');
        try out.append(arena, right_marker);
        try out.append(arena, ' ');
        try out.append(arena, '|');
    }
    try out.appendSlice(arena, c.dim_off);
}

fn appendSpaces(arena: std.mem.Allocator, out: *std.ArrayList(u8), n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try out.append(arena, ' ');
}

/// Approximate terminal cell width of a UTF-8 string. ANSI escape codes
/// inside `s` are stripped from the count. Inline markdown (e.g. `**x**`)
/// is also discounted to its visible portion.
fn visibleWidth(s: []const u8) usize {
    var w: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        // Skip CSI escape sequences (shouldn't appear in raw markdown but
        // be defensive).
        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '[') {
            i += 2;
            while (i < s.len and !std.ascii.isAlphabetic(s[i])) i += 1;
            if (i < s.len) i += 1;
            continue;
        }
        // Skip inline markdown markers when counting visible width.
        if (s[i] == '*' or s[i] == '_' or s[i] == '`' or s[i] == '~') {
            // Treat any run of these as zero-width markers.
            const ch = s[i];
            while (i < s.len and s[i] == ch) i += 1;
            continue;
        }
        const cw = utf8Width(s[i..]);
        w += cw.width;
        i += cw.bytes;
    }
    return w;
}

fn utf8Width(s: []const u8) struct { width: usize, bytes: usize } {
    if (s.len == 0) return .{ .width = 0, .bytes = 0 };
    const b = s[0];
    if (b < 0x80) return .{ .width = 1, .bytes = 1 };
    if (b < 0xC0) return .{ .width = 1, .bytes = 1 };
    if (b < 0xE0) return .{ .width = 1, .bytes = 2 };
    if (b < 0xF0) {
        const w: usize = if (b >= 0xE3) 2 else 1;
        return .{ .width = w, .bytes = 3 };
    }
    return .{ .width = 2, .bytes = 4 };
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
}

test "render: table header bold, pipes dim, body inline" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\| name | role |
        \\| :--- | :--- |
        \\| Alice | dev |
    ;
    const out = try render(arena.allocator(), input, .{ .color = true });
    // Header cell rendered bold.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
    // Pipes dimmed.
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[2m|") != null);
    // Cells preserved in output (with ANSI noise around them).
    try testing.expect(std.mem.indexOf(u8, out, "name") != null);
    try testing.expect(std.mem.indexOf(u8, out, "Alice") != null);
}

test "render: table with CJK content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\| 场景 | 表达 |
        \\| :--- | :--- |
        \\| 礼貌 | さん |
    ;
    const out = try render(arena.allocator(), input, .{ .color = true });
    try testing.expect(std.mem.indexOf(u8, out, "场景") != null);
    try testing.expect(std.mem.indexOf(u8, out, "さん") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
}

test "render: table ends on blank line, normal text after" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\
        \\after **bold**
    ;
    const out = try render(arena.allocator(), input, .{ .color = true });
    // Bold applied after table closes.
    try testing.expect(std.mem.indexOf(u8, out, "after ") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\x1b[1m") != null);
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
