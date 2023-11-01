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

    var filepath: ?[]const u8 = null;
    var force_stdin = false;
    var write = false;

    _ = args.next();
    while (args.next()) |arg| {
        std.log.info("{s}", .{arg});

        if (std.mem.eql(u8, "-f", arg)) {
            if (args.next()) |_filepath| {
                if (std.mem.eql(u8, "-", _filepath)) {
                    force_stdin = true;
                }
                filepath = _filepath;
            } else {
                std.log.err("option '-f' requires an argument <envfile>", .{});
                return 1;
            }
            continue;
        }

        if (std.mem.eql(u8, "-w", arg)) {
            write = true;
            continue;
        }

        std.log.err("'{s}' is not a recognized flag, option, or argument", .{arg});
        return 1;
    }

    const is_stdin = force_stdin;
    var file = if (is_stdin)
        std.io.getStdIn()
    else
        openFile(filepath, write) catch return 1;
    defer if (!is_stdin) file.close();

    const reader = file.reader();
    var b = try reader.readByte();
    std.log.info("{c}", .{b});

    return 0;
}

inline fn openFile(maybe_filepath: ?[]const u8, write: bool) error{Failed}!std.fs.File {
    var filepath = maybe_filepath orelse ".env";

    return std.fs.cwd().openFile(
        filepath,
        .{
            .mode = if (write) .read_write else .read_only,
        },
    ) catch |err| {
        switch (err) {
            error.FileNotFound => {
                std.log.err("'{s}' does not exist (ENOENT)", .{filepath});
            },
            error.AccessDenied => {
                std.log.err("could not access '{s}' (EPERM)", .{filepath});
            },
            else => {
                std.log.err("failed to open '{s}' with {s}", .{ filepath, @errorName(err) });
            },
        }
        return error.Failed;
    };
}
