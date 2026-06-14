const std = @import("std");
const builtin = @import("builtin");

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;
    const debuggee_path = "zig-out/bin/sample1";

    var elf = try loadElf(gpa, io, debuggee_path);
    defer elf.deinit(gpa);

    // TODO: fork sample1 and ptrace(TRACEME) on it
    const pid = std.os.linux.fork();

    if (pid == 0) {
        std.debug.print("Still host\n", .{});
    } else {
        std.debug.print("Child proc!\n", .{});
    }
    // TODO: waitpid()
    // TODO: Read pc from regs (ptrace(GETREGS)?)
    // TODO: Map it with dwarf all the way to debug info for `sum`
    // TODO: Calculate its address (if necessary) and read /proc/<pid>/mem for its value
    // TODO: Print that beautiful shit

    return 0;
}

pub fn loadElf(gpa: std.mem.Allocator, io: std.Io, exe_path: []const u8) !std.debug.ElfFile {
    const bin_file = try std.Io.Dir.cwd().openFile(io, exe_path, .{});
    defer bin_file.close(io);
    var elf: std.debug.ElfFile = try .load(gpa, io, bin_file, null, &.none);

    const dwarf = if (elf.dwarf) |*dwarf| dwarf else {
        std.log.err("No dwarf loaded", .{});
        return error.NoDwarf;
    };
    try dwarf.open(gpa, builtin.cpu.arch.endian());
    
    return elf;
}
