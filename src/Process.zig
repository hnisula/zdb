const std = @import("std");
const builtin = @import("builtin");
const DebugInfo = @import("DebugInfo.zig");
const linux = std.os.linux;

const Process = @This();

const log = std.log.scoped(.process);

pid: if (builtin.os.tag == .windows) u32 else std.posix.pid_t,
handle: if (builtin.os.tag == .windows) std.os.windows.HANDLE else void,
mem_fd: if (builtin.os.tag == .windows) void else std.posix.fd_t,

breakpoints: []const Breakpoint,

bp_to_restore: ?Breakpoint = null,

const Breakpoint = struct {
    addr: u64,
    original_byte: u8,
};

const LaunchError = error{
    Busy,
    Retry,
    OutOfMemory,
    Unsupported,
    ArgsTooBig,
    Unaccessible,
    Io,
    IsDirectory,
    Fault,
    InvalidArgs,
    NotFound,
    MultipleElfInterpreters,
    BadInterpreter,
    Loop,
    TooManyFiles,
    NameTooLong,
    NotExecutable,
    InvalidPath,
};

pub fn launch(exe_path: []const u8) !Process {
    switch (builtin.os.tag) {
        .linux => {
            var rc = linux.fork();
            switch (std.posix.errno(rc)) {
                .SUCCESS => {},
                .AGAIN => return LaunchError.Retry,
                .NOMEM => return LaunchError.OutOfMemory,
                .NOSYS => return LaunchError.Unsupported,
                else => unreachable,
            }
            const pid: std.posix.pid_t = @intCast(rc);

            if (pid == 0) {
                rc = linux.ptrace(linux.PTRACE.TRACEME, 0, 0, 0, 0);
                switch (std.posix.errno(rc)) {
                    .SUCCESS => {},
                    .FAULT => return LaunchError.Fault,
                    .INVAL => return LaunchError.InvalidArgs,
                    .IO => return LaunchError.Io,
                    .PERM => return LaunchError.Unaccessible,
                    .SRCH => return LaunchError.NotFound,
                    .BUSY => return error.Unknown,
                    else => return error.Unknown,
                }
                const posix_exe_path_copy = try std.posix.toPosixPath(exe_path);
                const posix_exe_path = std.mem.sliceTo(&posix_exe_path_copy, 0);
                rc = linux.execve(posix_exe_path, &.{null}, &.{null});
                switch (std.posix.errno(rc)) {
                    .SUCCESS => {},
                    .@"2BIG" => return LaunchError.ArgsTooBig,
                    .ACCES => return LaunchError.Unaccessible,
                    .FAULT => return LaunchError.Fault,
                    .INVAL => return LaunchError.MultipleElfInterpreters,
                    .IO => return LaunchError.Io,
                    .ISDIR => return LaunchError.IsDirectory,
                    .LIBBAD => return LaunchError.BadInterpreter,
                    .LOOP => return LaunchError.Loop,
                    .MFILE => return LaunchError.TooManyFiles,
                    .NAMETOOLONG => return LaunchError.NameTooLong,
                    .NOENT => return LaunchError.NotFound,
                    .NOEXEC => return LaunchError.NotExecutable,
                    .NOMEM => return LaunchError.OutOfMemory,
                    .NOTDIR => return LaunchError.InvalidPath,
                    .PERM => return LaunchError.Unaccessible,
                    .TXTBSY => return LaunchError.Busy,
                    else => return error.Unknown,
                }
                // TODO: Print error instead of returning
                linux.exit(127);
            }

            const process: Process = .{ .pid = pid, .handle = {}, .mem_fd = try openMem(pid), .breakpoints = &.{} };
            const stop_reason = try waitForStop(&process);
            if (stop_reason != StopReason.stopped) { // TODO: Improve error handling to be clearer?
                unreachable;
            }
            _ = linux.ptrace(linux.PTRACE.SETOPTIONS, @intCast(pid), 0, linux.PTRACE.O.EXITKILL, 0);

            return process;
        },
        else => unreachable,
    }
}

const StopReason = enum {
    stopped,
    exited,
    continued,
    terminated, // By a signal
};

const WaitError = error{
    InvalidChild,
    Interrupted,
};

pub fn waitForStop(self: *const Process) !StopReason {
    switch (builtin.os.tag) {
        .linux => {
            var status: u32 = undefined;
            const rc = linux.waitpid(self.pid, &status, 0);
            return switch (std.posix.errno(rc)) {
                .SUCCESS => blk: {
                    const W = linux.W;
                    if (W.IFSTOPPED(status)) {
                        break :blk StopReason.stopped;
                    } else if (W.IFEXITED(status)) {
                        break :blk StopReason.exited;
                    } else if (W.IFSIGNALED(status)) {
                        break :blk StopReason.terminated;
                        // } else if (W.IFCONTINUED(status)) {
                        //     break :blk StopReason.continued;
                    } else {
                        unreachable;
                    }
                },
                .CHILD => WaitError.InvalidChild,
                .INTR => WaitError.Interrupted,
                else => unreachable,
            };
        },
        else => unreachable,
    }
}

pub fn cont(self: *Process) !void {
    // TODO: This ordering will fail, FIX!
    if (self.bp_to_restore) |bp| {
        try self.resetBreakpoint(bp);
        self.bp_to_restore = null;
    }
    _ = linux.ptrace(linux.PTRACE.CONT, self.pid, 0, 0, 0);
}

const RegsError = error{
    Fault,
    Io,
    Unaccessible,
    InvalidArgs,
    NoStoppedProcess,
    Unknown,
};

const StopSignal = enum {
    breakpoint,
    trace,
    branch,
    hardware,
    unknown,
};

const PtraceError = error{
    Unknown,
};

pub fn getStopSignal(self: *const Process) !StopSignal {
    var sig_info: linux.siginfo_t = undefined;
    const rc = linux.ptrace(linux.PTRACE.GETSIGINFO, self.pid, 0, @intFromPtr(&sig_info), 0);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |e| {
            log.err("Unhandled error: {d}", .{e});
            return PtraceError.Unknown;
        },
    }
    return switch (sig_info.code) {
        1, 128 => .breakpoint, // TRAP_BRKPT, SI_KERNEL
        2 => .trace, // TRAP_TRACE
        3 => .branch, // TRAP_BRANCH
        4 => .hardware, // TRAP_HWBKPT
        else => {
            log.warn("{d}", .{sig_info.code});
            return .unknown;
        },
    };
}

pub fn readRegs(pid: i64) !GpRegs {
    var native_regs: NativeRegs = undefined;
    const rc = linux.ptrace(linux.PTRACE.GETREGS, @intCast(pid), 0, @intFromPtr(&native_regs), 0);
    return switch (std.posix.errno(rc)) {
        .SUCCESS => .{ .pc = native_regs.rip, .sp = native_regs.rsp, .fp = native_regs.rbp, .native = native_regs },
        .FAULT => RegsError.Fault,
        .INVAL => RegsError.InvalidArgs,
        .IO => RegsError.Io,
        .PERM => RegsError.Unaccessible,
        .SRCH => RegsError.NoStoppedProcess,
        else => RegsError.Unknown,
    };
}

pub fn readPc(process: *const Process) !u64 {
    const regs = try readRegs(process.pid);
    return regs.pc;
}

pub fn readSp(process: *const Process) !u64 {
    const regs = try readRegs(process.pid);
    return regs.sp;
}

pub fn readFp(process: *const Process) !u64 {
    const regs = try readRegs(process.pid);
    return regs.fp;
}

const GpRegs = struct {
    pc: u64,
    sp: u64,
    fp: u64,
    native: NativeRegs,
};

const NativeRegs = extern struct {
    r15: c_ulong,
    r14: c_ulong,
    r13: c_ulong,
    r12: c_ulong,
    rbp: c_ulong,
    rbx: c_ulong,
    r11: c_ulong,
    r10: c_ulong,
    r9: c_ulong,
    r8: c_ulong,
    rax: c_ulong,
    rcx: c_ulong,
    rdx: c_ulong,
    rsi: c_ulong,
    rdi: c_ulong,
    orig_rax: c_ulong,
    rip: c_ulong,
    cs: c_ulong,
    eflags: c_ulong,
    rsp: c_ulong,
    ss: c_ulong,
    fs_base: c_ulong,
    gs_base: c_ulong,
    ds: c_ulong,
    es: c_ulong,
    fs: c_ulong,
    gs: c_ulong,
};

fn openMem(pid: std.posix.pid_t) !std.posix.pid_t {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrintSentinel(&path_buffer, "/proc/{d}/mem", .{pid}, 0);
    const rc = linux.open(path, .{ .ACCMODE = .RDWR }, 0);
    switch (std.posix.errno(rc)) {
        .SUCCESS => return @intCast(rc),
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn readMem(self: *const Process, addr: u64, out_buffer: []u8) !void {
    const rc = linux.pread(self.mem_fd, out_buffer.ptr, out_buffer.len, @intCast(addr));
    // TODO: Check bytes read
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn writeMem(self: *const Process, addr: u64, bytes: []const u8) !void {
    const rc = linux.pwrite(self.mem_fd, bytes.ptr, bytes.len, @intCast(addr));
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn writePc(self: *const Process, pc: u64) !void {
    // TEST
    const cur_pc = try self.readPc();
    std.debug.assert(cur_pc == pc + 1);

    const offset = @offsetOf(NativeRegs, "rip");
    const rc = linux.ptrace(linux.PTRACE.POKEUSER, @intCast(self.pid), offset, @intCast(pc), 0);
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => |e| return std.posix.unexpectedErrno(e),
    }
}

pub fn getBreakpoint(self: *const Process, addr: u64) ?Breakpoint {
    for (self.breakpoints) |breakpoint| {
        if (breakpoint.addr == addr) {
            return breakpoint;
        }
    }
    return null;
}

pub fn setBreakpointAddr(self: *const Process, addr: u64) !Breakpoint {
    var orig: [1]u8 = undefined;
    try self.readMem(addr, &orig);
    try self.writeMem(addr, .{0xcc});
}

pub fn hideBreakpointAndRewind(self: *const Process, breakpoint: Breakpoint) !void {
    const bytes: [1]u8 = .{breakpoint.original_byte};
    try self.writeMem(breakpoint.addr, &bytes);
    try self.writePc(breakpoint.addr - 1);
}

pub fn resetBreakpoint(self: *const Process, breakpoint: Breakpoint) !void {
    try self.writeMem(breakpoint.addr, &.{0xcc});
}
