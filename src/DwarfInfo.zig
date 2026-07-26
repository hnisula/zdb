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

const Form = enum(u64) {
    data1 = FORM.data1,
    data2 = FORM.data2,
    data4 = FORM.data4,
    data8 = FORM.data8,
    data16 = FORM.data16,
    sdata = FORM.sdata,
    udata = FORM.udata,
    flag = FORM.flag,
    flag_present = FORM.flag_present,
    strp = FORM.strp,
    line_strp = FORM.line_strp,
    addr = FORM.addr,
    ref_addr = FORM.ref_addr,
    rnglistx = FORM.rnglistx,
    block1 = FORM.block1,
    block2 = FORM.block2,
    block4 = FORM.block4,
    block = FORM.block,
    implicit_const = FORM.implicit_const,
    sec_offset = FORM.sec_offset,
    exprloc = FORM.exprloc,
    _,
};

const Lnct = enum(u64) {
    path = 0x1,
    directory_index = 0x2,
    timestamp = 0x3,
    size = 0x4,
    md5 = 0x5,
    lo_user = 0x2000,
    llvm_source = 0x2001,
    hi_user = 0x3fff,
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

pub fn getCu(self: *DwarfInfo, addr: u64) ?*const Cu {
    for (self.cus) |cu| {
        for (cu.ranges) |range| {
            if (range.low <= addr and addr <= range.high) {
                return &cu;
            }
        }
    }
    return null;
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

    fn sliceTo(self: *Cursor, comptime end: u8) []const u8 {
        const slice = std.mem.sliceTo(self.data[self.offset..], end);
        self.offset += slice.len + 1; // + 1 for the end byte
        return slice;
    }

    fn skip(self: *Cursor, n: u64) void {
        self.offset += n;
    }
};

fn getSection(dwarf: *std.debug.Dwarf, section_id: SectionId) ?[]const u8 {
    return dwarf.sections[@intFromEnum(section_id)].?.data;
}

const AbbrevAttr = struct {
    attr: u64,
    form: Form,
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
        const form_raw = cursor.readUleb128();
        var implicit_const: i64 = 0;
        if (attr == 0 and form_raw == 0) {
            break;
        }
        const form: Form = @enumFromInt(form_raw);
        if (form == Form.implicit_const) {
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

fn readFormValue(cursor: *Cursor, form: Form, dwarf: ?*std.debug.Dwarf, header: ?*const CuHeader) !FormValue {
    const value: FormValue = switch (form) {
        .data1 => .{ .uint = cursor.readUBytes(1) },
        .data2 => .{ .uint = cursor.readUBytes(2) },
        .data4 => .{ .uint = cursor.readUBytes(4) },
        .data8 => .{ .uint = cursor.readUBytes(8) },
        .data16 => .{ .uint = cursor.readUBytes(16) },
        .sdata => .{ .int = cursor.readSleb128() },
        .udata => .{ .uint = cursor.readUleb128() },
        .flag => .{ .bool = cursor.readByte() != 0 },
        .flag_present => .{ .bool = true },
        .addr => .{ .ref_offset = cursor.readUBytes(header.?.addr_size) },
        .strp => .{ .str = cursor.readStrp(getSection(dwarf.?, SectionId.debug_line).?) },
        .line_strp => .{ .str = cursor.readStrp(getSection(dwarf.?, SectionId.debug_line_str).?) },
        .ref_addr, .sec_offset => .{ .ref_offset = @intCast(cursor.readUBytes(header.?.dwarf_format_byte_count)) },
        .rnglistx => .{ .index = cursor.readUleb128() },
        .block1 => .{ .block = cursor.readBlock(1) },
        .block2 => .{ .block = cursor.readBlock(2) },
        .block4 => .{ .block = cursor.readBlock(4) },
        .block, .exprloc => .{ .block = cursor.readBlock(cursor.readUleb128()) },
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
    attrs: CuAttrs,
    ranges: []const model.AddrRange,
    lines_loaded: bool = false,
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
    default_is_stmt: bool,
    line_base: i8,
    line_range: u8,
    opcode_base: u8,
    standard_opcode_lengths: []const u8, // Length is opcode_base - 1
    program_start: u64, // NOTE: These values are relative to the header start and must be correct when executing the line program
    program_end: u64, // NOTE: And this one
    format: u8,
};

fn readLineProgHeader(arena: std.mem.Allocator, cu: *const Cu, cursor: *Cursor) !LineProgHeader {
    // TODO: Remove if unused
    _ = cu;

    var unit_length = cursor.readUBytes(4);
    var format: u8 = 4;
    var len_size: u8 = 4;
    if (unit_length == std.math.maxInt(u32)) {
        unit_length = cursor.readUBytes(8);
        len_size += 8;
        format = 8;
    }
    const program_end = cursor.offset + unit_length;
    const version: u16 = @intCast(cursor.readUBytes(2));
    var addr_size: ?u8 = null;
    var seg_selector_size: ?u8 = null;
    if (version >= 5) {
        addr_size = @intCast(cursor.readUBytes(1));
        seg_selector_size = @intCast(cursor.readUBytes(1));
    }
    const header_length = cursor.readUBytes(format);
    const program_start = cursor.offset + header_length;
    const min_instruction_length: u8 = @intCast(cursor.readUBytes(1));
    const max_ops_per_instruction: u8 = @intCast(cursor.readUBytes(1));
    const default_is_stmt: bool = cursor.readByte() != 0;
    const line_base: i8 = @intCast(cursor.readBytes(1));
    const line_range: u8 = @intCast(cursor.readUBytes(1));
    const opcode_base: u8 = @intCast(cursor.readUBytes(1));

    const opcode_block_length = opcode_base - 1;
    const standard_opcode_lengths = try arena.alloc(u8, opcode_block_length);
    @memcpy(standard_opcode_lengths, cursor.data[cursor.offset..][0..opcode_block_length]);
    cursor.skip(opcode_block_length);

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
        .program_start = program_start,
        .program_end = program_end,
        .format = format,
    };
}

fn readLineProgDirsOld(header: *const LineProgHeader, arena: std.mem.Allocator, cursor: *Cursor) ![]LineProgPath {
    std.debug.assert(header.version < 5);
    var dirs: std.ArrayList(LineProgPath) = .empty;
    defer dirs.deinit(arena);
    while (cursor.peekByte() != 0) {
        const dir = cursor.sliceTo(0);
        try dirs.append(arena, .{ .path = dir });
    }
    return try dirs.toOwnedSlice(arena);
}

const LineProgPath = struct {
    path: []const u8 = &.{},
    dir_idx: ?u64 = null,
};

fn readLineProgFilesOld(header: *const LineProgHeader, arena: std.mem.Allocator, cursor: *Cursor) ![]LineProgPath {
    std.debug.assert(header.version >= 5);
    var files: std.ArrayList(LineProgPath) = .empty;
    defer files.deinit(arena);
    while (cursor.peekByte() != 0) {
        const filename = cursor.sliceTo(0);
        const dir_idx = cursor.readUleb128() - 1; // - 1 because it's 1-based indices
        _ = cursor.readUleb128();
        _ = cursor.readUleb128();
        try files.append(arena, .{ .path = filename, .dir_idx = dir_idx });
    }
    return try files.toOwnedSlice(arena);
}

const LineProgPathFormatEntry = struct {
    content_type: Lnct,
    form: Form,
};

fn readLineProgPathsNew(arena: std.mem.Allocator, cursor: *Cursor, cu_header: *const CuHeader, dwarf: *std.debug.Dwarf) ![]LineProgPath {
    const format_entry_count = cursor.readBytes(1);
    const max_format_entry_count = 8;
    var format_entries: [max_format_entry_count]LineProgPathFormatEntry = undefined;
    std.debug.assert(format_entry_count <= max_format_entry_count);
    for (0..@intCast(format_entry_count)) |i| {
        const type_code = cursor.readUleb128();
        const form_code = cursor.readUleb128();
        format_entries[i] = .{ .content_type = @enumFromInt(type_code), .form = @enumFromInt(form_code) };
    }

    const entry_count = cursor.readUleb128();
    const entries = try arena.alloc(LineProgPath, entry_count);
    for (0..entry_count) |i| {
        for (0..@intCast(format_entry_count)) |u| {
            const value = try readFormValue(cursor, format_entries[u].form, dwarf, cu_header);
            switch (format_entries[u].content_type) {
                .path => entries[i].path = value.str,
                .directory_index => entries[i].dir_idx = value.uint,
                else => {},
            }
        }
    }
    return entries;
}

const LineProgRegs = struct {
    address: u64,
    op_index: u64,
    file: u64,
    line: u64,
    column: u64,
    isa: u64,
    discriminator: u64,
    is_stmt: bool,
    end_sequence: bool,
    basic_block: bool,
    prologue_end: bool,
    epilogue_begin: bool,

    fn initial(header: *const LineProgHeader) LineProgRegs {
        return .{
            .address = 0,
            .op_index = 0,
            .file = 1,
            .line = 1,
            .column = 0,
            .isa = 0,
            .is_stmt = header.default_is_stmt,
            .end_sequence = false,
            .discriminator = 0,
            .basic_block = false,
            .prologue_end = false,
            .epilogue_begin = false,
        };
    }

    fn resetFull(self: *LineProgRegs, header: *const LineProgHeader) void {
        self.* = initial(header);
    }

    fn resetPostEmit(self: *LineProgRegs) void {
        self.discriminator = 0;
        self.basic_block = false;
        self.prologue_end = false;
        self.epilogue_begin = false;
    }

    fn emitLine(self: *LineProgRegs, allocator: std.mem.Allocator, dirs: []const LineProgPath, files: []const LineProgPath) !LineProgLine {
        const filename = files[self.file].path;
        const dirpath = dirs[files[self.file].dir_idx.?].path;
        return .{
            .addr = self.address,
            .file = try std.fs.path.join(allocator, &.{ dirpath, filename }),
            .line = self.line,
            .column = self.column,
            .prologue_end = self.prologue_end,
            .end_sequence = self.end_sequence,
            .is_stmt = self.is_stmt,
        };
    }
};

const LNS = enum(u8) {
    extended_op = 0x0,
    copy = 0x1,
    advance_pc = 0x2,
    advance_line = 0x3,
    set_file = 0x4,
    set_column = 0x5,
    negate_stmt = 0x6,
    set_basic_block = 0x7,
    const_add_pc = 0x8,
    fixed_advance_pc = 0x9,
    set_prologue_end = 0xa,
    set_epilogue_begin = 0xb,
    set_isa = 0xc,
};

const LNE = enum(u8) {
    end_sequence = 0x1,
    set_address = 0x2,
    define_file = 0x3,
    set_discriminator = 0x4,
    _,
};

const LineProgLine = struct {
    addr: u64,
    file: []const u8,
    line: u64,
    column: u64,
    prologue_end: bool,
    end_sequence: bool,
    is_stmt: bool,
};

// NOTE: The cursor used here MUST have its offset relative to the start of the line program header for `program_end` to be correct
fn executeLineProg(header: *const LineProgHeader, cu: *const Cu, gpa: std.mem.Allocator, arena: std.mem.Allocator, cursor: *Cursor, dirs: []const LineProgPath, files: []const LineProgPath) ![]LineProgLine {
    var lines: std.ArrayList(LineProgLine) = .empty;
    defer lines.deinit(gpa);
    var regs: LineProgRegs = .initial(header);
    const addr_size = header.addr_size orelse cu.header.addr_size;
    while (cursor.offset != header.program_end) {
        const opcode = cursor.readByte();
        if (opcode == @intFromEnum(LNS.extended_op)) {
            const len = cursor.readUleb128();
            const sub_opcode = cursor.readByte();
            const typed_sub_op: LNE = @enumFromInt(sub_opcode);
            switch (typed_sub_op) {
                .end_sequence => {
                    regs.end_sequence = true;
                    try lines.append(gpa, try regs.emitLine(arena, dirs, files));
                    regs.resetFull(header);
                },
                .set_address => regs.address = cursor.readUBytes(addr_size),
                .define_file => cursor.skip(len - 1),
                .set_discriminator => regs.discriminator = cursor.readUleb128(),
                else => cursor.skip(len - 1),
            }
        } else if (opcode < header.opcode_base) {
            const typed_op: LNS = @enumFromInt(opcode);
            switch (typed_op) {
                .copy => {
                    try lines.append(gpa, try regs.emitLine(arena, dirs, files));
                    regs.resetPostEmit();
                },
                .advance_pc => regs.address += cursor.readUleb128() * header.min_instruction_length,
                .advance_line => regs.line = @intCast(@as(i64, @intCast(regs.line)) + cursor.readSleb128()),
                .set_file => regs.file = cursor.readUleb128(),
                .set_column => regs.column = cursor.readUleb128(),
                .negate_stmt => regs.is_stmt = !regs.is_stmt,
                .set_basic_block => regs.basic_block = true,
                .const_add_pc => regs.address += ((255 - header.opcode_base) / header.line_range) * header.min_instruction_length,
                .fixed_advance_pc => regs.address = @intCast(@as(i64, @intCast(regs.address)) + cursor.readBytes(2)),
                .set_prologue_end => regs.prologue_end = true,
                .set_epilogue_begin => regs.epilogue_begin = true,
                .set_isa => regs.isa = cursor.readUleb128(),
                else => unreachable,
            }
        } else {
            const opcode_rel = opcode - header.opcode_base;
            const addr_adv = (opcode_rel / header.line_range) * header.min_instruction_length;
            const line_adv = header.line_base + @as(i8, @intCast(opcode_rel % header.line_range));
            regs.address += addr_adv;
            regs.line = @intCast(@as(i64, @intCast(regs.line)) + line_adv);
            try lines.append(gpa, try regs.emitLine(arena, dirs, files));
            regs.resetPostEmit();
        }
    }

    return try arena.dupe(LineProgLine, lines.items);
}

pub fn getLineRanges(self: *DwarfInfo, allocator: std.mem.Allocator, addr: u64) ![]model.Line {
    var arena_allocator: std.heap.ArenaAllocator = .init(std.heap.page_allocator);
    defer arena_allocator.deinit();
    const arena = arena_allocator.allocator();
    const section = self.elf.dwarf.?.sections[@intFromEnum(SectionId.debug_line)].?.data;
    const cu = self.getCu(addr) orelse return error.NotFound;
    var cursor: Cursor = .{ .data = section, .offset = @intCast(cu.attrs.stmt_list.?) };

    const header = try readLineProgHeader(arena, cu, &cursor);
    var dirs: []LineProgPath = undefined;
    var files: []LineProgPath = undefined;
    switch (header.version) {
        0...4 => {
            dirs = try readLineProgDirsOld(&header, arena, &cursor);
            files = try readLineProgFilesOld(&header, arena, &cursor);
        },
        5...6 => {
            dirs = try readLineProgPathsNew(arena, &cursor, &cu.header, &self.elf.dwarf.?);
            files = try readLineProgPathsNew(arena, &cursor, &cu.header, &self.elf.dwarf.?);
        },
        else => return DwarfError.Unsupported,
    }
    const lines = try executeLineProg(&header, cu, self.gpa, arena, &cursor, dirs, files);
    var generic_lines: []model.Line = try allocator.alloc(model.Line, lines.len);
    for (lines, 0..) |line, i| {
        generic_lines[i] = .{
            .addr = line.addr,
            .line = line.line,
            .column = line.column,
            .file = try allocator.dupe(u8, line.file),
            .is_stmt = line.is_stmt,
            .end_sequence = line.end_sequence,
            .prologue_end = line.prologue_end,
        };
    }
    return generic_lines;
}
