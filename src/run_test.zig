const std = @import("std");
const linux = std.os.linux;
const builtin = @import("builtin");
const control = @import("control.zig");
const DwarfInfo = @import("DwarfInfo.zig");

pub fn main(init: std.process.Init) !u8 {
    const endian = builtin.cpu.arch.endian();
    const gpa = init.gpa;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const io = init.io;
    const exe_path = "zig-out/bin/sample1";

    var dw = try DwarfInfo.init(gpa, io, exe_path);
    defer dw.deinit();
    // var elf = try loadElf(gpa, io, exe_path);
    // defer elf.deinit(gpa);
    // var dwarf = elf.dwarf.?;

    const pid = try control.launch(exe_path);
    control.cont(pid);

    _ = try control.waitForStop(pid);
    const pc = try control.readPc(pid);
    _ = pc;
    _ = a;
    _ = endian;
    // const cu = try dw.dwarf.findCompileUnit(endian, pc);
    // std.debug.print("{s}", .{cu.die.getAttrString(dw.dwarf, endian, std.dwarf.AT.name, null, cu) catch "?"});
    // const line = try dw.dwarf.getLineNumberInfo(gpa, a, endian, cu, pc);
    // const symbol_name = dw.dwarf.getSymbolName(pc) orelse "NOOOO";
    // std.debug.print("{s}:{d} - {s}\n", .{ line.file_name, line.line, symbol_name });

    // TODO: Map it with dwarf all the way to debug info for `sum`

    // TODO: Implement die tree traversal to find locals and stuff

    // TODO: Calculate its address (if necessary) and read /proc/<pid>/mem for its value
    // TODO: Print that beautiful shit

    return 0;
}

const RunError = error{
    DebugReg,
    Fault,
    InvalidArgument,
    Io,
    Untraceable,
    NotFound,
};

pub fn runProcess(debuggee_path: [:0]const u8) !void {
    var rc = linux.ptrace(linux.PTRACE.TRACEME, 0, 0, 0, 0);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        .BUSY => return RunError.DebugReg,
        .FAULT => return RunError.Fault,
        .INVAL => return RunError.InvalidArgument,
        .IO => return RunError.Io,
        .PERM => return RunError.Untraceable,
        .SRCH => return RunError.NotFound,
        else => return error.Unknown,
    }
    rc = linux.execve(debuggee_path, &.{null}, &.{null});
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => std.debug.print("FAILED exceve()\n", .{}),
    }
}

pub fn waitForProcess(pid: i32) void {
    const W = std.posix.W;
    var status: u32 = 0;
    const rc = linux.waitpid(pid, &status, 0);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => std.debug.print("waitpid() failed\n", .{}),
    }
    if (W.IFSTOPPED(status)) {
        std.debug.print("waitpid(): STOPPED ({d})\n", .{W.STOPSIG(status)});
    } else if (W.IFEXITED(status)) {
        std.debug.print("waitpid(): EXITED\n", .{});
    } else if (W.IFSIGNALED(status)) {
        std.debug.print("waitpid(): SIGNALED\n", .{});
    }
}

pub fn loadElf(gpa: std.mem.Allocator, io: std.Io, exe_path: []const u8) !std.debug.ElfFile {
    const bin_file = try std.Io.Dir.cwd().openFile(io, exe_path, .{});
    defer bin_file.close(io);
    var elf: std.debug.ElfFile = try .load(gpa, io, bin_file, null, &.none);

    const dwarf = if (elf.dwarf) |*dwarf| dwarf else {
        std.log.err("No dwarf loaded\n", .{});
        return error.NoDwarf;
    };
    try dwarf.open(gpa, builtin.cpu.arch.endian());

    return elf;
}

