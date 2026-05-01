//! Pipeline types: Message, Delta, Usage. Per TECH-DESIGN §2.
const std = @import("std");

pub const Role = enum {
    system,
    user,
    assistant,
    tool,

    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .system => "system",
            .user => "user",
            .assistant => "assistant",
            .tool => "tool",
        };
    }
};

pub const ContentPart = union(enum) {
    text: []const u8,
    // image: ImageRef,  // P4
};

pub const Message = struct {
    role: Role,
    content: []const ContentPart,
};

pub const Usage = struct {
    input_tokens: u32 = 0,
    output_tokens: u32 = 0,

    pub fn total(self: Usage) u32 {
        return self.input_tokens + self.output_tokens;
    }

    pub fn merge(self: *Usage, other: Usage) void {
        if (other.input_tokens > 0) self.input_tokens = other.input_tokens;
        if (other.output_tokens > 0) self.output_tokens = other.output_tokens;
    }
};

pub const FinishReason = enum {
    end_turn,
    max_tokens,
    stop,
    tool_use,
    content_filter,
    other,
    unknown,

    pub fn toString(self: FinishReason) []const u8 {
        return switch (self) {
            .end_turn => "end_turn",
            .max_tokens => "max_tokens",
            .stop => "stop",
            .tool_use => "tool_use",
            .content_filter => "content_filter",
            .other => "other",
            .unknown => "unknown",
        };
    }
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments_json: []const u8,
};

/// Streaming event. MVP populates only text/usage_update/finish/noop.
/// thinking/tool_call_*/image are pre-allocated for P4 without union changes.
pub const Delta = union(enum) {
    text: []const u8,
    thinking: []const u8,
    tool_call_start: ToolCall,
    tool_call_delta: struct { id: []const u8, args_chunk: []const u8 },
    usage_update: Usage,
    finish: struct { reason: FinishReason, usage: Usage },
    noop,
};

pub const ErrorInfo = struct {
    code: ErrorCode,
    message: []const u8,
    provider: ?[]const u8 = null,
    status: ?u16 = null,
};

pub const ErrorCode = enum {
    internal,
    invalid_args,
    invalid_config,
    provider_auth_failed,
    provider_rate_limited,
    provider_api_error,
    network_error,
    timeout,
    invalid_response,
    unsupported,
    file_error,
    cancelled,

    pub fn exitCode(self: ErrorCode) u8 {
        return switch (self) {
            .internal => 1,
            .invalid_args, .invalid_config => 2,
            .provider_auth_failed => 3,
            .provider_rate_limited => 4,
            .provider_api_error => 5,
            .network_error => 6,
            .timeout => 7,
            .invalid_response => 8,
            .unsupported => 9,
            .file_error => 10,
            .cancelled => 130,
        };
    }

    pub fn toString(self: ErrorCode) []const u8 {
        return switch (self) {
            .internal => "internal",
            .invalid_args => "invalid_args",
            .invalid_config => "invalid_config",
            .provider_auth_failed => "provider_auth_failed",
            .provider_rate_limited => "provider_rate_limited",
            .provider_api_error => "provider_api_error",
            .network_error => "network_error",
            .timeout => "timeout",
            .invalid_response => "invalid_response",
            .unsupported => "unsupported",
            .file_error => "file_error",
            .cancelled => "cancelled",
        };
    }
};

pub const RequestOptions = struct {
    model: []const u8,
    messages: []const Message,
    system: ?[]const u8 = null,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    stop: ?[]const []const u8 = null,
    stream: bool = true,
    /// --extra k=v passthrough fields, merged into request JSON top-level.
    extra: std.StringHashMapUnmanaged(std.json.Value) = .empty,
};

pub const Auth = union(enum) {
    none: void,
    bearer: []const u8,
    header: struct { name: []const u8, value: []const u8 },

    pub fn applyHeaders(self: Auth, headers: *std.ArrayList(std.http.Header), gpa: std.mem.Allocator) !void {
        switch (self) {
            .none => {},
            .bearer => |token| {
                if (token.len == 0) return;
                const v = try std.fmt.allocPrint(gpa, "Bearer {s}", .{token});
                try headers.append(gpa, .{ .name = "Authorization", .value = v });
            },
            .header => |h| {
                if (h.value.len == 0) return;
                try headers.append(gpa, .{ .name = h.name, .value = h.value });
            },
        }
    }
};

test "Usage merge keeps non-zero fields" {
    var u = Usage{ .input_tokens = 10, .output_tokens = 0 };
    u.merge(.{ .input_tokens = 0, .output_tokens = 50 });
    try std.testing.expectEqual(@as(u32, 10), u.input_tokens);
    try std.testing.expectEqual(@as(u32, 50), u.output_tokens);
}

test "ErrorCode exit codes" {
    try std.testing.expectEqual(@as(u8, 3), ErrorCode.provider_auth_failed.exitCode());
    try std.testing.expectEqual(@as(u8, 130), ErrorCode.cancelled.exitCode());
}
