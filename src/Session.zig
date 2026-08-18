const std = @import("std");

const Process = @import("Process.zig");
const DebugInfo = @import("DebugInfo.zig");

const Session = @This();

process: Process,
debug_info: DebugInfo,

pub fn init(exe_path: []const u8, io: std.Io, gpa: std.mem.Allocator) !Session {
    return .{
        .debug_info = try .init(io, gpa, exe_path),
        .process = try .launch(exe_path), // TODO: Don't launch at init?
    };
}

pub fn deinit(self: *Session) void {
    self.debug_info.deinit();
}

pub fn cont(self: *Session) !void {
    try self.process.cont();
}

pub fn setBreakpoint(self: *Session, filepath: []const u8, line: u64) void {
    // TODO: get addr to hand to `process` to set the breakpoint
    _ = self;
    _ = filepath;
    _ = line;
    // self.debug_info.getLine();
}