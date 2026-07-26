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
        var cursor: Cursor = .{ .data = dies, .offset = offset };
        const cu = try dwarf_info.readCu(&cursor);
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

const Cursor = struct {
    data: []const u8,
    offset: usize,

    fn peekByte(self: Cursor) u8 {
        return self.data[self.offset];
    }

    fn readByte(self: *Cursor) u8 {
        const value = self.data[self.offset];
        self.offset += 1;
        return value;
    }

    fn readUBytes(self: *Cursor, n: u8) u64 {
        const value = std.mem.readVarInt(u64, self.data[self.offset..][0..n], builtin.cpu.arch.endian());
        self.offset += n;
        return value;
    }

    fn readBytes(self: *Cursor, n: u8) i64 {
        const u_value = self.readUBytes(n);
        const shift: u6 = @intCast((8 - n) * 8);
        return @as(i64, @bitCast(u_value << shift)) >> shift;
    }

    fn readSleb128(self: *Cursor) i64 {
        var value: i64 = 0;
        var shift: u6 = 0;
        while (true) {
            const byte = self.data[self.offset];
            value |= @as(i64, byte & 0x7f) << shift;
            self.offset += 1;
            shift += 7;
            if (byte & 0x80 == 0) {
                return value;
            }
        }
    }

    fn readUleb128(self: *Cursor) u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            const byte = self.data[self.offset];
            value |= @as(u64, byte & 0x7f) << shift;
            self.offset += 1;
            shift += 7;
            if (byte & 0x80 == 0) {
                return value;
            }
        }
    }

    fn readStrp(self: *Cursor, str_section: []const u8) []const u8 {
        const str_offset = self.readUBytes(4);
        return std.mem.sliceTo(str_section[str_offset..], 0);
    }

    fn readBlock(self: *Cursor, size: u64) []const u8 {
        self.offset += size;
        return self.data[self.offset..][0..size];
    }

    fn sliceTo(self: *Cursor, end: u8) []const u8 {
        const slice = std.mem.sliceTo(&self.data[self.offset], end);
        self.offset += slice.len + 1; // + 1 for the end byte
        return slice;
    }
};

fn getSection(dwarf: *std.debug.Dwarf, section_id: SectionId) ?[]const u8 {
    return dwarf.sections[@intFromEnum(section_id)].?.data;
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

fn readAbbrevEntry(self: *DwarfInfo, scratch: *std.ArrayList(AbbrevAttr), cursor: *Cursor) !Abbrev {
    const code = cursor.readUleb128();
    if (code == 0) {
        return .{ .code = code, .tag = 0, .has_children = false, .attributes = &.{} };
    }
    const tag = cursor.readUleb128();
    const has_children: bool = cursor.readByte() != 0;

    while (true) {
        const attr = cursor.readUleb128();
        const form = cursor.readUleb128();
        var implicit_const: i64 = 0;
        if (attr == 0 and form == 0) {
            break;
        }
        if (form == FORM.implicit_const) {
            implicit_const = cursor.readSleb128();
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
        const debug_abbrev = self.elf.dwarf.?.sections[@intFromEnum(SectionId.debug_abbrev)].?.data;
        result.value_ptr.* = .empty;
        var cursor: Cursor = .{ .data = debug_abbrev, .offset = @intCast(table) };
        try self.readAbbrevs(result.value_ptr, &cursor);
    }
    return result.value_ptr;
}

fn readAbbrevs(self: *DwarfInfo, map: *std.AutoHashMapUnmanaged(u64, Abbrev), cursor: *Cursor) !void {
    var attr_scratch: std.ArrayList(AbbrevAttr) = try .initCapacity(self.gpa, 36);
    defer attr_scratch.deinit(self.gpa);
    while (true) {
        const abbrev = try self.readAbbrevEntry(&attr_scratch, cursor);
        if (abbrev.code == 0) {
            break;
        }
        try map.put(self.arena.allocator(), abbrev.code, abbrev);
    }
}

fn readCuHeader(cursor: *Cursor) CuHeader {
    const header_start = cursor.offset;
    var unit_len = cursor.readUBytes(4);
    var len_size: u8 = 4;
    var format: u8 = 4;
    var header_len: u64 = 4 + 2 + 1 + 1 + 4;
    if (unit_len == std.math.maxInt(u32)) {
        unit_len = cursor.readUBytes(8);
        header_len += 8;
        len_size += 8;
        format = 8;
    }
    const version: u16 = @intCast(cursor.readUBytes(2));

    var unit_type: u8 = undefined;
    var addr_size: u8 = undefined;
    var debug_abbrev_offset: u32 = undefined;
    if (version >= 5) {
        unit_type = cursor.readByte();
        addr_size = cursor.readByte();
        debug_abbrev_offset = @intCast(cursor.readUBytes(4));
    } else {
        debug_abbrev_offset = @intCast(cursor.readUBytes(4));
        addr_size = cursor.readByte();
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
    cursor: *Cursor,
    parse_children: bool,
) (DwarfError || std.mem.Allocator.Error)!?Die {
    const die_offset = cursor.offset;
    const abbrev_code = cursor.readUleb128();
    if (abbrev_code == 0) {
        return null;
    }
    const abbrev = abbrevs.get(abbrev_code) orelse return DwarfError.Unknown;

    // attributes
    for (abbrev.attributes) |abbrev_attr| {
        const value = try readFormValue(cursor, abbrev_attr.form, &self.elf.dwarf.?, context.cu_header);
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
    const child_offset = cursor.offset;
    var children: ?[]const Die = null;
    if (!abbrev.has_children) {
        children = &.{};
    } else if (parse_children and abbrev.has_children) {
        children = try self.readDieChildren(context, abbrevs, cursor.data, child_offset);
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

fn readFormValue(cursor: *Cursor, form: u64, dwarf: ?*std.debug.Dwarf, header: ?*const CuHeader) !FormValue {
    const value: FormValue = switch (form) {
        FORM.data1 => .{ .uint = cursor.readUBytes(1) },
        FORM.data2 => .{ .uint = cursor.readUBytes(2) },
        FORM.data4 => .{ .uint = cursor.readUBytes(4) },
        FORM.data8 => .{ .uint = cursor.readUBytes(8) },
        FORM.data16 => .{ .uint = cursor.readUBytes(16) },
        FORM.sdata => .{ .int = cursor.readSleb128() },
        FORM.udata => .{ .uint = cursor.readUleb128() },
        FORM.flag => .{ .bool = cursor.readByte() != 0 },
        FORM.flag_present => .{ .bool = true },
        FORM.addr => .{ .ref_offset = cursor.readUBytes(header.?.addr_size) },
        FORM.strp => .{ .str = cursor.readStrp(getSection(dwarf.?, SectionId.debug_line).?) },
        FORM.line_strp => .{ .str = cursor.readStrp(getSection(dwarf.?, SectionId.debug_line_str).?) },
        FORM.ref_addr, FORM.sec_offset => .{ .ref_offset = @intCast(cursor.readUBytes(header.?.dwarf_format_byte_count)) },
        FORM.rnglistx => .{ .index = cursor.readUleb128() },
        FORM.block1 => .{ .block = cursor.readBlock(1) },
        FORM.block2 => .{ .block = cursor.readBlock(2) },
        FORM.block4 => .{ .block = cursor.readBlock(4) },
        FORM.block, FORM.exprloc => .{ .block = cursor.readBlock(cursor.readUleb128()) },
        else => return DwarfError.Unsupported,
    };
    return value;
}

fn readDieChildren(
    self: *DwarfInfo,
    context: *ParseContext,
    abbrevs: *const std.AutoHashMapUnmanaged(u64, Abbrev),
    data: []const u8,
    child_offset: u64,
) ![]const Die {
    const child_mark = context.die_scratch.items.len;
    var cursor: Cursor = .{ .data = data, .offset = child_offset };
    while (try self.readDie(context, abbrevs, &cursor, true)) |child| {
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
    attrs: CuAttrs,
};

fn readCu(self: *DwarfInfo, cursor: *Cursor) !Cu {
    const header = readCuHeader(cursor);
    const abbrevs = try self.getOrParseAbbrevs(header.debug_abbrev_offset);

    var context: ParseContext = .{
        .attr_scratch = try .initCapacity(self.gpa, 64),
        .die_scratch = .empty,
        .cu_header = &header,
    };
    defer context.attr_scratch.deinit(self.gpa);
    defer context.die_scratch.deinit(self.gpa);
    const die = try self.readDie(&context, abbrevs, cursor, false) orelse return DwarfError.Unknown;
    const cu_attrs = getCuBaseAttrs(&die);

    var cu: Cu = .{
        .header = header,
        .die = die,
        .ranges = &.{},
        .attrs = cu_attrs,
    };

    cu.ranges = try self.resolveRanges(&cu, die.attrs);

    return cu;
}

const CuAttrs = struct {
    types_base: ?u64 = null,
    rnglists_base: ?u64 = null,
    addr_base: ?u64 = null,
    low_pc: ?u64 = null,
    stmt_list: ?u64 = null,
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
        } else if (attr.attr == AT.stmt_list) {
            cu_attrs.stmt_list = attr.value.ref_offset;
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
                        const section = getSection(&self.elf.dwarf.?, SectionId.debug_rnglists);
                        const table_index: usize = cu.attrs.rnglists_base.? + index * cu.header.dwarf_format_byte_count;
                        var table_cursor: Cursor = .{ .data = section.?, .offset = table_index };
                        const list_offset = cu.attrs.rnglists_base.? + table_cursor.readUBytes(cu.header.dwarf_format_byte_count);
                        var range_cursor: Cursor = .{ .data = section.?, .offset = list_offset };
                        const attr_ranges = try self.readRangeListNew(cu, &range_cursor);
                        try ranges.appendSlice(self.gpa, attr_ranges);
                    },
                    .ref_offset => |ref_offset| {
                        // if dwarf 5 -> .debug_rnglists, else if dwarf <5 -> .debug_ranges
                        const attr_ranges = if (cu.header.version == 5) blk: {
                            var cursor: Cursor = .{ .data = getSection(&self.elf.dwarf.?, SectionId.debug_rnglists).?, .offset = ref_offset };
                            break :blk try self.readRangeListNew(cu, &cursor);
                        } else blk: {
                            var cursor: Cursor = .{ .data = getSection(&self.elf.dwarf.?, SectionId.debug_ranges).?, .offset = ref_offset };
                            break :blk try self.readRangeListOld(cu, &cursor);
                        };
                        try ranges.appendSlice(self.gpa, attr_ranges);
                    },
                    .uint => |uint| {
                        // dwarf 2/3 but same as previous prong's DWARF 4 version (direct offset)
                        std.debug.assert(cu.header.version < 5);
                        var cursor: Cursor = .{ .data = getSection(&self.elf.dwarf.?, SectionId.debug_ranges).?, .offset = uint };
                        const attr_ranges = try self.readRangeListOld(cu, &cursor);
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
fn readRangeListNew(self: *DwarfInfo, cu: *const Cu, cursor: *Cursor) ![]const model.AddrRange {
    const debug_addr = if (self.elf.dwarf.?.sections[@intFromEnum(SectionId.debug_addr)]) |section| section.data else null;
    var range_scratch: std.ArrayList(model.AddrRange) = .empty;
    defer range_scratch.deinit(self.gpa);
    var base = cu.attrs.low_pc;
    var code = cursor.readByte();

    while (code != RLE.end_of_list) {
        var start: u64 = 0;
        var end: u64 = 0;

        switch (code) {
            RLE.start_length => {
                start = cursor.readUBytes(cu.header.addr_size);
                end = start + cursor.readUleb128();
            },
            RLE.start_end => {
                start = cursor.readUBytes(cu.header.addr_size);
                end = cursor.readUBytes(cu.header.addr_size);
            },
            RLE.offset_pair => {
                std.debug.assert(base != null);
                start = base.? + cursor.readUleb128();
                end = base.? + cursor.readUleb128();
            },
            RLE.startx_length => {
                std.debug.assert(debug_addr != null);
                const startx = cursor.readUleb128();
                const length = cursor.readUleb128();
                var addr_cursor: Cursor = .{ .data = debug_addr.?, .offset = startx };
                start = addr_cursor.readUBytes(cu.header.addr_size);
                end = start + length;
            },
            RLE.startx_endx => {
                std.debug.assert(debug_addr != null);
                const startx = cursor.readUleb128();
                const endx = cursor.readUleb128();
                var start_cursor: Cursor = .{ .data = debug_addr.?, .offset = startx };
                start = start_cursor.readUBytes(cu.header.addr_size);
                var end_cursor: Cursor = .{ .data = debug_addr.?, .offset = endx };
                end = end_cursor.readUBytes(cu.header.addr_size);
            },
            RLE.base_address => {
                base = cursor.readUBytes(cu.header.addr_size);
            },
            RLE.base_addressx => {
                std.debug.assert(debug_addr != null);
                const addr_offset = cu.attrs.addr_base.? + cursor.readUleb128() * cu.header.addr_size;
                var addr_cursor: Cursor = .{ .data = debug_addr.?, .offset = addr_offset };
                base = addr_cursor.readUBytes(cu.header.addr_size);
            },
            else => return DwarfError.Unsupported,
        }

        const addr_range = try range_scratch.addOne(self.gpa);
        addr_range.* = .{ .low = start, .high = end };
        code = cursor.readByte();
    }

    if (range_scratch.items.len == 0) {
        return &.{};
    } else {
        return try self.arena.allocator().dupe(model.AddrRange, range_scratch.items);
    }
}

// Handles the DWARF <5 .debug_ranges
fn readRangeListOld(self: *DwarfInfo, cu: *const Cu, cursor: *Cursor) ![]const model.AddrRange {
    var range_scratch: std.ArrayList(model.AddrRange) = .empty;
    defer range_scratch.deinit(self.gpa);
    var base = cu.attrs.low_pc.?;
    var first = cursor.readUBytes(cu.header.addr_size);
    var second = cursor.readUBytes(cu.header.addr_size);

    while (first != 0 and second != 0) {
        std.debug.assert(cu.header.addr_size == 4 or cu.header.addr_size == 8);
        const max_int: u64 = if (cu.header.addr_size == 4) std.math.maxInt(u32) else std.math.maxInt(u64);
        if (first == max_int) {
            base = second;
            continue;
        }

        const addr_range = try range_scratch.addOne(self.gpa);
        addr_range.* = .{ .low = base + first, .high = base + second };

        first = cursor.readUBytes(cu.header.addr_size);
        second = cursor.readUBytes(cu.header.addr_size);
    }

    if (range_scratch.items.len == 0) {
        return &.{};
    } else {
        return try self.arena.allocator().dupe(model.AddrRange, range_scratch.items);
    }
}

const LineProgHeader = struct {
    unit_length: u64,
    version: u16,
    addr_size: ?u8,
    seg_selector_size: ?u8,
    header_length: u64,
    min_instruction_length: u8,
    max_ops_per_instruction: ?u8,
    default_is_stmt: u8,
    line_base: i8,
    line_range: u8,
    opcode_base: u8,
    standard_opcode_lengths: []const u8, // Length is opcode_base - 1
};

fn readLineProgHeader(self: *DwarfInfo, arena: std.mem.Allocator, cu: *const Cu) !LineProgHeader {
    var cursor: Cursor = .{ .data = getSection(self.elf.dwarf.?, SectionId.debug_line), .offset = cu.attrs.stmt_list };
    var unit_length = cursor.readUBytes(4);
    var len_size: u8 = 4;
    if (unit_length == std.math.maxInt(u32)) {
        unit_length = cursor.readUBytes(8);
        len_size += 8;
    }
    const version: u16 = @intCast(cursor.readUBytes(2));
    var addr_size: ?u8 = null;
    var seg_selector_size: ?u8 = null;
    if (version >= 5) {
        addr_size = @intCast(cursor.readUBytes(1));
        seg_selector_size = @intCast(cursor.readUBytes(1));
    }
    const header_length = cursor.readUBytes(cu.header.dwarf_format_byte_count);
    const min_instruction_length: u8 = @intCast(cursor.readUBytes(1));
    const max_ops_per_instruction: u8 = @intCast(cursor.readUBytes(1));
    const default_is_stmt: u8 = @intCast(cursor.readUBytes(1));
    const line_base: i8 = @intCast(cursor.readBytes(1));
    const line_range: u8 = @intCast(cursor.readUBytes(1));
    const opcode_base: u8 = @intCast(cursor.readUBytes(1));
    const standard_opcode_lengths = try arena.alloc(u8, opcode_base - 1);
    @memcpy(standard_opcode_lengths, cursor.data[cursor.offset..][0..(opcode_base - 1)]);

    return .{
        .unit_length = unit_length,
        .version = version,
        .addr_size = addr_size,
        .seg_selector_size = seg_selector_size,
        .header_length = header_length,
        .min_instruction_length = min_instruction_length,
        .max_ops_per_instruction = max_ops_per_instruction,
        .default_is_stmt = default_is_stmt,
        .line_base = line_base,
        .line_range = line_range,
        .opcode_base = opcode_base,
        .standard_opcode_lengths = standard_opcode_lengths,
    };
}

fn readLineProgDirsOld(header: *LineProgHeader, arena: std.mem.Allocator, data: []const u8, offset: *usize) ![]const u8 {
    std.debug.assert(header.version < 5);
    var dirs: std.ArrayList([]const u8) = .empty;
    defer dirs.deinit(arena);
    while (data[offset.*] != 0) {
        const dir = std.mem.sliceTo(&data[offset.*], 0);
        offset.* += dir.len;
        try dirs.append(arena, dir);
    }
    return try dirs.toOwnedSlice(arena);
}

const LineProgEntry = struct {
    path: []const u8 = &.{},
    dir_idx: ?u64 = null,
};

fn readLineProgFilesOld(header: *LineProgHeader, arena: std.mem.Allocator, cursor: *Cursor) ![]LineProgEntry {
    std.debug.assert(header.version >= 5);
    var files: std.ArrayList(LineProgEntry) = .empty;
    defer files.deinit(arena);
    while (cursor.peekByte() != 0) {
        const filename = cursor.sliceTo(0);
        const dir_idx = cursor.readUleb128() - 1; // - 1 because it's 1-based indices
        const mod_time = cursor.readUleb128();
        const file_length = cursor.readUleb128();
        try files.append(arena, .{ .path = filename, .dir_idx = dir_idx, .timestamp = mod_time, .size = file_length });
    }
    return try files.toOwnedSlice(arena);
}

const LineProgPathFormatEntry = struct {
    content_type: u8,
    form: u8,
};

const LNCT = enum(u64) {
    path = 0x1,
    directory_index = 0x2,
    timestamp = 0x3,
    size = 0x4,
    md5 = 0x5,
    lo_user = 0x2000,
    hi_user = 0x3fff,
};

fn readLineProgPathsNew(header: *LineProgHeader, arena: std.mem.Allocator, cursor: *Cursor) ![]LineProgEntry {
    const format_entry_count = cursor.readBytes(1);
    const max_format_entry_count = 8;
    const format_entries = [max_format_entry_count]LineProgPathFormatEntry;
    std.debug.assert(format_entry_count <= max_format_entry_count);
    for (0..format_entry_count) |i| {
        const type_code = cursor.readBytes(1);
        const form_code = cursor.readBytes(1);
        format_entries[i] = .{ .content_type = type_code, .form = form_code };
    }
    _ = header;

    const entry_count = cursor.readUleb128();
    const entries = try arena.alloc(LineProgEntry, entry_count);
    for (0..entry_count) |i| {
        for (0..format_entry_count) |u| {
            const value = try readFormValue(cursor, null, null);
            switch (format_entries[u].content_type) {
                LNCT.path => entries[i].path = value.str,
                LNCT.directory_index => entries[i].dir_idx = value,
                else => {},
            }
        }
    }
    return entries;
}

// pub fn getLines(self: *DwarfInfo) ![]model.Line {
//     const section = self.elf.dwarf.?.sections[@intFromEnum(SectionId.debug_line)].?.data;
//     _ = section;
// }

const LCNT = enum(u8) {
    path = 0x1,
    directory_index = 0x2,
    timestamp = 0x3,
    size = 0x4,
    md5 = 0x5,
};
