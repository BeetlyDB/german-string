const std = @import("std");
const Allocator = std.mem.Allocator;

// Optimized German-string
pub const String = packed struct {
    len: u32,
    payload: packed union {
        content: u96,
        heap: packed struct {
            prefix: u32,
            ptr: [*]const u8,
        },
    },

    const INLINE_THRESHOLD: u32 = 12;

    pub const InitOpts = struct {
        dupe: bool = true,
    };

    pub fn init(allocator: Allocator, input: []const u8, opts: InitOpts) !String {
        if (input.len > std.math.maxInt(u32)) {
            return error.StringTooLarge;
        }
        const l: u32 = @intCast(input.len);

        if (l <= INLINE_THRESHOLD) {
            var content: [12]u8 = undefined;
            @memcpy(content[0..l], input);
            return .{ .len = l, .payload = .{ .content = @bitCast(content) } };
        }

        var prefix: [4]u8 = undefined;
        @memcpy(&prefix, input[0..4]);

        return .{
            .len = l,
            .payload = .{
                .heap = .{
                    .prefix = @bitCast(prefix),
                    .ptr = if (opts.dupe) (try allocator.dupe(u8, input)).ptr else input.ptr,
                },
            },
        };
    }

    pub inline fn get_prefix(self: *const String) [4]u8 {
        return @bitCast(self.payload.heap.prefix);
    }

    pub inline fn get_content(self: *const String) [12]u8 {
        return @bitCast(self.payload.content);
    }

    pub fn deinit(self: *const String, allocator: Allocator) void {
        if (self.len > INLINE_THRESHOLD) {
            allocator.free(self.payload.heap.ptr[0..self.len]);
        }
    }

    pub inline fn str(self: *const String) []const u8 {
        if (self.len <= INLINE_THRESHOLD) {
            const slice: []const u8 = self.get_content()[0..];
            return slice[0..self.len];
        }

        return self.payload.heap.ptr[0..self.len];
    }

    pub inline fn isEmpty(self: *const String) bool {
        return self.len == 0;
    }

    pub fn format(self: String, writer: *std.Io.Writer) !void {
        return writer.writeAll(self.str());
    }

    pub inline fn eql(a: *const String, b: *const String) bool {
        if (a.len != b.len) return false;

        if (a.len <= INLINE_THRESHOLD) {
            return a.payload.content == b.payload.content;
        }

        if (a.payload.heap.prefix != b.payload.heap.prefix) {
            return false;
        }

        if (a.payload.heap.ptr == b.payload.heap.ptr) {
            return true;
        }

        return std.mem.eql(u8, a.payload.heap.ptr[0..a.len], b.payload.heap.ptr[0..b.len]);
    }

    pub fn eqlSlice(a: *const String, b: []const u8) bool {
        if (a.len != b.len) return false;

        if (a.len <= INLINE_THRESHOLD) {
            const a_slice = a.str();
            return std.mem.eql(u8, a_slice, b);
        }

        if (b.len >= 4) {
            const prefix_b = std.mem.readInt(u32, b[0..4], .little);
            if (a.payload.heap.prefix != prefix_b) {
                return false;
            }
        }

        return std.mem.eql(u8, a.payload.heap.ptr[0..a.len], b);
    }
};

const testing = std.testing;

test "String optimized" {
    const other_short = try String.init(undefined, "other_short", .{});
    const other_long = try String.init(testing.allocator, "other_long" ** 100, .{});
    defer other_long.deinit(testing.allocator);

    inline for (0..100) |i| {
        @setEvalBranchQuota(10000);
        const input = "a" ** i;
        const str = try String.init(testing.allocator, input, .{});
        defer str.deinit(testing.allocator);

        try testing.expect(std.mem.eql(u8, input, str.str()));
        try testing.expectEqual(true, str.eql(&str));
        try testing.expectEqual(true, str.eqlSlice(input));
        try testing.expectEqual(false, str.eql(&other_short));
        try testing.expectEqual(false, str.eqlSlice("other_short"));
        try testing.expectEqual(false, str.eql(&other_long));
    }
}

test "String: edge cases & invariants" {
    const alloc = testing.allocator;

    // empty
    {
        const s = try String.init(alloc, "", .{});
        defer s.deinit(alloc);
        try testing.expect(s.isEmpty());
        try testing.expectEqual(@as(usize, 0), s.str().len);
    }

    // exact inline boundary
    {
        const input = "123456789012"; // 12
        const s = try String.init(alloc, input, .{});
        defer s.deinit(alloc);
        try testing.expectEqualStrings(input, s.str());
    }

    // just over inline boundary
    {
        const input = "1234567890123"; // 13
        const s = try String.init(alloc, input, .{});
        defer s.deinit(alloc);
        try testing.expectEqualStrings(input, s.str());
    }
}

test "String: dupe=false pointer aliasing (heap only)" {
    var buf = [_]u8{'h'} ** 32; // > INLINE_THRESHOLD
    const s = try String.init(undefined, buf[0..], .{ .dupe = false });

    try testing.expect(s.len > String.INLINE_THRESHOLD);
    try testing.expectEqual(
        @intFromPtr(&buf),
        @intFromPtr(s.payload.heap.ptr),
    );
}

test "String: eql & eqlSlice matrix" {
    const alloc = testing.allocator;

    const a = try String.init(alloc, "abcdef", .{});
    const b = try String.init(alloc, "abcdef", .{});
    const c = try String.init(alloc, "abcdeg", .{});
    defer a.deinit(alloc);
    defer b.deinit(alloc);
    defer c.deinit(alloc);

    try testing.expect(a.eql(&b));
    try testing.expect(!a.eql(&c));

    try testing.expect(a.eqlSlice("abcdef"));
    try testing.expect(!a.eqlSlice("abcdeg"));
    try testing.expect(!a.eqlSlice("abc"));
}

test "String: prefix fast-fail works" {
    const alloc = testing.allocator;

    const a = try String.init(alloc, "abcdZZZZZZ", .{});
    const b = try String.init(alloc, "abceYYYYYY", .{});
    defer a.deinit(alloc);
    defer b.deinit(alloc);

    try testing.expect(!a.eql(&b));
}

test "bench: String.eqlSlice vs []const u8" {
    const alloc = testing.allocator;
    const iters = 5_000_000;

    const input = "this_is_a_reasonably_long_string_for_testing";
    const s = try String.init(alloc, input, .{});
    defer s.deinit(alloc);

    var timer = try std.time.Timer.start();

    // String.eqlSlice
    var ok1: usize = 0;
    timer.reset();
    for (0..iters) |_| {
        if (s.eqlSlice(input)) ok1 += 1;
    }
    const t1 = timer.read();

    // std.mem.eql
    var ok2: usize = 0;
    timer.reset();
    for (0..iters) |_| {
        if (std.mem.eql(u8, input, input)) ok2 += 1;
    }
    const t2 = timer.read();

    std.debug.print(
        \\bench results ({} iters):
        \\  String.eqlSlice: {} ns
        \\  mem.eql:         {} ns
        \\  ratio:           {d:.2}x
        \\
    , .{
        iters,
        t1,
        t2,
        @as(f64, @floatFromInt(t1)) / @as(f64, @floatFromInt(t2)),
    });

    try testing.expectEqual(ok1, iters);
    try testing.expectEqual(ok2, iters);
}

test "bench: inline String vs mem.eql (short, unequal)" {
    const iters = 8_000_000;

    var a_buf = [_]u8{ 's', 'h', 'o', 'r', 't' };
    var b_buf = [_]u8{ 's', 'h', 'o', 'r', 'f' };

    const a_slice = a_buf[0..];
    const b_slice = b_buf[0..];

    const a = try String.init(undefined, a_slice, .{});
    const b = try String.init(undefined, b_slice, .{});

    var timer = try std.time.Timer.start();

    // String.eql
    var neq1: usize = 0;
    timer.reset();
    for (0..iters) |_| {
        if (!a.eql(&b)) neq1 += 1;
    }
    const t1 = timer.read();

    // std.mem.eql
    var neq2: usize = 0;
    timer.reset();
    for (0..iters) |_| {
        if (!std.mem.eql(u8, a_slice, b_slice)) neq2 += 1;
    }
    const t2 = timer.read();

    std.debug.print(
        \\inline unequal bench ({} iters):
        \\  String.eql: {} ns
        \\  mem.eql:    {} ns
        \\  ratio:      {d:.2}x
        \\
    , .{
        iters,
        t1,
        t2,
        @as(f64, @floatFromInt(t1)) / @as(f64, @floatFromInt(t2)),
    });

    try testing.expectEqual(neq1, iters);
    try testing.expectEqual(neq2, iters);
}
