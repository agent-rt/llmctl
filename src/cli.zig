//! Command-line argument parser. Per TECH-DESIGN §13.
//! Hand-rolled, no third-party deps. Emits a parsed Args struct.
const std = @import("std");
const types = @import("types.zig");
const extra_mod = @import("extra.zig");

pub const OutputFormat = enum { text, json, ndjson };
pub const RenderMode = enum { none, markdown };

pub const Args = struct {
    provider: ?[]const u8 = null,
    base_url: ?[]const u8 = null,
    /// Multi-model support: collect all --model occurrences.
    models: std.ArrayList([]const u8) = .empty,
    system: ?[]const u8 = null,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    extra: std.StringHashMapUnmanaged(std.json.Value) = .empty,
    interactive: bool = false,
    session: ?[]const u8 = null,
    save_session: ?[]const u8 = null,
    output: OutputFormat = .text,
    /// null = "user did not specify"; main.zig picks a default per mode (markdown in REPL, none elsewhere).
    render: ?RenderMode = null,
    buffer: bool = false,
    no_color: bool = false,
    dry_run: bool = false,
    verbose: bool = false,
    show_help: bool = false,
    show_version: bool = false,
    /// Positional argv prompt (joined with spaces if multiple).
    prompt: ?[]const u8 = null,
};

pub const ParseError = anyerror;

const help_text =
    \\llmctl — fast, pipe-friendly LLM API debugger
    \\
    \\USAGE:
    \\    llmctl [OPTIONS] [PROMPT]
    \\    echo "..." | llmctl [OPTIONS]
    \\
    \\PROVIDER:
    \\    --provider <name>     Provider name (default: local; built-ins: local, openai, openai-compat, anthropic)
    \\    --base-url <url>      Override provider base URL
    \\    --model, -m <name>    Model name (repeat for multi-model)
    \\
    \\PROMPT:
    \\    --system <text|@file> System prompt (use @path to read from file)
    \\
    \\PARAMETERS:
    \\    --temperature <f>     Sampling temperature
    \\    --max-tokens <n>      Maximum output tokens (default: 4096)
    \\    --top-p <f>           Nucleus sampling
    \\    --extra k=v           Pass-through field (repeatable; type-inferred)
    \\    --extra-json '{...}'  Pass-through fields from JSON object
    \\
    \\OUTPUT:
    \\    --output text|json|ndjson   (default: text)
    \\    --render none|markdown      Post-render text output (default: none; implies --buffer)
    \\    --buffer              Buffer text output until completion (alias --no-stream)
    \\    --no-color            Disable ANSI colors
    \\    --json                Alias for --output json
    \\    --no-stream           Alias for --buffer
    \\
    \\SESSION:
    \\    --session <path>      Load+update conversation from JSON file
    \\    --save-session <path> Save (or fork) conversation to JSON file
    \\    -i, --interactive     Enter REPL mode (slash commands; /help inside)
    \\
    \\DEBUG:
    \\    --dry-run             Print request body and exit (auth redacted)
    \\    --verbose, -v         Print provider/url/latency/usage to stderr
    \\
    \\OTHER:
    \\    --help, -h
    \\    --version, -V
    \\
    \\BUILT-IN PROVIDERS:
    \\    local           http://localhost:8080  (auth: none)  ← llama-server default
    \\    openai          https://api.openai.com (auth: bearer ${OPENAI_API_KEY})
    \\    openai-compat   user-supplied via --base-url
    \\    anthropic       https://api.anthropic.com (auth: bearer ${ANTHROPIC_API_KEY})
    \\
    \\CONFIG:
    \\    llmctl config list             Print all defaults from ~/.config/llmctl/defaults
    \\    llmctl config get <key>        Print one default
    \\    llmctl config set <key> <val>  Write/update a default
    \\    llmctl config unset <key>      Remove a default
    \\    llmctl config path             Print the defaults file path
    \\
    \\EXAMPLES:
    \\    llmctl "explain recursion"
    \\    echo "summarize" | llmctl < article.txt
    \\    llmctl --base-url http://10.0.0.64:8800 --model gemma "hi"
    \\    llmctl --output ndjson "hi" | jq .
    \\    llmctl --extra cache_prompt=true --extra seed=42 "hi"
    \\
;

pub fn helpText() []const u8 {
    return help_text;
}

pub fn parse(arena: std.mem.Allocator, argv: []const [:0]const u8) ParseError!Args {
    var a: Args = .{};

    var prompt_parts: std.ArrayList([]const u8) = .empty;

    var i: usize = 1; // skip argv[0]
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        // Handle --key=value form by splitting.
        var key: []const u8 = arg;
        var inline_val: ?[]const u8 = null;
        if (std.mem.startsWith(u8, arg, "--")) {
            if (std.mem.indexOfScalar(u8, arg, '=')) |eq| {
                key = arg[0..eq];
                inline_val = arg[eq + 1 ..];
            }
        }

        if (std.mem.eql(u8, key, "--help") or std.mem.eql(u8, key, "-h")) {
            a.show_help = true;
        } else if (std.mem.eql(u8, key, "--version") or std.mem.eql(u8, key, "-V")) {
            a.show_version = true;
        } else if (std.mem.eql(u8, key, "--provider")) {
            a.provider = try takeValue(argv, &i, inline_val);
        } else if (std.mem.eql(u8, key, "--base-url")) {
            a.base_url = try takeValue(argv, &i, inline_val);
        } else if (std.mem.eql(u8, key, "--model") or std.mem.eql(u8, key, "-m")) {
            const v = try takeValue(argv, &i, inline_val);
            try a.models.append(arena, v);
        } else if (std.mem.eql(u8, key, "--system")) {
            a.system = try takeValue(argv, &i, inline_val);
        } else if (std.mem.eql(u8, key, "--temperature")) {
            const v = try takeValue(argv, &i, inline_val);
            a.temperature = std.fmt.parseFloat(f32, v) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "--max-tokens")) {
            const v = try takeValue(argv, &i, inline_val);
            a.max_tokens = std.fmt.parseInt(u32, v, 10) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "--top-p")) {
            const v = try takeValue(argv, &i, inline_val);
            a.top_p = std.fmt.parseFloat(f32, v) catch return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "--extra")) {
            const v = try takeValue(argv, &i, inline_val);
            const r = try extra_mod.parseKv(arena, v);
            try a.extra.put(arena, r.key, r.value);
        } else if (std.mem.eql(u8, key, "--extra-json")) {
            const v = try takeValue(argv, &i, inline_val);
            try extra_mod.mergeJsonObject(arena, v, &a.extra);
        } else if (std.mem.eql(u8, key, "--output")) {
            const v = try takeValue(argv, &i, inline_val);
            if (std.mem.eql(u8, v, "text")) a.output = .text
            else if (std.mem.eql(u8, v, "json")) a.output = .json
            else if (std.mem.eql(u8, v, "ndjson")) a.output = .ndjson
            else return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "--json")) {
            a.output = .json;
        } else if (std.mem.eql(u8, key, "--ndjson")) {
            a.output = .ndjson;
        } else if (std.mem.eql(u8, key, "--interactive") or std.mem.eql(u8, key, "-i")) {
            a.interactive = true;
        } else if (std.mem.eql(u8, key, "--session")) {
            a.session = try takeValue(argv, &i, inline_val);
        } else if (std.mem.eql(u8, key, "--save-session")) {
            a.save_session = try takeValue(argv, &i, inline_val);
        } else if (std.mem.eql(u8, key, "--render")) {
            const v = try takeValue(argv, &i, inline_val);
            if (std.mem.eql(u8, v, "none")) a.render = .none
            else if (std.mem.eql(u8, v, "markdown") or std.mem.eql(u8, v, "md")) a.render = .markdown
            else return error.InvalidValue;
        } else if (std.mem.eql(u8, key, "--buffer") or std.mem.eql(u8, key, "--no-stream")) {
            a.buffer = true;
        } else if (std.mem.eql(u8, key, "--no-color")) {
            a.no_color = true;
        } else if (std.mem.eql(u8, key, "--dry-run")) {
            a.dry_run = true;
        } else if (std.mem.eql(u8, key, "--verbose") or std.mem.eql(u8, key, "-v")) {
            a.verbose = true;
        } else if (std.mem.eql(u8, key, "--")) {
            // Treat remaining as positional.
            i += 1;
            while (i < argv.len) : (i += 1) {
                try prompt_parts.append(arena, argv[i]);
            }
            break;
        } else if (std.mem.startsWith(u8, key, "-") and key.len > 1) {
            return error.UnknownFlag;
        } else {
            // Positional.
            try prompt_parts.append(arena, arg);
        }
    }

    if (prompt_parts.items.len > 0) {
        a.prompt = try std.mem.join(arena, " ", prompt_parts.items);
    }

    return a;
}

fn takeValue(argv: []const [:0]const u8, i: *usize, inline_val: ?[]const u8) anyerror![]const u8 {
    if (inline_val) |v| return v;
    if (i.* + 1 >= argv.len) return error.MissingValue;
    i.* += 1;
    return argv[i.*];
}

const testing = std.testing;

fn argsFromArray(arr: []const [:0]const u8) []const [:0]const u8 {
    return arr;
}

test "parse: positional prompt" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "llmctl", "hello", "world" };
    const a = try parse(arena.allocator(), &argv);
    try testing.expectEqualStrings("hello world", a.prompt.?);
}

test "parse: --model repeated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "llmctl", "-m", "a", "--model", "b" };
    const a = try parse(arena.allocator(), &argv);
    try testing.expectEqual(@as(usize, 2), a.models.items.len);
    try testing.expectEqualStrings("a", a.models.items[0]);
    try testing.expectEqualStrings("b", a.models.items[1]);
}

test "parse: --output ndjson" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "llmctl", "--output", "ndjson", "hi" };
    const a = try parse(arena.allocator(), &argv);
    try testing.expectEqual(OutputFormat.ndjson, a.output);
}

test "parse: --json alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "llmctl", "--json", "hi" };
    const a = try parse(arena.allocator(), &argv);
    try testing.expectEqual(OutputFormat.json, a.output);
}

test "parse: --extra collects key/value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "llmctl", "--extra", "seed=42", "--extra", "cache=true" };
    const a = try parse(arena.allocator(), &argv);
    var extra_copy = a.extra;
    try testing.expectEqual(@as(usize, 2), extra_copy.count());
    try testing.expect(extra_copy.get("seed").?.integer == 42);
    try testing.expect(extra_copy.get("cache").?.bool == true);
}

test "parse: --key=value form" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const argv = [_][:0]const u8{ "llmctl", "--temperature=0.5", "--model=gpt-4" };
    const a = try parse(arena.allocator(), &argv);
    try testing.expectEqual(@as(f32, 0.5), a.temperature.?);
    try testing.expectEqualStrings("gpt-4", a.models.items[0]);
}
