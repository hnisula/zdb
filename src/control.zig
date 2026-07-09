const std = @import("std");
const builtin = @import("builtin");
const linux = std.os.linux;

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

pub fn waitForStop(pid: i64) !StopReason {
    switch (builtin.os.tag) {
        .linux => {
            var status: u32 = undefined;
            const rc = linux.waitpid(@intCast(pid), &status, 0);
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

pub fn cont(pid: i64) void {
    _ = linux.ptrace(linux.PTRACE.CONT, @intCast(pid), 0, 0, 0);
}

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

pub fn launch(exe_path: []const u8) !i64 {
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
            const pid: i64 = @intCast(rc);

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

            const stop_reason = try waitForStop(pid);
            if (stop_reason != StopReason.stopped) { // TODO: Improve error handling to be clearer?
                unreachable;
            }
            _ = linux.ptrace(linux.PTRACE.SETOPTIONS, @intCast(pid), 0, linux.PTRACE.O.EXITKILL, 0);

            return pid;
        },
        else => unreachable,
    }
}

const RegsError = error{
    Fault,
    Io,
    Unaccessible,
    InvalidArgs,
    NoStoppedProcess,
    Unknown,
};

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

pub fn readPc(pid: i64) !u64 {
    const regs = try readRegs(pid);
    return regs.pc;
}
pub fn readSp(pid: i64) !u64 {
    const regs = try readRegs(pid);
    return regs.sp;
}
pub fn readFp(pid: i64) !u64 {
    const regs = try readRegs(pid);
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
