const std = @import("std");

pub const AddrRange = struct {
    low: u64,
    high: u64,
};

pub const Line = struct {
    addr: u64,
    line: u64,
    column: u64,
    file: []const u8,
    is_stmt: bool,
    prologue_end: bool,
    end_sequence: bool,
};

pub const Unit = struct {
    offset: u64, // Some debug format internal value (e.g. byte offset in DWARF)
    name: []const u8,
    ranges: []const AddrRange,
};

pub const Function = struct {
    name: []const u8,
};
