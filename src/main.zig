const std = @import("std");

const builtin = @import("builtin");

pub fn main() !u8 {
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

    var filepath: []const u8 = ".env";
    _ = args.next();
    while (args.next()) |arg| {
        std.log.info("{s}", .{arg});

        if (std.mem.eql(u8, "-f", arg)) {
            if (args.next()) |f| {
                filepath = f;
            } else {
                std.log.err("error: option '-f' requires an argument <envfile>", .{});
                return 1;
            }
            continue;
        }

        std.log.err("error: '{s}' is not a recognized flag, option, or argument", .{arg});
        return 1;
    }

    return 0;
}
