//! Pure geometry for compiled occurrence image maps. No source parsing or I/O.
const std = @import("std");
const A = std.mem.Allocator;
const GeometryError = error{GeometryUnavailable};

pub const Shape = enum { rectangle, circle, polygon };
pub const Layout = struct {
    original_width: u32,
    original_height: u32,
    width: f64,
    height: f64,
};
pub const Bounds = struct { left: f64, top: f64, width: f64, height: f64 };
pub const Point = struct { x: f64, y: f64 };
pub const Hit = union(enum) { outside, none, default_action, region: usize };
pub const Region = struct { shape: Shape, coordinates: []const f64 };
pub const Prepared = struct {
    regions: []const Region,
    width: f64,
    height: f64,
    has_default: bool,

    pub fn deinit(self: Prepared, a: A) void {
        for (self.regions) |region| a.free(region.coordinates);
        a.free(self.regions);
    }

    pub fn hit(self: Prepared, painted: Bounds, point: Point) GeometryError!Hit {
        if (!finite(painted.left) or !finite(painted.top) or !positive(painted.width) or
            !positive(painted.height) or !finite(point.x) or !finite(point.y)) return error.GeometryUnavailable;
        if (point.x < painted.left or point.y < painted.top) return .outside;
        const dx = try checked(point.x - painted.left);
        const dy = try checked(point.y - painted.top);
        if (dx >= painted.width or dy >= painted.height) return .outside;
        const local: Point = .{
            .x = try checked((dx / painted.width) * self.width),
            .y = try checked((dy / painted.height) * self.height),
        };
        for (self.regions, 0..) |region, index| {
            if (try contains(region, local)) return .{ .region = index };
        }
        return if (self.has_default) .default_action else .none;
    }
};

fn finite(value: f64) bool { return std.math.isFinite(value); }
fn positive(value: f64) bool { return finite(value) and value > 0; }
fn checked(value: f64) GeometryError!f64 {
    if (!finite(value)) return error.GeometryUnavailable;
    return value;
}

/// Scale and round in the unzoomed image-layout plane. The caller separately
/// supplies the actual painted content bounds, excluding border and padding.
/// ImageMap c35cb94 uses this summed-axis ratio and half-away rounding.
pub fn prepare(a: A, map: anytype, layout: Layout) (A.Error || GeometryError)!Prepared {
    if (layout.original_width == 0 or layout.original_height == 0 or !positive(layout.width) or
        !positive(layout.height)) return error.GeometryUnavailable;
    const original_sum: f64 = @as(f64, @floatFromInt(layout.original_width)) + @as(f64, @floatFromInt(layout.original_height));
    const scale = try checked((try checked(layout.width + layout.height)) / original_sum);
    if (scale <= 0) return error.GeometryUnavailable;
    var remaining: usize = 1 << 20;
    if (map.regions.len > remaining) return error.GeometryUnavailable;
    remaining -= map.regions.len;
    if (map.default_action != null) {
        if (remaining == 0) return error.GeometryUnavailable;
        remaining -= 1;
    }
    var regions: std.ArrayList(Region) = .empty;
    errdefer {
        for (regions.items) |region| a.free(region.coordinates);
        regions.deinit(a);
    }
    for (map.regions) |region| {
        const shape = std.meta.stringToEnum(Shape, @tagName(region.shape)) orelse return error.GeometryUnavailable;
        const count = region.coordinates.len;
        if (count > remaining or switch (shape) {
            .rectangle => count != 4,
            .circle => count != 3,
            .polygon => count < 6 or count % 2 != 0,
        }) return error.GeometryUnavailable;
        remaining -= count;
        const coordinates = try a.alloc(f64, count);
        errdefer a.free(coordinates);
        for (region.coordinates, coordinates) |original, *scaled| {
            if (!finite(original)) return error.GeometryUnavailable;
            scaled.* = try checked(@round(try checked(original * scale)));
        }
        try regions.append(a, .{ .shape = shape, .coordinates = coordinates });
    }
    return .{ .regions = try regions.toOwnedSlice(a), .width = layout.width, .height = layout.height, .has_default = map.default_action != null };
}

fn onSegment(a: Point, b: Point, p: Point) GeometryError!bool {
    if (p.x < @min(a.x, b.x) or p.x > @max(a.x, b.x) or p.y < @min(a.y, b.y) or p.y > @max(a.y, b.y)) return false;
    const dx = try checked(b.x - a.x);
    const dy = try checked(b.y - a.y);
    const px = try checked(p.x - a.x);
    const py = try checked(p.y - a.y);
    const lhs = try checked(dx * py);
    const rhs = try checked(dy * px);
    return lhs == rhs;
}

fn contains(region: Region, point: Point) GeometryError!bool {
    const c = region.coordinates;
    switch (region.shape) {
        .rectangle => {
            const left = @min(c[0], c[2]);
            const right = @max(c[0], c[2]);
            const top = @min(c[1], c[3]);
            const bottom = @max(c[1], c[3]);
            if (left == right or top == bottom) return false;
            return point.x >= left and point.x <= right and point.y >= top and point.y <= bottom;
        },
        .circle => {
            if (c[2] <= 0) return false;
            const dx = try checked(point.x - c[0]);
            const dy = try checked(point.y - c[1]);
            const squared = try checked((try checked(dx * dx)) + (try checked(dy * dy)));
            return squared <= try checked(c[2] * c[2]);
        },
        .polygon => {
            var inside = false;
            var previous: Point = .{ .x = c[c.len - 2], .y = c[c.len - 1] };
            var index: usize = 0;
            while (index < c.len) : (index += 2) {
                const current: Point = .{ .x = c[index], .y = c[index + 1] };
                if (try onSegment(previous, current, point)) return true;
                if ((previous.y > point.y) != (current.y > point.y)) {
                    const fraction = try checked((try checked(point.y - current.y)) / (try checked(previous.y - current.y)));
                    const crossing = try checked(current.x + (try checked(fraction * (try checked(previous.x - current.x)))));
                    if (point.x < crossing) inside = !inside;
                }
                previous = current;
            }
            return inside;
        },
    }
}

const TestMap = struct { regions: []const Region, default_action: ?u8 = null };
const unit_layout: Layout = .{ .original_width = 100, .original_height = 100, .width = 100, .height = 100 };
const unit_bounds: Bounds = .{ .left = 0, .top = 0, .width = 100, .height = 100 };

test "image map immutable scaling rounds coordinates before density and content projection" {
    const a = std.testing.allocator;
    const values = [_]Region{.{ .shape = .polygon, .coordinates = &.{ -1, -1, 3, -1, 3, 3, -1, 3 } }};
    const scaled = try prepare(a, TestMap{ .regions = &values }, .{ .original_width = 100, .original_height = 100, .width = 50, .height = 50 });
    defer scaled.deinit(a);
    try std.testing.expectEqualSlices(f64, &.{ -1, -1, 2, -1, 2, 2, -1, 2 }, scaled.regions[0].coordinates);
    const bounds: Bounds = .{ .left = 30, .top = 40, .width = 100, .height = 100 };
    try std.testing.expectEqual(Hit{ .region = 0 }, try scaled.hit(bounds, .{ .x = 34, .y = 44 }));
    try std.testing.expectEqual(Hit.none, try scaled.hit(bounds, .{ .x = 35, .y = 45 }));
    try std.testing.expectEqual(Hit.outside, try scaled.hit(bounds, .{ .x = 29, .y = 40 }));
    try std.testing.expectEqual(Hit.outside, try scaled.hit(bounds, .{ .x = 130, .y = 40 }));
}

test "image map hit rules retain order corners closed edges empty radii and even odd polygons" {
    const a = std.testing.allocator;
    const values = [_]Region{
        .{ .shape = .rectangle, .coordinates = &.{ 20, 20, 10, 10 } },
        .{ .shape = .circle, .coordinates = &.{ 20, 20, 10 } },
        .{ .shape = .polygon, .coordinates = &.{ 40, 40, 60, 60, 40, 60, 60, 40 } },
    };
    const map = try prepare(a, TestMap{ .regions = &values, .default_action = 1 }, unit_layout);
    defer map.deinit(a);
    try std.testing.expectEqual(Hit{ .region = 0 }, try map.hit(unit_bounds, .{ .x = 20, .y = 20 }));
    try std.testing.expectEqual(Hit{ .region = 1 }, try map.hit(unit_bounds, .{ .x = 30, .y = 20 }));
    try std.testing.expectEqual(Hit{ .region = 2 }, try map.hit(unit_bounds, .{ .x = 50, .y = 45 }));
    try std.testing.expectEqual(Hit{ .region = 2 }, try map.hit(unit_bounds, .{ .x = 50, .y = 50 }));
    try std.testing.expectEqual(Hit.default_action, try map.hit(unit_bounds, .{ .x = 45, .y = 50 }));
    const empty = [_]Region{
        .{ .shape = .circle, .coordinates = &.{ 5, 5, -1 } },
        .{ .shape = .circle, .coordinates = &.{ 5, 5, 0 } },
        .{ .shape = .rectangle, .coordinates = &.{ 5, 5, 5, 10 } },
    };
    const no_hit = try prepare(a, TestMap{ .regions = &empty }, unit_layout);
    defer no_hit.deinit(a);
    try std.testing.expectEqual(Hit.none, try no_hit.hit(unit_bounds, .{ .x = 5, .y = 5 }));
}

test "image map unavailable geometry preserves finite source data and never guesses a background action" {
    const a = std.testing.allocator;
    const huge = [_]Region{.{ .shape = .circle, .coordinates = &.{ 0, 0, std.math.floatMax(f64) } }};
    const map = try prepare(a, TestMap{ .regions = &huge, .default_action = 1 }, unit_layout);
    defer map.deinit(a);
    try std.testing.expectEqual(std.math.floatMax(f64), map.regions[0].coordinates[2]);
    try std.testing.expectError(error.GeometryUnavailable, map.hit(unit_bounds, .{ .x = 1, .y = 1 }));
    try std.testing.expectError(error.GeometryUnavailable, prepare(a, TestMap{ .regions = &huge }, .{ .original_width = 1, .original_height = 1, .width = 100, .height = 100 }));
    try std.testing.expectError(error.GeometryUnavailable, prepare(a, TestMap{ .regions = &.{} }, .{ .original_width = 0, .original_height = 1, .width = 1, .height = 1 }));
    try std.testing.expectError(error.GeometryUnavailable, map.hit(.{ .left = 0, .top = 0, .width = 0, .height = 1 }, .{ .x = 0, .y = 0 }));
    const empty_map = try prepare(a, TestMap{ .regions = &.{} }, unit_layout);
    defer empty_map.deinit(a);
    try std.testing.expectEqual(Hit.none, try empty_map.hit(unit_bounds, .{ .x = 5, .y = 5 }));
    const default_map = try prepare(a, TestMap{ .regions = &.{}, .default_action = 1 }, unit_layout);
    defer default_map.deinit(a);
    try std.testing.expectEqual(Hit.default_action, try default_map.hit(unit_bounds, .{ .x = 5, .y = 5 }));
    try std.testing.expectEqual(Hit.outside, try default_map.hit(unit_bounds, .{ .x = 100, .y = 5 }));
}
