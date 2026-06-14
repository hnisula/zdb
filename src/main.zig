const std = @import("std");
const requests = @import("dap/requests.zig");
const responses = @import("dap/responses.zig");
const common = @import("dap/common.zig");

pub fn main(init: std.process.Init) !u8 {
    var buffer: [1024]u8 = undefined;
    const t: std.Io.File = .stdin();
    var reader = t.reader(init.io, &buffer);
    try reader.interface.readSliceAll(buffer[0..0]);
    std.debug.print("{d}", .{buffer.len});

    _ = try readMessage(init.gpa, &reader.interface);
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

fn readMessage(arena: std.mem.Allocator, reader: *std.Io.Reader) !common.Message {
    const content_length_str = "Content-Length:";
    var content_length: u32 = 0;

    while (try reader.takeDelimiter('\n')) |header| {
        if (header.len == 1 and header[0] == '\r') {
            break;
        } else {
            if (std.ascii.startsWithIgnoreCase(header, content_length_str)) {
                const size_start = (std.mem.indexOf(u8, header, ":") orelse return ReadError.InvalidMessageHeader) + 1;
                const size_end = header.len - 1;
                content_length = try std.fmt.parseInt(u32, std.mem.trim(u8, header[size_start..size_end], " \t"), 10);
            }
        }
    } else return ReadError.Wtf;

    const body_buffer = try arena.alloc(u8, content_length);
    defer arena.free(body_buffer);
    try reader.readSliceAll(body_buffer);
    const parsed_body = try std.json.parseFromSlice(std.json.Value, arena, body_buffer, .{});
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
        .request => .{ .request = try parseRequest(arena, msg_cmd, &body) },
    };
}

fn parseRequest(arena: std.mem.Allocator, cmd: requests.Command, body: *const std.json.ObjectMap) !requests.Request {
    switch (cmd) {
        .initialize => {
            const args_json = body.get("arguments") orelse return ReadError.InvalidMessageBody;
            const args = args_json.object;
            const client_id = args.get("clientID").?.string;
            const adapter_id = args.get("adapterID").?.string;
            return .{ .initialize = .{ .client_id = try arena.dupe(u8, client_id), .adapter_id = try arena.dupe(u8, adapter_id) } };
        },
        .setBreakpoints => {
            const args_json = body.get("arguments") orelse return ReadError.InvalidMessageBody;
            const args = args_json.object;
            const source = args.get("source").?.string;
            return .{ .setBreakpoints = .{ .source = source } };
        },
        else => return ReadError.Wtf,
    }
}

fn handleInitialize(allocator: std.mem.Allocator, cmd: *const requests.Initialize) !responses.Initialize {
    // TODO: Do real init stuff
    _ = cmd;
    _ = allocator;
    return .{ .supportsCapabilitiesDoneRequest = true };
}

// TEST stuff
fn writeMsg(writer: *std.Io.Writer, msg: []const u8) !void {
    try writer.print("Content-Length: {d}\r\n\r\n{s}", .{ msg.len, msg });
}

fn writeResponse(allocator: std.mem.Allocator, writer: *std.Io.Writer, msg: anytype) !void {
    var body_writer: std.Io.Writer.Allocating = .init(allocator);
    defer body_writer.deinit();
    try std.json.Stringify.value(msg, .{ .emit_null_optional_fields = false }, &body_writer.writer);
    try body_writer.writer.flush();
    try writeMsg(writer, body_writer.written());
}

test "test1" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeMsg(&out.writer,
        \\{
        \\  "type": "request",
        \\  "command": "initialize",
        \\  "arguments": {
        \\    "clientID": "clionmaybe",
        \\    "adapterID": "zdbmaybe"
        \\  }
        \\}
    );
    var in: std.Io.Reader = .fixed(out.written());

    const msg = try readMessage(allocator, &in);
    const response = try handleInitialize(allocator, &msg.request.initialize);
    try writeResponse(allocator, &out.writer, response);
    std.debug.print("{s}", .{out.written()});
}
