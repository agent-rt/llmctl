//! API key / Authorization redaction. Per TECH-DESIGN §16.
//! Simple substring/pattern scrub for use in verbose / dry-run / error output.
const std = @import("std");

/// Scrub `Authorization: Bearer <token>` and `x-api-key: <token>` style values
/// in a header or text blob. Returns a newly-allocated string with replacements.
pub fn redact(gpa: std.mem.Allocator, input: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, input.len);

    var i: usize = 0;
    while (i < input.len) {
        // Look for "sk-" prefix (OpenAI-style keys, 16+ chars).
        if (i + 3 < input.len and input[i] == 's' and input[i + 1] == 'k' and input[i + 2] == '-') {
            var j = i + 3;
            while (j < input.len and (std.ascii.isAlphanumeric(input[j]) or input[j] == '_' or input[j] == '-')) j += 1;
            if (j - (i + 3) >= 16) {
                try out.appendSlice(gpa, "sk-***");
                i = j;
                continue;
            }
        }
        // Look for "Bearer " followed by token.
        if (i + 7 <= input.len and std.ascii.eqlIgnoreCase(input[i .. i + 7], "Bearer ")) {
            try out.appendSlice(gpa, input[i .. i + 7]);
            i += 7;
            var j = i;
            while (j < input.len and !std.ascii.isWhitespace(input[j])) j += 1;
            if (j > i) {
                try out.appendSlice(gpa, "***");
                i = j;
                continue;
            }
        }
        try out.append(gpa, input[i]);
        i += 1;
    }

    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "redact OpenAI key" {
    const r = try redact(testing.allocator, "key is sk-abc123def456ghi789jkl in body");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("key is sk-*** in body", r);
}

test "redact Bearer token" {
    const r = try redact(testing.allocator, "Authorization: Bearer abc.def.ghi");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("Authorization: Bearer ***", r);
}

test "short sk- not redacted" {
    const r = try redact(testing.allocator, "sk-short");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("sk-short", r);
}

test "no match passthrough" {
    const r = try redact(testing.allocator, "hello world");
    defer testing.allocator.free(r);
    try testing.expectEqualStrings("hello world", r);
}
