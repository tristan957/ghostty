const Metrics = @This();

const std = @import("std");

/// Recommended cell width and height for a monospace grid using this font.
cell_width: u32,
cell_height: u32,

/// For monospace grids, the recommended y-value from the bottom to set
/// the baseline for font rendering. This is chosen so that things such
/// as the bottom of a "g" or "y" do not drop below the cell.
cell_baseline: u32,

/// The position of the underline from the top of the cell and the
/// thickness in pixels.
underline_position: u32,
underline_thickness: u32,

/// The position and thickness of a strikethrough. Same units/style
/// as the underline fields.
strikethrough_position: u32,
strikethrough_thickness: u32,

/// Apply a set of modifiers.
pub fn apply(self: *Metrics, mods: ModifierSet) void {
    var it = mods.iterator();
    while (it.next()) |entry| {
        switch (entry.key_ptr.*) {
            // We clamp these values to a minimum of 1 to prevent divide-by-zero
            // in downstream operations.
            inline .cell_width,
            .cell_height,
            => |tag| {
                const original = @field(self, @tagName(tag));
                @field(self, @tagName(tag)) = @max(
                    entry.value_ptr.apply(original),
                    1,
                );
            },

            inline else => |tag| {
                @field(self, @tagName(tag)) = entry.value_ptr.apply(@field(self, @tagName(tag)));
            },
        }
    }
}

/// A set of modifiers to apply to metrics. We use a hash map because
/// we expect most metrics to be unmodified and want to take up as
/// little space as possible.
pub const ModifierSet = std.AutoHashMapUnmanaged(Key, Modifier);

/// A modifier to apply to a metrics value. The modifier value represents
/// a delta, so percent is a percentage to change, not a percentage of.
/// For example, "20%" is 20% larger, not 20% of the value. Likewise,
/// an absolute value of "20" is 20 larger, not literally 20.
pub const Modifier = union(enum) {
    percent: f64,
    absolute: i32,

    /// Parses the modifier value. If the value ends in "%" it is assumed
    /// to be a percent, otherwise the value is parsed as an integer.
    pub fn parse(input: []const u8) !Modifier {
        if (input.len == 0) return error.InvalidFormat;

        if (input[input.len - 1] == '%') {
            var percent = std.fmt.parseFloat(
                f64,
                input[0 .. input.len - 1],
            ) catch return error.InvalidFormat;
            percent /= 100;

            if (percent <= -1) return .{ .percent = 0 };
            if (percent < 0) return .{ .percent = 1 + percent };
            return .{ .percent = 1 + percent };
        }

        return .{
            .absolute = std.fmt.parseInt(i32, input, 10) catch
                return error.InvalidFormat,
        };
    }

    /// So it works with the config framework.
    pub fn parseCLI(input: ?[]const u8) !Modifier {
        return try parse(input orelse return error.ValueRequired);
    }

    /// Apply a modifier to a numeric value.
    pub fn apply(self: Modifier, v: u32) u32 {
        return switch (self) {
            .percent => |p| percent: {
                const p_clamped: f64 = @max(0, p);
                const v_f64: f64 = @floatFromInt(v);
                const applied_f64: f64 = @round(v_f64 * p_clamped);
                const applied_u32: u32 = @intFromFloat(applied_f64);
                break :percent applied_u32;
            },

            .absolute => |abs| absolute: {
                const v_i64: i64 = @intCast(v);
                const abs_i64: i64 = @intCast(abs);
                const applied_i64: i64 = @max(0, v_i64 +| abs_i64);
                const applied_u32: u32 = std.math.cast(u32, applied_i64) orelse
                    std.math.maxInt(u32);
                break :absolute applied_u32;
            },
        };
    }
};

/// Key is an enum of all the available metrics keys.
pub const Key = key: {
    const field_infos = std.meta.fields(Metrics);
    var enumFields: [field_infos.len]std.builtin.Type.EnumField = undefined;
    for (field_infos, 0..) |field, i| {
        enumFields[i] = .{
            .name = field.name,
            .value = i,
        };
    }

    var decls = [_]std.builtin.Type.Declaration{};
    break :key @Type(.{
        .Enum = .{
            .tag_type = std.math.IntFittingRange(0, field_infos.len - 1),
            .fields = &enumFields,
            .decls = &decls,
            .is_exhaustive = true,
        },
    });
};

// NOTE: This is purposely not pub because we want to force outside callers
// to use the `.{}` syntax so unused fields are detected by the compiler.
fn init() Metrics {
    return .{
        .cell_width = 0,
        .cell_height = 0,
        .cell_baseline = 0,
        .underline_position = 0,
        .underline_thickness = 0,
        .strikethrough_position = 0,
        .strikethrough_thickness = 0,
    };
}

test "Metrics: apply modifiers" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var set: ModifierSet = .{};
    defer set.deinit(alloc);
    try set.put(alloc, .cell_width, .{ .percent = 1.2 });

    var m: Metrics = init();
    m.cell_width = 100;
    m.apply(set);
    try testing.expectEqual(@as(u32, 120), m.cell_width);
}

test "Modifier: parse absolute" {
    const testing = std.testing;

    {
        const m = try Modifier.parse("100");
        try testing.expectEqual(Modifier{ .absolute = 100 }, m);
    }

    {
        const m = try Modifier.parse("-100");
        try testing.expectEqual(Modifier{ .absolute = -100 }, m);
    }
}

test "Modifier: parse percent" {
    const testing = std.testing;

    {
        const m = try Modifier.parse("20%");
        try testing.expectEqual(Modifier{ .percent = 1.2 }, m);
    }
    {
        const m = try Modifier.parse("-20%");
        try testing.expectEqual(Modifier{ .percent = 0.8 }, m);
    }
    {
        const m = try Modifier.parse("0%");
        try testing.expectEqual(Modifier{ .percent = 1 }, m);
    }
}

test "Modifier: percent" {
    const testing = std.testing;

    {
        const m: Modifier = .{ .percent = 0.8 };
        const v: u32 = m.apply(100);
        try testing.expectEqual(@as(u32, 80), v);
    }
    {
        const m: Modifier = .{ .percent = 1.8 };
        const v: u32 = m.apply(100);
        try testing.expectEqual(@as(u32, 180), v);
    }
}

test "Modifier: absolute" {
    const testing = std.testing;

    {
        const m: Modifier = .{ .absolute = -100 };
        const v: u32 = m.apply(100);
        try testing.expectEqual(@as(u32, 0), v);
    }
    {
        const m: Modifier = .{ .absolute = -120 };
        const v: u32 = m.apply(100);
        try testing.expectEqual(@as(u32, 0), v);
    }
    {
        const m: Modifier = .{ .absolute = 100 };
        const v: u32 = m.apply(100);
        try testing.expectEqual(@as(u32, 200), v);
    }
}