const std = @import("std");
const builtin = @import("builtin");
const model = @import("model.zig");
const DwarfInfo = @This();

const SectionId = std.debug.Dwarf.Section.Id;
const AT = std.dwarf.AT;
const RLE = std.dwarf.RLE;
const TAG = std.dwarf.TAG;
const FORM = std.dwarf.FORM;

elf: std.debug.ElfFile,
gpa: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
abbrevs: std.AutoHashMapUnmanaged(u64, std.AutoHashMapUnmanaged(u64, Abbrev)),
cus: []Cu,

const InitError = error{
    NoDwarf,
};

pub fn init(io: std.Io, gpa: std.mem.Allocator, binary_path: []const u8) !DwarfInfo {
    const arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    const bin_file = try std.Io.Dir.cwd().openFile(io, binary_path, .{});
    defer bin_file.close(io);
    var elf: std.debug.ElfFile = try .load(gpa, io, bin_file, null, &.none);
    errdefer elf.deinit(gpa);
    const dwarf = if (elf.dwarf) |*dwarf| dwarf else {
        return error.NoDwarf;
    };
    try dwarf.open(gpa, builtin.cpu.arch.endian());
    var dwarf_info: DwarfInfo = .{
        .elf = elf,
        .gpa = gpa,
        .arena = arena,
        .abbrevs = .empty,
        .cus = &.{},
    };

    const dies = dwarf.sections[@intFromEnum(SectionId.debug_info)].?.data;
    var offset: usize = 0;
    var cus: std.ArrayList(Cu) = .empty;

    while (dies.len > offset) {
        const cu_offset = offset;
        const cu = try dwarf_info.readCu(dies, &offset);
        // std.debug.print("CU offset: {x}\nCU size: {x}\nCU abbr_offset: {x}\nCU range count: {d}\n---\n", .{
        //     cu.header.offset,
        //     cu.header.unit_len,
        //     cu.header.debug_abbrev_offset,
        //     cu.ranges.len,
        // });
        offset = cu_offset + cu.header.unit_len;
        try cus.append(dwarf_info.arena.allocator(), cu);
    }
    dwarf_info.cus = cus.items;

    return dwarf_info;
}

pub fn deinit(self: *DwarfInfo) void {
    self.elf.deinit(self.gpa);
    self.arena.deinit();
}

pub fn getUnits(self: *DwarfInfo, allocator: std.mem.Allocator) ![]model.Unit {
    var units: []model.Unit = try allocator.alloc(model.Unit, self.cus.len);
    for (self.cus, 0..) |cu, i| {
        units[i] = .{ .offset = cu.die.offset, .name = "", .ranges = cu.ranges };
    }
    return units;
}

fn getSection(self: *DwarfInfo, id: SectionId) []const u8 {
    return self.elf.dwarf.?.sections[@intFromEnum(id)].?.data;
}

fn readBytes(n: u8, data: []const u8, offset: *usize) u64 {
    const value = std.mem.readVarInt(u64, data[offset.*..][0..n], builtin.cpu.arch.endian());
    offset.* += n;
    return value;
}

fn readSleb128(data: []const u8, offset: *usize) i64 {
    var value: i64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = data[offset.*];
        value |= @as(i64, byte & 0x7f) << shift;
        offset.* += 1;
        shift += 7;
        if (byte & 0x80 == 0) {
            return value;
        }
    }
}

fn readUleb128(data: []const u8, offset: *usize) u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    while (true) {
        const byte = data[offset.*];
        value |= @as(u64, byte & 0x7f) << shift;
        offset.* += 1;
        shift += 7;
        if (byte & 0x80 == 0) {
            return value;
        }
    }
}

fn readStrp(data: []const u8, offset: *usize, dwarf: *std.debug.Dwarf, section_id: SectionId) []const u8 {
    const str_offset = readBytes(4, data, offset);
    return std.mem.sliceTo(dwarf.sections[@intFromEnum(section_id)].?.data[str_offset..], 0);
}

fn readBlock(size: u64, data: []const u8, offset: *usize) []const u8 {
    offset.* += size;
    return data[offset.*..][0..size];
}

const AbbrevAttr = struct {
    attr: u64,
    form: u64,
    implicit_const: i64,
};

const Abbrev = struct {
    code: u64,
    tag: u64,
    has_children: bool,
    attributes: []const AbbrevAttr,
};

const CuHeader = struct {
    offset: u64,
    dwarf_format_byte_count: u8, // Dwarf format (32 or 64 bit) in bytes (4 or 8) - Bad name for what it's used for (byte count)
    len: u64,
    unit_len: u64, // NOTE: Including length values themselves (4 or 12 bytes)
    version: u16,
    unit_type: u8,
    addr_size: u8,
    debug_abbrev_offset: u32,
};

const CompileUnit = struct {
    name: []const u8,
    has_children: bool,
};

fn readAbbrevEntry(self: *DwarfInfo, scratch: *std.ArrayList(AbbrevAttr), data: []const u8, offset: *usize) !Abbrev {
    const code = readUleb128(data, offset);
    if (code == 0) {
        return .{ .code = code, .tag = 0, .has_children = false, .attributes = &.{} };
    }
    const tag = readUleb128(data, offset);
    const has_children = data[offset.*] != 0;
    offset.* += 1;

    while (true) {
        const attr = readUleb128(data, offset);
        const form = readUleb128(data, offset);
        var implicit_const: i64 = 0;
        if (attr == 0 and form == 0) {
            break;
        }
        if (form == FORM.implicit_const) {
            implicit_const = readSleb128(data, offset);
        }
        try scratch.append(self.gpa, .{ .attr = attr, .form = form, .implicit_const = implicit_const });
    }

    var attrs: []AbbrevAttr = undefined;

    if (scratch.items.len > 0) {
        attrs = try self.arena.allocator().alloc(AbbrevAttr, scratch.items.len);
        @memcpy(attrs, scratch.items);
        scratch.clearRetainingCapacity();
    } else {
        attrs = &.{};
    }

    return .{ .code = code, .tag = tag, .has_children = has_children, .attributes = attrs };
}

fn getOrParseAbbrevs(self: *DwarfInfo, table: u64) !*std.AutoHashMapUnmanaged(u64, Abbrev) {
    const result = try self.abbrevs.getOrPut(self.arena.allocator(), table);
    if (!result.found_existing) {
        var offset = table;
        const debug_abbrev = self.elf.dwarf.?.sections[@intFromEnum(SectionId.debug_abbrev)].?.data;
        result.value_ptr.* = .empty;
        try self.readAbbrevs(result.value_ptr, debug_abbrev, &offset);
    }
    return result.value_ptr;
}

fn readAbbrevs(self: *DwarfInfo, map: *std.AutoHashMapUnmanaged(u64, Abbrev), data: []const u8, offset: *usize) !void {
    var attr_scratch: std.ArrayList(AbbrevAttr) = try .initCapacity(self.gpa, 36);
    defer attr_scratch.deinit(self.gpa);
    while (true) {
        const abbrev = try self.readAbbrevEntry(&attr_scratch, data, offset);
        if (abbrev.code == 0) {
            break;
        }
        try map.put(self.arena.allocator(), abbrev.code, abbrev);
    }
}

fn readCuHeader(data: []const u8, offset: *usize) CuHeader {
    const endian = builtin.cpu.arch.endian();
    const header_start = offset.*;
    var unit_len: u64 = @intCast(std.mem.readInt(u32, data[offset.*..][0..4], endian));
    var len_size: u8 = 4;
    var format: u8 = 4;
    offset.* += 4;
    var header_len: u64 = 4 + 2 + 1 + 1 + 4;
    if (unit_len == std.math.maxInt(u32)) {
        unit_len = std.mem.readInt(u64, data[offset.*..][0..8], endian);
        offset.* += 8;
        header_len += 8;
        len_size += 8;
        format = 8;
    }
    const version = std.mem.readInt(u16, data[offset.*..][0..2], endian);
    offset.* += 2;

    var unit_type: u8 = undefined;
    var addr_size: u8 = undefined;
    var debug_abbrev_offset: u32 = undefined;
    if (version == 5) {
        unit_type = data[offset.* + 0];
        addr_size = data[offset.* + 1];
        debug_abbrev_offset = std.mem.readInt(u32, data[offset.* + 2 ..][0..4], endian);
        offset.* += 1 + 1 + 4;
    } else {
        debug_abbrev_offset = std.mem.readInt(u32, data[offset.* + 0 ..][0..4], endian);
        addr_size = data[offset.* + 4];
        offset.* += 4 + 1;
    }
    return .{
        .offset = header_start,
        .dwarf_format_byte_count = format,
        .len = header_len,
        .unit_len = unit_len + len_size,
        .version = version,
        .unit_type = unit_type,
        .addr_size = addr_size,
        .debug_abbrev_offset = debug_abbrev_offset,
    };
}

const DieType = enum(u32) {
    compile_unit = TAG.compile_unit,
    module = TAG.module,
    subprogram = TAG.subprogram,
};

const ParseContext = struct {
    die_scratch: std.ArrayList(Die),
    attr_scratch: std.ArrayList(Attribute),
    cu_header: *const CuHeader,
};

const FormValue = union(enum) {
    uint: u64,
    int: i64,
    bool: bool,
    ref_offset: u64,
    index: u64,
    str: []const u8,
    block: []const u8,
};

const Attribute = struct {
    attr: u64,
    value: FormValue,
};

const Die = struct {
    offset: u64,
    abbrev_code: u64,
    tag: u64,
    attrs: []const Attribute,
    child_offset: u64,
    children: ?[]const Die,
};

const DwarfError = error{
    Unknown,
    Unsupported,
};

fn readDie(
    self: *DwarfInfo,
    context: *ParseContext,
    abbrevs: *const std.AutoHashMapUnmanaged(u64, Abbrev),
    data: []const u8,
    offset: *usize,
    parse_children: bool,
) (DwarfError || std.mem.Allocator.Error)!?Die {
    const die_offset = offset.*;
    const abbrev_code = readUleb128(data, offset);
    if (abbrev_code == 0) {
        return null;
    }
    const abbrev = abbrevs.get(abbrev_code) orelse return DwarfError.Unknown;

    // attributes
    for (abbrev.attributes) |abbrev_attr| {
        const value: FormValue = switch (abbrev_attr.form) {
            FORM.data1 => .{ .uint = readBytes(1, data, offset) },
            FORM.data2 => .{ .uint = readBytes(2, data, offset) },
            FORM.data4 => .{ .uint = readBytes(4, data, offset) },
            FORM.data8 => .{ .uint = readBytes(8, data, offset) },
            FORM.data16 => .{ .uint = readBytes(16, data, offset) },
            FORM.sdata => .{ .int = readSleb128(data, offset) },
            FORM.udata => .{ .uint = readUleb128(data, offset) },
            FORM.flag => .{ .bool = readBytes(1, data, offset) != 0 },
            FORM.flag_present => .{ .bool = true },
            FORM.addr => .{ .ref_offset = readBytes(context.cu_header.addr_size, data, offset) },
            FORM.strp => .{ .str = readStrp(data, offset, &self.elf.dwarf.?, SectionId.debug_str) },
            FORM.line_strp => .{ .str = readStrp(data, offset, &self.elf.dwarf.?, SectionId.debug_line_str) },
            FORM.ref_addr, FORM.sec_offset => .{ .ref_offset = @intCast(readBytes(context.cu_header.dwarf_format_byte_count, data, offset)) },
            FORM.rnglistx => .{ .index = readUleb128(data, offset) },
            FORM.block1 => .{ .block = readBlock(1, data, offset) },
            FORM.block2 => .{ .block = readBlock(2, data, offset) },
            FORM.block4 => .{ .block = readBlock(4, data, offset) },
            FORM.block, FORM.exprloc => .{ .block = readBlock(readUleb128(data, offset), data, offset) },
            else => return DwarfError.Unsupported,
        };
        var attr = try context.attr_scratch.addOneBounded();
        attr.attr = abbrev_attr.attr;
        attr.value = value;
    }
    var die_attrs: []const Attribute = &.{};
    if (context.attr_scratch.items.len > 0) {
        die_attrs = try self.arena.allocator().dupe(Attribute, context.attr_scratch.items);
    }
    context.attr_scratch.clearRetainingCapacity();

    // children
    const child_offset = offset.*;
    var children: ?[]const Die = null;
    if (!abbrev.has_children) {
        children = &.{};
    } else if (parse_children and abbrev.has_children) {
        children = try self.readDieChildren(context, abbrevs, data, child_offset);
    }

    return .{
        .offset = die_offset,
        .abbrev_code = abbrev_code,
        .tag = abbrev.tag,
        .attrs = die_attrs,
        .child_offset = child_offset,
        .children = children,
    };
}

fn readDieChildren(
    self: *DwarfInfo,
    context: *ParseContext,
    abbrevs: *const std.AutoHashMapUnmanaged(u64, Abbrev),
    data: []const u8,
    child_offset: u64,
) ![]const Die {
    const child_mark = context.die_scratch.items.len;
    var offset = child_offset;
    while (try self.readDie(context, abbrevs, data, &offset, true)) |child| {
        try context.die_scratch.append(self.gpa, child);
    }
    const child_count = context.die_scratch.items.len - child_mark;
    std.debug.assert(child_count > 0);
    const children = try self.arena.allocator().alloc(Die, child_count);
    context.die_scratch.shrinkRetainingCapacity(child_mark);

    return children;
}

const Cu = struct {
    header: CuHeader,
    die: Die,
    ranges: []const model.AddrRange,
    low_pc: ?u64,
    rnglists_base: ?u64,
    types_base: ?u64,
    addr_base: ?u64,
};

fn readCu(self: *DwarfInfo, data: []const u8, offset: *usize) !Cu {
    const header = readCuHeader(data, offset);
    const abbrevs = try self.getOrParseAbbrevs(header.debug_abbrev_offset);

    var context: ParseContext = .{
        .attr_scratch = try .initCapacity(self.gpa, 64),
        .die_scratch = .empty,
        .cu_header = &header,
    };
    defer context.attr_scratch.deinit(self.gpa);
    defer context.die_scratch.deinit(self.gpa);
    const die = try self.readDie(&context, abbrevs, data, offset, false) orelse return DwarfError.Unknown;
    const cu_attrs = getCuBaseAttrs(&die);

    var cu: Cu = .{
        .header = header,
        .die = die,
        .ranges = &.{},
        .low_pc = cu_attrs.low_pc,
        .rnglists_base = cu_attrs.rnglists_base,
        .types_base = cu_attrs.types_base,
        .addr_base = cu_attrs.addr_base,
    };

    cu.ranges = try self.resolveRanges(&cu, die.attrs);

    return cu;
}

const CuAttrs = struct {
    types_base: ?u64 = null,
    rnglists_base: ?u64 = null,
    addr_base: ?u64 = null,
    low_pc: ?u64 = null,
};

fn getCuBaseAttrs(die: *const Die) CuAttrs {
    var cu_attrs: CuAttrs = .{};

    for (die.attrs) |attr| {
        if (attr.attr == AT.rnglists_base) {
            cu_attrs.rnglists_base = attr.value.ref_offset;
        } else if (attr.attr == AT.base_types) {
            cu_attrs.types_base = attr.value.ref_offset;
        } else if (attr.attr == AT.addr_base) {
            cu_attrs.addr_base = attr.value.ref_offset;
        } else if (attr.attr == AT.low_pc) {
            cu_attrs.low_pc = attr.value.ref_offset;
        }
    }

    return cu_attrs;
}

fn resolveRanges(self: *DwarfInfo, cu: *const Cu, attrs: []const Attribute) ![]const model.AddrRange {
    var ranges: std.ArrayList(model.AddrRange) = .empty;
    defer ranges.deinit(self.gpa);
    var low_pc: ?u64 = null;
    var high_pc: ?u64 = null;
    var high_pc_is_addr = false;

    for (attrs) |attr| {
        switch (attr.attr) {
            AT.low_pc => low_pc = attr.value.ref_offset,
            AT.high_pc => {
                switch (attr.value) {
                    .ref_offset => |offset| {
                        high_pc = offset;
                        high_pc_is_addr = true;
                    },
                    .uint => |length| high_pc = length,
                    else => return DwarfError.Unsupported,
                }
            },
            AT.ranges => {
                switch (attr.value) {
                    .index => |index| {
                        // dwarf 5 -> debug_rnglists (with rnglists_base and index/offset size)
                        std.debug.assert(cu.header.version >= 5);
                        const section = self.elf.dwarf.?.sections[@intFromEnum(SectionId.debug_rnglists)].?.data;
                        var table_index: usize = cu.rnglists_base.? + index * cu.header.dwarf_format_byte_count;
                        var list_offset = cu.rnglists_base.? + readBytes(cu.header.dwarf_format_byte_count, section, &table_index);
                        const offset = &list_offset;
                        const attr_ranges = try self.readRangeListNew(
                            cu,
                            section,
                            offset,
                        );
                        try ranges.appendSlice(self.gpa, attr_ranges);
                    },
                    .ref_offset => |ref_offset| {
                        // if dwarf 5 -> .debug_rnglists, else if dwarf <5 -> .debug_ranges
                        const attr_ranges = if (cu.header.version == 5) blk: {
                            var offset = ref_offset;
                            break :blk try self.readRangeListNew(
                                cu,
                                self.elf.dwarf.?.sections[@intFromEnum(SectionId.debug_rnglists)].?.data,
                                &offset,
                            );
                        } else blk: {
                            var offset = ref_offset;
                            break :blk try self.readRangeListOld(
                                cu,
                                self.elf.dwarf.?.sections[@intFromEnum(SectionId.debug_ranges)].?.data,
                                &offset,
                            );
                        };
                        try ranges.appendSlice(self.gpa, attr_ranges);
                    },
                    .uint => |uint| {
                        // dwarf 2/3 but same as previous prong's DWARF 4 version (direct offset)
                        std.debug.assert(cu.header.version < 5);
                        var offset = uint;
                        const attr_ranges = try self.readRangeListOld(
                            cu,
                            self.elf.dwarf.?.sections[@intFromEnum(SectionId.debug_ranges)].?.data,
                            &offset,
                        );
                        try ranges.appendSlice(self.gpa, attr_ranges);
                    },
                    else => return DwarfError.Unsupported,
                }
                // rngslists_base ONLY for rnglistx: rnglists_base + index (the attr value?) * offset_size
                // sec_offset FORM is a direct offset into .debug_ranges or .debug_rnglists ???
            },
            else => {},
        }
    }

    return try self.arena.allocator().dupe(model.AddrRange, ranges.items);
}

// Handles the DWARF 5+ .debug_rnglists
fn readRangeListNew(self: *DwarfInfo, cu: *const Cu, data: []const u8, offset: *usize) ![]const model.AddrRange {
    const debug_addr = if (self.elf.dwarf.?.sections[@intFromEnum(SectionId.debug_addr)]) |section| section.data else null;
    var range_scratch: std.ArrayList(model.AddrRange) = .empty;
    defer range_scratch.deinit(self.gpa);
    var base = cu.low_pc;
    var code = data[offset.*];
    offset.* += 1;

    while (code != RLE.end_of_list) {
        var start: u64 = 0;
        var end: u64 = 0;

        switch (code) {
            RLE.start_length => {
                start = readBytes(cu.header.addr_size, data, offset);
                end = start + readUleb128(data, offset);
            },
            RLE.start_end => {
                start = readBytes(cu.header.addr_size, data, offset);
                end = readBytes(cu.header.addr_size, data, offset);
            },
            RLE.offset_pair => {
                std.debug.assert(base != null);
                start = base.? + readUleb128(data, offset);
                end = base.? + readUleb128(data, offset);
            },
            RLE.startx_length => {
                std.debug.assert(debug_addr != null);
                var startx = readUleb128(data, offset);
                const length = readUleb128(data, offset);
                start = readBytes(cu.header.addr_size, debug_addr.?, &startx);
                end = start + length;
            },
            RLE.startx_endx => {
                std.debug.assert(debug_addr != null);
                var startx = readUleb128(data, offset);
                var endx = readUleb128(data, offset);
                start = readBytes(cu.header.addr_size, debug_addr.?, &startx);
                end = readBytes(cu.header.addr_size, debug_addr.?, &endx);
            },
            RLE.base_address => {
                base = readBytes(cu.header.addr_size, data, offset);
            },
            RLE.base_addressx => {
                std.debug.assert(debug_addr != null);
                var addr_offset = cu.addr_base.? + readUleb128(data, offset) * cu.header.addr_size;
                base = readBytes(cu.header.addr_size, debug_addr.?, &addr_offset);
            },
            else => return DwarfError.Unsupported,
        }

        const addr_range = try range_scratch.addOne(self.gpa);
        addr_range.* = .{ .low = start, .high = end };
        code = data[offset.*];
        offset.* += 1;
    }

    if (range_scratch.items.len == 0) {
        return &.{};
    } else {
        return try self.arena.allocator().dupe(model.AddrRange, range_scratch.items);
    }
}

// Handles the DWARF <5 .debug_ranges
fn readRangeListOld(self: *DwarfInfo, cu: *const Cu, data: []const u8, offset: *usize) ![]const model.AddrRange {
    var range_scratch: std.ArrayList(model.AddrRange) = .empty;
    defer range_scratch.deinit(self.gpa);
    var base = cu.low_pc.?;
    var first = readBytes(cu.header.addr_size, data, offset);
    var second = readBytes(cu.header.addr_size, data, offset);

    while (first != 0 and second != 0) {
        std.debug.assert(cu.header.addr_size == 4 or cu.header.addr_size == 8);
        const max_int: u64 = if (cu.header.addr_size == 4) std.math.maxInt(u32) else std.math.maxInt(u64);
        if (first == max_int) {
            base = second;
            continue;
        }

        const addr_range = try range_scratch.addOne(self.gpa);
        addr_range.* = .{ .low = base + first, .high = base + second };

        first = readBytes(cu.header.addr_size, data, offset);
        second = readBytes(cu.header.addr_size, data, offset);
    }

    if (range_scratch.items.len == 0) {
        return &.{};
    } else {
        return try self.arena.allocator().dupe(model.AddrRange, range_scratch.items);
    }
}
