//! HTTP client wrapper around std.http.Client. Streams response body via callback.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const StreamResult = struct {
    status: u16,
    /// If non-2xx, body is collected into this slice (arena-owned). Empty otherwise.
    error_body: []const u8 = "",
};

pub const ChunkCallback = *const fn (ctx: *anyopaque, chunk: []const u8) anyerror!void;

pub const StreamOptions = struct {
    method: std.http.Method = .POST,
    url: []const u8,
    body: []const u8,
    headers: []const std.http.Header,
    on_chunk: ChunkCallback,
    ctx: *anyopaque,
};

/// Open a connection, send body, then stream response chunks to the callback.
/// On non-2xx, the response body is collected (up to 64 KiB) and returned in result.error_body.
pub fn stream(
    gpa: Allocator,
    io: std.Io,
    arena: Allocator,
    opts: StreamOptions,
) !StreamResult {
    const uri = try std.Uri.parse(opts.url);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var req = try client.request(opts.method, uri, .{
        .extra_headers = opts.headers,
        .keep_alive = false,
    });
    defer req.deinit();

    // Send body.
    req.transfer_encoding = .{ .content_length = opts.body.len };
    var send_buf: [4096]u8 = undefined;
    var bw = try req.sendBodyUnflushed(&send_buf);
    try bw.writer.writeAll(opts.body);
    try bw.end();
    try req.connection.?.flush();

    // Receive head.
    var redirect_buf: [4096]u8 = undefined;
    var resp = try req.receiveHead(&redirect_buf);
    const status: u16 = @intFromEnum(resp.head.status);

    // Read body — small transfer buffer for low-latency streaming.
    var transfer_buf: [4096]u8 = undefined;
    const reader = resp.reader(&transfer_buf);

    if (status < 200 or status >= 300) {
        // Collect error body (capped) and return.
        var collected: std.ArrayList(u8) = .empty;
        const cap_limit: usize = 64 * 1024;
        var read_chunk: [4096]u8 = undefined;
        while (collected.items.len < cap_limit) {
            const n = try reader.readSliceShort(&read_chunk);
            if (n == 0) break;
            const take = @min(n, cap_limit - collected.items.len);
            try collected.appendSlice(arena, read_chunk[0..take]);
        }
        return .{ .status = status, .error_body = collected.items };
    }

    // 2xx: stream to callback.
    var read_chunk: [4096]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&read_chunk);
        if (n == 0) break;
        try opts.on_chunk(opts.ctx, read_chunk[0..n]);
    }
    return .{ .status = status };
}
