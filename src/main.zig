const std = @import("std");

const builtin = @import("builtin");

pub fn main() !void {
    var gpa = if (builtin.mode == .Debug) blk: {
        std.log.info("builtin.mode == .Debug", .{});
        const GpaAlloc = std.heap.GeneralPurposeAllocator(.{});
        break :blk GpaAlloc{
            .backing_allocator = std.heap.page_allocator,
        };
    } else blk: {
        break :blk void{};
    };
    defer if (builtin.mode == .Debug) {
        std.debug.print("Checking for memory leaks...", .{});
        _ = gpa.deinit();
        std.debug.print(" OK (all memory deallocated)\n", .{});
    };

    var allocator = if (builtin.mode == .Debug) blk: {
        break :blk gpa.allocator();
    } else blk: {
        break :blk std.heap.page_allocator;
    };

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    // cause a memory leak on purpose to observe the leak detector
    //_ = try allocator.create(u8);

    while (args.next()) |arg| {
        std.log.info("{s}", .{arg});
    }
}
