const std = @import("std");

const builtin = @import("builtin");

const HashMap = std.StringHashMapUnmanaged([]const u8);
const ErrorMessages = struct {
    const all_caps = "ENVs must begin with 'export ' or ALL_CAPS, not e{s}";
};

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

    var maybe_filepath: ?[]const u8 = null;
    var write = false;

    _ = args.next();
    while (args.next()) |arg| {
        std.log.info("{s}", .{arg});

        if (std.mem.eql(u8, "-f", arg)) {
            if (args.next()) |filepath| {
                maybe_filepath = filepath;
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

    const is_tty = std.os.isatty(std.os.STDIN_FILENO);
    const read_file = if (maybe_filepath) |filepath|
        !std.mem.eql(u8, "-", filepath)
    else if (is_tty) true else false;

    var file = if (read_file)
        openFile(maybe_filepath orelse ".env", write) catch return 1
    else
        std.io.getStdIn();
    defer if (read_file) file.close();

    var buffered_reader = std.io.BufferedReader(
        4096,
        @TypeOf(file.reader()),
    ){ .unbuffered_reader = file.reader() };
    const reader = buffered_reader.reader();

    var env = Env{ .allocator = allocator };
    defer env.deinit();
    _ = try env.parse(reader);

    return 0;
}

pub const Env = struct {
    pub const State = enum {
        start,
        value,
        variable,
        single_quote,
        double_quote,
        escape,
    };

    allocator: std.mem.Allocator,
    map: HashMap = .{},

    pub fn deinit(env: *Env) void {
        env.map.deinit(env.allocator);
    }

    /// caller should provide arena and deinit after use
    pub fn parse(env: *Env, reader: anytype) !void {
        var state: State = .start;

        // '#' ignore all until end of line
        // 'export ' ignore
        // 'UPPER_SNAKES'
        var name_buf = std.ArrayListUnmanaged(u8){};
        defer name_buf.deinit(env.allocator);
        state_loop: while (true) {
            // we only handle UTF-8 - because we're sane
            const char = try reader.readByte();
            switch (state) {
                .start => {
                    switch (char) {
                        ' ', '\r', '\n', '\t' => {},
                        '#' => {
                            while (true) {
                                const next = try reader.readByte();
                                switch (next) {
                                    '\r', '\n' => break,
                                    else => {},
                                }
                            }
                        },
                        'e' => {
                            const chars = try reader.readBytesNoEof(6);
                            // e'xport '
                            if (!std.mem.eql(u8, "xport ", &chars)) {
                                std.log.err(ErrorMessages.all_caps, .{chars});
                                return error.Failed;
                            }
                        },
                        else => {
                            name_buf.items.len = 0;
                            try name_buf.append(env.allocator, char);
                            while (true) {
                                const next = try reader.readByte();
                                switch (next) {
                                    'A'...'Z' => {
                                        try name_buf.append(env.allocator, next);
                                    },
                                    '=' => {
                                        state = .value;
                                        break;
                                    },
                                    else => {
                                        std.log.err(ErrorMessages.all_caps, .{"TODO"});
                                        return error.Failed;
                                    },
                                }
                            }

                            std.log.info("{s}", .{name_buf.items});

                            // TODO do the rest of the stuff

                            break :state_loop;
                        },
                    }
                },
                else => {
                    return error.Failed;
                },
            }
        }
    }
};

inline fn openFile(filepath: []const u8, write: bool) error{Failed}!std.fs.File {
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
