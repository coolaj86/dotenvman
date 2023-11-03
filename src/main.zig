const std = @import("std");

const builtin = @import("builtin");

const String = std.ArrayListUnmanaged(u8);
const HashMap = std.StringHashMapUnmanaged([]const u8);
const ErrorMessages = struct {
    const all_caps = "ENVs must begin with 'export' or 'ALL_CAPS=', not '{s}'";
    const export_space = "expected whitespace after 'export' but got '{c}'";
    const duplicate_key = "duplicated key '{s}='";
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
        if (gpa.deinit() == .ok) {
            std.debug.print(" OK (all memory deallocated)\n", .{});
        } else {
            std.log.err("Oops! Got some memory unleakin' to do!", .{});
        }
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

    // TODO open a file or stdout when in write mode
    var buffered_writer = std.io.BufferedWriter(
        4096,
        @TypeOf(std.io.null_writer),
    ){ .unbuffered_writer = std.io.null_writer };
    const writer = buffered_writer.writer();

    var env = Env{ .allocator = allocator };
    defer env.deinit();
    _ = try env.parse(reader, writer);

    return 0;
}

pub const Env = struct {
    pub const State = enum {
        chomp_prefix,
        read_key,
        chomp_export,
        chomp_whitespace,
        read_unquoted,
    };

    allocator: std.mem.Allocator,
    map: HashMap = .{},

    pub fn deinit(env: *Env) void {
        env.map.deinit(env.allocator);
    }

    /// caller should provide arena and deinit after use
    pub fn parse(env: *Env, src_reader: anytype, writer: anytype) !void {
        //var had_cr = true; // preserve windows whitespace
        var state: State = .chomp_prefix;
        //var prev: State = .read_key;

        var str_buf = String{};
        defer str_buf.deinit(env.allocator);

        // var buffered_reader = std.io.BufferedReader(
        //     4096,
        //     @TypeOf(file.reader()),
        // ){ .unbuffered_reader = file.reader() };
        // const reader = buffered_reader.reader();

        const lookahead = 10;
        var peek_reader = std.io.PeekStream(
            .{ .Static = lookahead },
            @TypeOf(src_reader),
        ).init(src_reader);
        const reader = peek_reader.reader();

        // '#' ignore all until end of line
        // 'export ' ignore
        // 'UPPER_SNAKES'
        state_loop: while (true) {
            // we only handle UTF-8 - because we're sane
            switch (state) {
                .chomp_prefix => {
                    var char = try reader.readByte();
                    switch (char) {
                        ' ', '\t' => {
                            // chomp chomp chomp!
                            // (no leading or trailing spaces)
                        },
                        '\r', '\n' => {
                            try writer.writeByte(char);
                        },
                        '#' => {
                            try writer.writeByte(char);
                            while (true) {
                                var next = try reader.readByte();
                                switch (next) {
                                    '\r', '\n' => {
                                        try writer.writeByte(char);
                                        break;
                                    },
                                    else => {
                                        try writer.writeByte(char);
                                    },
                                }
                            }
                        },
                        else => {
                            try peek_reader.putBackByte(char);
                            state = .read_key;
                        },
                    }
                },
                .read_key => {
                    var char = try reader.readByte();
                    switch (char) {
                        'e' => {
                            try peek_reader.putBackByte(char);
                            try mustConsumeExport(reader, writer);

                            const next = try mustConsumeSpaces(reader);
                            try peek_reader.putBackByte(next);
                            try writer.writeByte(' ');
                        },
                        'A'...'Z' => {
                            try str_buf.append(env.allocator, char);
                            try writer.writeByte(char);
                        },
                        '=' => {
                            const key = str_buf.items;
                            if (env.map.contains(key)) {
                                std.log.err(ErrorMessages.duplicate_key, .{key});
                                return error.Failed;
                            }
                            std.log.info("{s}=", .{key});

                            try writer.writeByte(char);
                            state = .read_unquoted;
                        },
                        else => {
                            // TODO
                            // https://ziglang.org/documentation/master/std/#A;std:zig.fmtEscapes
                            switch (char) {
                                '\r' => {
                                    try str_buf.append(env.allocator, '\\');
                                    try str_buf.append(env.allocator, 'r');
                                },
                                '\n' => {
                                    try str_buf.append(env.allocator, '\\');
                                    try str_buf.append(env.allocator, 'n');
                                },
                                else => {
                                    try str_buf.append(env.allocator, char);
                                },
                            }
                            std.log.err(ErrorMessages.all_caps, .{str_buf.items});
                            return error.Failed;
                        },
                    }
                },
                .read_unquoted => {
                    std.log.err("that's all that's implemented right now", .{});
                    return error.Failed;
                },
                else => {
                    break :state_loop;
                },
            }
        }
    }

    inline fn mustConsumeExport(reader: anytype, writer: anytype) !void {
        const chars = try reader.readBytesNoEof(6);
        if (!std.mem.eql(u8, "export", &chars)) {
            std.log.err(ErrorMessages.all_caps, .{chars});
            return error.Failed;
        }
        try writer.writeAll(&chars);
    }

    inline fn mustConsumeSpaces(reader: anytype) !u8 {
        var has_space = false;
        while (true) {
            var next = try reader.readByte();
            switch (next) {
                ' ', '\t' => {
                    has_space = true;
                },
                else => {
                    if (!has_space) {
                        std.log.err(ErrorMessages.export_space, .{next});
                        return error.Failed;
                    }
                    return next;
                },
            }
        }
    }

    inline fn consumeValue(env: *Env, reader: anytype, value_buf: *String) !void {
        _ = env;
        _ = reader;
        _ = value_buf;
        // const first = try reader.readByte();
        // switch (first) {
        // }
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
