const std = @import("std");
const requests = @import("dap/requests.zig");
const common = @import("dap/common.zig");

pub fn main(init: std.process.Init) !u8 {
    var buffer: [1024]u8 = undefined;
    const t: std.Io.File = .stdin();
    var reader = t.reader(init.io, &buffer);
    try reader.interface.readSliceAll(buffer[0..0]);
    std.debug.print("{d}", .{buffer.len});

    _ = try readMessage(&reader.interface);
    return 0;
}

// TEST?
fn readStdin(io: std.Io) !void {
    const buffer_size = 4096;
    var read_buffer: [buffer_size]u8 = undefined;
    var reader_maybe = std.Io.File.stdin().reader(io, &read_buffer);
    var reader = &reader_maybe.interface;
    const request = try reader.takeDelimiterExclusive('\n');
    try readMessage(request);
}

const ReadError = error{
    InvalidMessageHeader,
    InvalidMessageBody,
    Wtf,
};

fn readMessage(reader: *std.Io.Reader) !common.Message {
    const content_length_str = "Content-Length:";
    var arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var content_length: u32 = 0;

    while (try reader.takeDelimiter('\n')) |header| {
        if (header.len == 0) {
            break;
        } else {
            if (std.ascii.startsWithIgnoreCase(header, content_length_str)) {
                const size_start = (std.mem.indexOf(u8, header, ":") orelse return ReadError.InvalidMessageHeader) + 1;
                const size_end = header.len;
                content_length = try std.fmt.parseInt(u32, std.mem.trim(u8, header[size_start..size_end], " \t"), 10);
            }
        }
    } else return ReadError.Wtf;

    const body_buffer = try alloc.alloc(u8, content_length);
    defer alloc.free(body_buffer);
    try reader.readSliceAll(body_buffer);
    const parsed_body = try std.json.parseFromSlice(std.json.Value, alloc, body_buffer, .{});
    if (std.meta.activeTag(parsed_body.value) != .object) {
        return ReadError.InvalidMessageBody;
    }
    const body = parsed_body.value.object;
    
    // TODO: Parse into request type
    const msg_type_json = body.get("type") orelse return ReadError.InvalidMessageBody;
    const msg_type = std.meta.stringToEnum(common.MessageType, msg_type_json.string) orelse return ReadError.InvalidMessageBody;
    const msg_cmd_json = body.get("command") orelse return ReadError.InvalidMessageBody;
    const msg_cmd = std.meta.stringToEnum(requests.Command, msg_cmd_json.string) orelse return ReadError.InvalidMessageBody;
    
    return switch (msg_type) {
        .request => .{ .request = try parseRequest(msg_cmd, &body) },
    };
}

fn parseRequest(cmd: requests.Command, body: *const std.json.ObjectMap) !requests.Request {
    _ = body;
    return switch (cmd) {
        .initialize => .{ .initialize = .{ .client_id = "CLIENT1", .adapter_id = "ADAPTER1" } },
        .setBreakpoints => .{ .setBreakpoints = .{ .source = "source.zig" } },
        else => return ReadError.Wtf,
    };
}

fn handleInitialize(cmd: *const requests.Initialize) !void {
    
}

test "test1" {
    var in: std.Io.Reader = .fixed(
        \\Content-Length: 54
        \\
        \\{
        \\  "type": "request",
        \\  "command": "setBreakpoints"
        \\}
    );
        var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    const msg = readMessage(&in) catch |err| {
        std.debug.print("WTFBRO PARSING\n", .{});
        return err;
    };
    std.debug.print("{s}", .{ msg.request.setBreakpoints.source });
}
