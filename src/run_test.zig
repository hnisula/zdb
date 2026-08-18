const std = @import("std");
const linux = std.os.linux;
const builtin = @import("builtin");

const DebugInfo = @import("DebugInfo.zig");
const Process = @import("Process.zig");

const log = std.log.scoped(.run_test);
pub const std_options: std.Options = .{
    .log_level = .debug,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const exe_path = "zig-out/bin/sample1";

    try traceInferior(io, gpa, exe_path);

    // TODO: Map it with dwarf all the way to debug info for `sum`

    // TODO: Implement die tree traversal to find locals and stuff

    // TODO: Calculate its address (if necessary) and read /proc/<pid>/mem for its value
    // TODO: Print that beautiful shit

    return 0;
}

pub fn traceInferior(io: std.Io, gpa: std.mem.Allocator, exe_path: []const u8) !void {
    var debug_info: DebugInfo = try .init(io, gpa, exe_path);
    defer debug_info.deinit();

    var process = try Process.launch(exe_path);
    try process.cont();

    while (true) {
        const stop_reason = try process.waitForStop();

        if (stop_reason != .stopped) {
            log.info("Process stopped (probably). Bye", .{});
            break;
        }

        // Read and process command
        

        // Keep debugging
        const addr = try process.readPc();

        log.debug("Stop reason: {}", .{stop_reason});
        const stop_signal = try process.getStopSignal();
        log.debug("Stop signal: {}", .{stop_signal});
        const prev_addr = addr - 1;
        var prev_instruction: [1]u8 = undefined;
        try process.readMem(prev_addr, &prev_instruction);
        if (prev_instruction[0] == 0xcc) {
            if (process.getBreakpoint(prev_addr)) |bp| {
                try process.hideBreakpointAndRewind(bp);
                process.bp_to_restore = bp;
            }
        } else {
            // stepping? check anything?
        }

        switch (stop_reason) {
            .exited, .terminated => {
                log.info("StopReason = {s}", .{@tagName(stop_reason)});
                break;
            },
            else => {},
        }

        if (process.getBreakpoint(addr)) |bp| {
            try process.hideBreakpointAndRewind(bp);
        }
        const cu = debug_info.getUnit(addr);
        const line_info = try debug_info.lineForAddr(addr);
        log.info("Stopped at addr: 0x{x}", .{addr});
        if (line_info) |li| {
            const line = try debug_info.lineText(&li);
            log.debug("{s}:{d}:{d}", .{ li.file, li.line, li.column });
            log.info("{s}", .{line});
        } else {
            log.warn("No line found", .{});
        }
        _ = cu;
        try process.cont();
    }
}
