const std = @import("std");
const StructField = std.builtin.TypeInfo.StructField;
const isSignedInt = std.meta.trait.isSignedInt;
const isIntegral = std.meta.trait.isIntegral;

// common definitions

const ArrayList = std.ArrayList;

/// Type of encoding for a Varint value.
const VarintType = enum {
    Simple,
    ZigZagOptimized
};

/// Enum describing the different field types available.
pub const FieldTypeTag = enum{
    Varint,
    FixedInt,
    SubMessage,
    List,
    OneOf,
    Map
};

/// Enum describing the content type of a repeated field.
pub const ListTypeTag = enum {
    Varint,
    FixedInt,
    SubMessage,
};

/// Tagged union for repeated fields, giving the details of the underlying type.
pub const ListType = union(ListTypeTag) {
    Varint : VarintType,
    FixedInt,
    SubMessage,
};

/// Enum describing the details of keys or values for a map type.
pub const KeyValueTypeTag = enum {
    Varint,
    FixedInt,
    SubMessage,
    List,

};

/// Tagged union giving the details of underlying types in a map field
pub const  KeyValueType = union(KeyValueTypeTag) {
    Varint : VarintType,
    FixedInt,
    SubMessage,
    List : ListType,

    pub fn toFieldType(self: KeyValueType) FieldType {
        return switch(self)
        {
            .Varint => |varint_type| .{.Varint = varint_type},
            .FixedInt => .{.FixedInt},
            .SubMessage => .{.SubMessage},
            .List => |list_type| .{.List = list_type}
        };
    }
};

/// Struct for key and values of a map type
pub const KeyValueTypeData = struct {
    t: type,
    pb_data: KeyValueType,
};


/// Struct describing keys and values of a map
pub const MapData = struct {
    key: KeyValueTypeData,
    value: KeyValueTypeData
};

/// Main tagged union holding the details of any field type.
pub const FieldType = union(FieldTypeTag) {
    Varint : VarintType,
    FixedInt,
    SubMessage,
    List : ListType,
    OneOf: type,
    Map: MapData,

    /// returns the wire type of a field. see https://developers.google.com/protocol-buffers/docs/encoding#structure
    pub fn get_wirevalue(comptime ftype : FieldType, comptime value_type: type) u3 {
        const real_type: type = switch(@typeInfo(value_type)) {
            .Optional => |opt| opt.child,
            else => value_type
        };
        return switch (ftype) {
            .Varint => 0,
            .FixedInt => return switch(@bitSizeOf(real_type)) {
                64 => 1,
                32 => 5,
                else => @compileLog("Invalid size for fixed int :", @bitSizeOf(real_type), "type is ", real_type)
            },
            .SubMessage, .List, .Map => 2,
            .OneOf => unreachable,
        };
    }
};


/// Structure describing a field. Most of the relevant informations are
/// In the FieldType data. Tag is optional as OneOf fields are "virtual" fields.
pub const FieldDescriptor = struct {
    tag: ?u32,
    ftype: FieldType,
};

/// Helper function to build a FieldDescriptor. Makes code clearer, mostly.
pub fn fd(tag: ?u32, comptime ftype: FieldType) FieldDescriptor {
    return FieldDescriptor{
        .tag = tag,
        .ftype = ftype
    };
}

// encoding

/// Appends an unsigned varint value.
/// Awaits a u64 value as it's the biggest unsigned varint possible,
// so anything can be cast to it by definition
fn append_raw_varint(pb: *ArrayList(u8), value: u64) !void {
    var copy = value;
    while(copy > 0x7F) {
        try pb.append(0x80 + @intCast(u8, copy & 0x7F));
        copy = copy >> 7;
    }
    try pb.append(@intCast(u8, copy & 0x7F));
}

/// Inserts a varint into the pb at start_index
/// Mostly useful when inserting the size of a field after it has been
/// Appended to the pb buffer.
fn insert_raw_varint(pb: *ArrayList(u8), size: u64, start_index: usize) !void {
    if(size < 0x7F){
        try pb.insert(start_index, @truncate(u8, size));
    }
    else
    {
        var copy = size;
        var index = start_index;
        while(copy > 0x7F) : (index += 1 ) {
            try pb.insert(index, 0x80 + @intCast(u8, copy & 0x7F));
            copy = copy >> 7;
        }
        try pb.insert(index, @intCast(u8, copy & 0x7F));
    }
}

/// Appends a varint to the pb array. 
/// Mostly does the required transformations to use append_raw_varint
/// after making the value some kind of unsigned value.
fn append_as_varint(pb: *ArrayList(u8), value: anytype, comptime varint_type: VarintType) !void {
    if(value < 0x7F and value >= 0){
        try pb.append(@intCast(u8, value));
    }
    else
    {
        const type_of_val = @TypeOf(value);
        const bitsize = @bitSizeOf(type_of_val);
        const val : u64 = comptime blk: {
            if(isSignedInt(type_of_val)){
                switch(varint_type) {
                    .ZigZagOptimized => {
                        break :blk @intCast(u64, (value >> (bitsize-1)) ^ (value << 1));
                    },
                    .Simple => {
                        break :blk @ptrCast(*const std.meta.Int(.unsigned, bitsize), &value).*;
                    }
                }
            }
            else
            {
                break :blk @intCast(u64, value);
            }
        };

        try append_raw_varint(pb, val);
    }
}

/// Append a value of any complex type that can be transfered as a varint
/// Only serves as an indirection to manage Enum and Booleans properly.
fn append_varint(pb : *ArrayList(u8), value: anytype, comptime varint_type: VarintType) !void {
    switch(@typeInfo(@TypeOf(value))) {
        .Enum => try append_as_varint(pb, @as(i32, @enumToInt(value)), varint_type),
        .Bool => try append_as_varint(pb, @as(u8, @boolToInt(value)), varint_type),
        else => try append_as_varint(pb, value, varint_type),
    }
}

/// Appends a fixed size int to the pb buffer.
/// Takes care of casting any signed/float value to an appropriate unsigned type
fn append_fixed(pb : *ArrayList(u8), value: anytype) !void {
    const bitsize = @bitSizeOf(@TypeOf(value));

    var as_unsigned_int = switch(@TypeOf(value)) {
        f32, f64, i32, i64 => @bitCast(std.meta.Int(.unsigned, bitsize), value),
        u32, u64, u8 => value,
        else => blk: {
            @compileLog("error in append_fixed, value type is",  @TypeOf(value));
            break :blk unreachable;
        }
    };
    var index : usize = 0;

    while(index < (bitsize/8)) : (index += 1) {
        try pb.append(@truncate(u8, as_unsigned_int));
        as_unsigned_int = as_unsigned_int >> 8;
    }
}

/// Appends a submessage to the array.
/// Recursively calls internal_pb_encode.
fn append_submessage(pb :* ArrayList(u8), value: anytype) !void {
    const len_index = pb.items.len;
    try internal_pb_encode(pb, value);
    const size_encoded = pb.items.len - len_index;
    try insert_raw_varint(pb, size_encoded, len_index);
}

/// Simple appending of a list of bytes.
fn append_bytes(pb: *ArrayList(u8), value: *const ArrayList(u8)) !void {
    try append_as_varint(pb, value.len, .Simple);
    try pb.appendSlice(value.items);
}

/// simple appending of a list of fixed-size data.
fn append_list_of_fixed(pb: *ArrayList(u8), value: anytype) !void {
    const total_len = @divFloor(value.items.len * @bitSizeOf(@typeInfo(@TypeOf(value.items)).Pointer.child), 8);
    try append_as_varint(pb, total_len, .Simple);
    if(@TypeOf(value) == ArrayList(u8)) {
        try pb.appendSlice(value.items);
    }
    else {
        for(value.items) |item| {
            try append_fixed(pb, item);
        }
    }
}

/// Appends a list of varint to the pb buffer.
fn append_list_of_varint(pb : *ArrayList(u8), value_list: anytype, comptime varint_type: VarintType) !void {
    const len_index = pb.items.len;
    for(value_list.items) |item| {
        try append_varint(pb, item, varint_type);
    }
    const size_encoded = pb.items.len - len_index;
    try insert_raw_varint(pb, size_encoded, len_index);
}

/// Appends a list of submessages to the pb_buffer.
fn append_list_of_submessages(pb: *ArrayList(u8), value_list: anytype) !void {
    const len_index = pb.items.len;
    for(value_list.items) |item| {
        try append_submessage(pb, item);
    }
    const size_encoded = pb.items.len - len_index;
    try insert_raw_varint(pb, size_encoded, len_index);
}


/// calculates the comptime value of (tag_index << 3) + wire type. 
/// This is fully calculated at comptime which is great.
fn get_full_tag_value(comptime field: FieldDescriptor, comptime value_type: type) ?u32 {
    return if(field.tag) |tag| ((tag << 3)| field.ftype.get_wirevalue(value_type)) else null;
}

/// Appends the full tag of the field in the pb buffer, if there is any.
fn append_tag(pb : *ArrayList(u8), comptime field: FieldDescriptor,  value_type: type) !void {
    if(get_full_tag_value(field, value_type)) |tag_value|{
        try append_varint(pb, tag_value, .Simple);
    }
}

fn MapSubmessage(comptime key_data : KeyValueTypeData, comptime value_data : KeyValueTypeData) type {
    return struct {
        const Self = @This();

        key : ?key_data.t,
        value : ?value_data.t,

        pub const _desc_table = .{
            .key = fd(1, key_data.pb_data.toFieldType()),
            .value = fd(2, value_data.pb_data.toFieldType())
        };

        pub fn encode(self: Self, allocator: *mem.Allocator) ![]u8 {
            return pb_encode(self, allocator);
        }

        pub fn decode(input: []const u8, allocator: *mem.Allocator) !Self {
            return pb_decode(Self, input, allocator);
        }

        pub fn init(allocator: *mem.Allocator) Self {
            return pb_init(Self, allocator);
        }

        pub fn deinit(self: Self) void {
            pb_deinit(self);
        }
    };
}

/// Appends the content of a Map field to the pb buffer.
/// Relies on a property of maps being basically a list of submessage with key index = 1 and value index = 2
/// By relying on this property, encoding maps is as easy as building an internal
/// Struct type with this data, and encoding using all the rest of the tool already
/// at hand.
/// See this note for details https://developers.google.com/protocol-buffers/docs/proto3#backwards_compatibility
fn append_map(pb : *ArrayList(u8), comptime field: FieldDescriptor, map: anytype) !void {
    const len_index = pb.items.len;
    var iterator : @TypeOf(map).Iterator = map.iterator();
    const key_type_data = field.ftype.Map.key;
    const value_type_data = field.ftype.Map.value;
    const Submessage = MapSubmessage(key_type_data, value_type_data);
    while (iterator.next()) |data| {
        try append_submessage(pb, Submessage{.key = data.key_ptr.*, .value = data.value_ptr.*});
    }
    const size_encoded = pb.items.len - len_index;
    try insert_raw_varint(pb, size_encoded, len_index);
}

/// Appends a value to the pb buffer. Starts by appending the tag, then a comptime switch
/// routes the code to the correct type of data to append. 
fn append(pb : *ArrayList(u8), comptime field: FieldDescriptor, value_type: type, value: anytype) !void {
    try append_tag(pb, field, value_type);
    switch(field.ftype)
    {
        .Varint => |varint_type| {
            try append_varint(pb, value, varint_type);
        },
        .FixedInt => {
            try append_fixed(pb, value);  
        },
        .SubMessage => {
            try append_submessage(pb, value);
        },
        .List => |list_type| {
            switch(list_type) {
                .FixedInt => {
                    try append_list_of_fixed(pb, value);
                },
                .SubMessage => {
                    try append_list_of_submessages(pb, value);
                },
                .Varint => |varint_type| {
                    try append_list_of_varint(pb, value, varint_type);
                }
            }
        },
        .OneOf => |union_type| {
            const active = @tagName(value);
            inline for (@typeInfo(@TypeOf(union_type._union_desc)).Struct.fields) |union_field| {
                if(std.mem.eql(u8, union_field.name, active)) {
                    try append(pb, @field(union_type._union_desc, union_field.name), @TypeOf(@field(value, union_field.name)), @field(value, union_field.name));
                }
            }
        },
        .Map => {        
            try append_map(pb, field, value);    
        }
    }
}

/// Internal function that decodes the descriptor information and struct fields
/// before passing them to the append function
fn internal_pb_encode(pb : *ArrayList(u8), data: anytype) !void {
    const field_list  = @typeInfo(@TypeOf(data)).Struct.fields;
    const data_type = @TypeOf(data);

    inline for(field_list) |field| {
        if (@typeInfo(field.field_type) == .Optional){
            if(@field(data, field.name)) |value| {
                try append(pb, @field(data_type._desc_table, field.name), @TypeOf(value), value);
            }
        }
        else
        {
            switch(@field(data_type._desc_table, field.name).ftype)
            {
                .List => if(@field(data, field.name).items.len != 0) {
                    try append(pb, @field(data_type._desc_table, field.name), @TypeOf(@field(data, field.name)), @field(data, field.name));
                },
                .Map => if(@field(data, field.name).count() != 0) {
                    try append(pb, @field(data_type._desc_table, field.name), @TypeOf(@field(data, field.name)), @field(data, field.name));
                },
                else => @compileLog("You shouldn't be here")
            }
        }
    }
}

/// Public encoding function, meant to be embdedded in generated structs
pub fn pb_encode(data : anytype, allocator: *std.mem.Allocator) ![]u8 {
    var pb = ArrayList(u8).init(allocator);
    errdefer pb.deinit();

    try internal_pb_encode(&pb, data);
    
    return pb.toOwnedSlice();
}

/// Generic init function. Properly initialise any field required. Meant to be embedded in generated structs.
pub fn pb_init(comptime T: type, allocator : *std.mem.Allocator) T {

    var value: T = undefined;

    inline for (@typeInfo(T).Struct.fields) |field| {
        switch (@field(T._desc_table, field.name).ftype) {
            .Varint, .FixedInt => {
                @field(value, field.name) = if(field.default_value) |val| val else null;
            },
            .SubMessage, .List, .Map => {
                @field(value, field.name) = @TypeOf(@field(value, field.name)).init(allocator);
            },
            .OneOf => {
                @field(value, field.name) = null;
            }
        }
    }

    return value;
}

/// Generic deinit function. Properly initialise any field required. Meant to be embedded in generated structs.
pub fn pb_deinit(data: anytype) void {
    const T  = @TypeOf(data);

    inline for (@typeInfo(T).Struct.fields) |field| {
        deinit_field(data, field.name, @field(T._desc_table, field.name).ftype);
    }
}

/// Internal deinit function for a specific field
fn deinit_field(field: anytype, comptime field_name: []const u8, comptime ftype: FieldType) void {
    switch(ftype) {
        .Varint, .FixedInt => {},
        .SubMessage => {
            @field(field, field_name).deinit();
        },
        .List => |list_type| {
            if(list_type == .SubMessage) {
                for(@field(field, field_name).items) |item| {
                    item.deinit();
                }
            }
            @field(field, field_name).deinit();
        },
        .OneOf => |union_type| {
            if(@field(field, field_name)) |union_value| {
                const active = @tagName(union_value);
                inline for (@typeInfo(@TypeOf(union_type._union_desc)).Struct.fields) |union_field| {
                    if(std.mem.eql(u8, union_field.name, active)) {
                        deinit_field(union_value, union_field.name, @field(union_type._union_desc, union_field.name).ftype);
                    }
                } 
            } 
        },
        .Map => |_| {
            // for unknown reason i have to specifically made it var here. Otherwise it's a const field.
            var temp = @field(field, field_name); // key/values requiring dealloc aren't managed yet!
            temp.deinit();
        }
    }
}

// decoding

/// Enum describing if described data is raw (<u64) data or a byte slice.
const ExtractedDataTag = enum {
    RawValue,
    Slice,
};

/// Union enclosing either a u64 raw value, or a byte slice.
const ExtractedData = union(ExtractedDataTag) {
    RawValue : u64,
    Slice: []const u8
};

/// Unit of extracted data from a stream
/// Please not that "tag" is supposed to be the full tag. See get_full_tag_value.
const Extracted = struct {
    tag: u32,
    data: ExtractedData
};

/// Decoded varint value generic type
fn DecodedVarint(comptime T: type) type {
    return struct {
        value: T,
        size: usize,
    };
}

/// Decodes a varint from a slice, to type T.
fn decode_varint(comptime T: type, input: []const u8) DecodedVarint(T) {
    var value: T = 0;
    var index: usize = 0;

    while((input[index] & 0b10000000) != 0) : (index += 1) {
        value += (@as(T, input[index] & 0x7F)) << (@intCast(std.math.Log2Int(T), index*7));
    }

    value += (@as(T, input[index] & 0x7F)) << (@intCast(std.math.Log2Int(T), index*7));

    return DecodedVarint(T){
        .value = value,
        .size = index +1,
    };
}

/// Decodes a fixed value to type T
fn decode_fixed(comptime T : type, slice: []const u8) T {
    var result : T = 0;

    for(slice) |byte, index| {
        result += @as(T, byte) << (@intCast(std.math.Log2Int(T), index * 8));
    }
    return result;
}

/// "Tokenizer" of a byte slice to raw pb data.
const WireDecoderIterator = struct {
    input: []const u8,
    current_index : usize = 0,

    /// Attempts at decoding the next pb_buffer data.
    fn next(state: *WireDecoderIterator) !?Extracted {
        if(state.current_index < state.input.len) {
            const tag_and_wire = decode_varint(u32, state.input[state.current_index..]);
            state.current_index += tag_and_wire.size;
            const tag : u32 = tag_and_wire.value;
            const wire_value = tag_and_wire.value & 0b00000111;
            const data : ExtractedData = switch(wire_value) {
                0 => blk: {
                    const varint = decode_varint(u64, state.input[state.current_index..]);
                    state.current_index += varint.size;
                    break :blk ExtractedData{
                        .RawValue = varint.value,
                    };
                },
                1 => blk: {
                        const value = ExtractedData{.RawValue = decode_fixed(u64, state.input[state.current_index..state.current_index+8])};
                        state.current_index += 8;
                        break :blk value;
                },
                5 => blk: {
                        const value = ExtractedData{.RawValue = decode_fixed(u32, state.input[state.current_index..state.current_index+4])};
                        state.current_index += 4;
                        break :blk value;
                },
                else => @panic("Not implemented yet")
            };

            return Extracted{
                .tag = tag,
                .data = data
            };
        }
        else
        {
            return null;
        }    
    }
};

/// Get a real varint of type T from a raw u64 data.
fn get_varint_value(comptime T : type, comptime varint_type : VarintType, raw: u64) T {
    return comptime switch(varint_type) {
        .ZigZagOptimized => 
            switch (@typeInfo(T)) {
                .Int =>  @intCast(T, (@intCast(i64, raw) >> 1) ^ (-(@intCast(i64, raw) & 1))),
                .Enum => @intToEnum(T, @intCast(i32, (@intCast(i64, raw) >> 1) ^ (-(@intCast(i64, raw) & 1)))),
                else => unreachable
            }
        ,
        .Simple =>
            switch (@typeInfo(T)) {
                .Int => switch(T) {
                    u32, u64 => @intCast(T, raw),
                    i32, i64 => @bitCast(T, @truncate(std.meta.Int(.unsigned, @bitSizeOf(T)), raw)),
                    else => unreachable
                },
                .Bool => raw == 1,
                .Enum => @intToEnum(T, @intCast(i32, raw)),
                else => unreachable
            }
    };
}

/// Get a real fixed value of type T from a raw u64 value.
fn get_fixed_value(comptime T: type, raw: u64) T {
    return switch(T) {
        i32, u32, i64, u64 => @ptrCast(*const T, &@truncate(std.meta.Int(.unsigned, @bitSizeOf(T)), raw)).*,
        f32, f64 => @ptrCast(*T, &@intCast(std.meta.Int(.unsigned, @bitSizeOf(T)), raw)).*,
        else => @compileLog("Not implemented")
    };
}


/// public decoding function meant to be embedded in message structures
/// Iterates over the input and try to fill the resulting structure accordingly.
pub fn pb_decode(comptime T: type, input: []const u8, allocator: *std.mem.Allocator) !T {
    var result = pb_init(T, allocator);
    
    var iterator = WireDecoderIterator{.input = input};

    while(try iterator.next()) |extracted_data| {
        
        const field_found : ?StructField = inline for (@typeInfo(T).Struct.fields) |field| {
            if(get_full_tag_value(@field(T._desc_table, field.name), field.field_type)) |tag_value|
            {
                if(tag_value == extracted_data.tag) break field;
            }
        } else null;

        if(field_found) |field| {
            const child_type = @typeInfo(field.field_type).Optional.child;
            
            @field(result, field.name) = switch(@field(T._desc_table, field.name).ftype) {
                .Varint => |varint_type| get_varint_value(child_type, varint_type, extracted_data.data.RawValue),
                .FixedInt => get_fixed_value(child_type, extracted_data.data.RawValue),
                else => @panic("Not implemented")
            };
        }
    }

    return result;
}

// TBD

// tests

const testing = std.testing;

test "get varint" {
    var pb = ArrayList(u8).init(testing.allocator);
    const value: u32 = 300;
    defer pb.deinit();
    try append_varint(&pb, value, .Simple);

    try testing.expectEqualSlices(u8, &[_]u8{0b10101100, 0b00000010}, pb.items);
}

