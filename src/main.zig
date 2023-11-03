const std = @import("std");

const builtin = @import("builtin");

const String = std.ArrayListUnmanaged(u8);
const HashMap = std.StringHashMapUnmanaged([]const u8);
const ErrorMessages = struct {
    const all_caps = "ENVs must begin with 'export' or 'ALL_CAPS=', not '{s}'";
    const all_caps_esc = "ENVs must begin with 'export' or 'ALL_CAPS=', not \"{}\"";
    const expect_alpha = "ENV keys must begin with 'A-Z' or '_', not '{c}'";
    const export_space = "expected whitespace after 'export' but got '{c}'";
    const expect_eol = "expected end of line (or file), but got '{c}'";
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
        read_unquoted,
        read_unquoted_escape,
        read_literal,
        read_quoted,
        read_quoted_escape,
        read_variable,
        chomp_eol,
    };

    pub const QuoteStyle = enum {
        unquoted,
        literal,
        quoted,
    };

    pub const NewlineStyle = enum {
        crlf,
        newline,
    };

    allocator: std.mem.Allocator,
    map: HashMap = .{},
    newline_style: ?NewlineStyle = null,
    debug: bool = true,

    pub fn deinit(env: *Env) void {
        env.map.deinit(env.allocator);
    }

    /// caller should provide arena and deinit after use
    pub fn parse(env: *Env, src_reader: anytype, writer: anytype) !void {
        var state: State = .chomp_prefix;
        var quote_style: QuoteStyle = .unquoted;

        var is_first_char_of_key = true;
        var key_buf = String{};
        var val_buf = String{};
        var var_buf = String{};
        defer key_buf.deinit(env.allocator);
        defer val_buf.deinit(env.allocator);
        defer var_buf.deinit(env.allocator);

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
                        '\r' => {
                            var next = try reader.readByte();
                            try env.normalizeCrlf(next, writer);
                            try peek_reader.putBackByte(next);
                        },
                        '\n' => {
                            if (env.newline_style == null) {
                                env.newline_style = .newline;
                            }
                            try writer.writeByte(char);
                        },
                        '#' => {
                            consumeComment(char, reader, writer) catch |err| switch (err) {
                                error.EndOfStream => break,
                                else => return err,
                            };
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
                            try peek_reader.putBackByte('e');
                            try mustConsumeExport(reader, writer);

                            const next = try mustConsumeSpaces(reader);
                            try peek_reader.putBackByte(next);
                            try writer.writeByte(' ');
                        },
                        'A'...'Z', '_' => {
                            is_first_char_of_key = false;
                            try key_buf.append(env.allocator, char);
                            try writer.writeByte(char);
                        },
                        '0'...'9' => {
                            if (is_first_char_of_key) {
                                std.log.err(ErrorMessages.expect_alpha, .{char});
                                return error.Failed;
                            }
                            // TODO must begin with [A-Z_]
                            try key_buf.append(env.allocator, char);
                            try writer.writeByte(char);
                        },
                        '=' => {
                            is_first_char_of_key = true;
                            const key = key_buf.items;
                            if (env.map.contains(key)) {
                                std.log.err(ErrorMessages.duplicate_key, .{key});
                                return error.Failed;
                            }
                            std.debug.print("{s}=", .{key});

                            try writer.writeByte(char);
                            // TODO dupe keyname somewhere

                            key_buf.items.len = 0;
                            val_buf.items.len = 0;
                            var_buf.items.len = 0;

                            var next = try reader.readByte();
                            switch (next) {
                                '\'' => {
                                    if (env.debug) try val_buf.append(env.allocator, next);
                                    quote_style = .literal;
                                    state = .read_literal;
                                },
                                '"' => {
                                    if (env.debug) try val_buf.append(env.allocator, next);
                                    quote_style = .quoted;
                                    state = .read_quoted;
                                },
                                else => {
                                    quote_style = .unquoted;
                                    state = .read_unquoted;
                                    try peek_reader.putBackByte(next);
                                },
                            }
                        },
                        else => {
                            try key_buf.append(env.allocator, char);

                            // std.debug.print("{}", .{std.zig.fmtEscapes(bytes)})
                            // https://ziglang.org/documentation/master/std/#A;std:zig.fmtEscapes
                            std.log.err(ErrorMessages.all_caps_esc, .{std.zig.fmtEscapes(key_buf.items)});
                            //std.log.err(ErrorMessages.all_caps, .{key_buf.items});
                            return error.Failed;
                        },
                    }
                },
                .read_unquoted => {
                    var char = try reader.readByte();
                    switch (char) {
                        '\\' => {
                            if (env.debug) try val_buf.append(env.allocator, char);
                            try writer.writeByte(char);
                            state = .read_unquoted_escape;
                        },
                        '\'' => {
                            if (env.debug) try val_buf.append(env.allocator, char);
                            state = .read_literal;
                        },
                        '"' => {
                            if (env.debug) try val_buf.append(env.allocator, char);
                            state = .read_quoted;
                        },
                        ' ', '\t' => {
                            // continuation of the output string 'MY_KEY='
                            std.debug.print("{s}\n", .{val_buf.items});
                            //std.debug.print("{'}\n", .{std.zig.fmtEscapes(val_buf.items)});
                            val_buf.items.len = 0;
                            var_buf.items.len = 0;
                            state = .chomp_eol;
                        },
                        '\r' => {
                            var next = try reader.readByte();
                            try env.normalizeCrlf(next, writer);
                            try peek_reader.putBackByte(next);
                        },
                        '\n' => {
                            if (env.newline_style == null) {
                                env.newline_style = .newline;
                            }
                            // TODO read for \n after \r
                            // continuation of MY_KEY=
                            std.debug.print("{s}\n", .{val_buf.items});
                            //std.debug.print("{'}\n", .{std.zig.fmtEscapes(val_buf.items)});
                            val_buf.items.len = 0;
                            try writer.writeByte(char);
                            state = .chomp_prefix;
                        },
                        else => {
                            try val_buf.append(env.allocator, char);
                            try writer.writeByte(char);
                        },
                    }
                },
                .read_unquoted_escape => {
                    // TODO escape the next thing (space, newline, etc)
                    // (or just don't allow unquoted escapes)
                    var char = try reader.readByte();
                    try writer.writeByte(char);
                    try val_buf.append(env.allocator, char);
                    switch (char) {
                        '\'' => {
                            if (env.debug) try val_buf.append(env.allocator, char);
                            // don't change to .read_literal
                        },
                        '"' => {
                            if (env.debug) try val_buf.append(env.allocator, char);
                            // don't change to .read_quoted
                        },
                        '\\' => {
                            if (env.debug) try val_buf.append(env.allocator, char);
                            // don't change behavior
                        },
                        '\r' => {
                            var next = try reader.readByte();
                            try env.normalizeCrlf(next, writer);
                            switch (next) {
                                '\n' => try writer.writeByte('\n'),
                                else => try peek_reader.putBackByte(next),
                            }
                        },
                        ' ', '\t', '\n' => {
                            // don't change from .read_unquoted
                        },
                        else => {
                            std.log.err("unexpected escape value \\{c}", .{char});
                            return error.Failed;
                        },
                    }
                    state = .read_unquoted;
                },
                .read_literal => {
                    var char = try reader.readByte();
                    try writer.writeByte(char);
                    switch (char) {
                        '\'' => {
                            if (env.debug) try val_buf.append(env.allocator, char);
                            state = .read_unquoted;
                        },
                        else => {
                            try val_buf.append(env.allocator, char);
                        },
                    }
                },
                .read_quoted => {
                    var char = try reader.readByte();
                    try writer.writeByte(char);
                    switch (char) {
                        '\\' => {
                            if (env.debug) try val_buf.append(env.allocator, char);
                            try writer.writeByte(char);
                            state = .read_quoted_escape;
                        },
                        '"' => {
                            if (env.debug) try val_buf.append(env.allocator, char);
                            state = .read_unquoted;
                        },
                        '$' => {
                            // TODO read { and track
                            try val_buf.append(env.allocator, char);
                            state = .read_variable;
                        },
                        else => {
                            try val_buf.append(env.allocator, char);
                        },
                    }
                },
                .read_quoted_escape => {
                    // TODO escape the next thing (space, newline, etc)
                    // (or just don't allow unquoted escapes)
                    var char = try reader.readByte();

                    switch (char) {
                        // do read \
                        '\\' => {},
                        // don't switch to .read_unquoted
                        '"' => {},
                        // don't switch to .read_variable
                        '$' => {},
                        else => {
                            std.log.err("unexpected escape value \\{c}", .{char});
                            return error.Failed;
                        },
                    }

                    try val_buf.append(env.allocator, char);
                    state = .read_quoted;
                },
                .read_variable => {
                    std.log.err("TODO: we can't read vars yet!", .{});
                    return error.Failed;
                },
                .chomp_eol => {
                    var char = reader.readByte() catch |err| switch (err) {
                        error.EndOfStream => break,
                        else => return err,
                    };
                    switch (char) {
                        ' ', '\t' => {
                            // chomp chomp chomp
                        },
                        '\r' => {
                            // TODO check for \n
                            try writer.writeByte(char);
                            state = .chomp_prefix;
                        },
                        '\n' => {
                            if (env.newline_style == null) {
                                env.newline_style = .newline;
                            }
                            try writer.writeByte(char);
                            state = .chomp_prefix;
                        },
                        '#' => {
                            try writer.writeByte(' ');
                            consumeComment(char, reader, writer) catch |err| switch (err) {
                                error.EndOfStream => break,
                                else => return err,
                            };
                            state = .chomp_prefix;
                        },
                        else => {
                            std.log.err(ErrorMessages.expect_eol, .{char});
                            return error.Failed;
                        },
                    }
                },
                else => {
                    break :state_loop;
                },
            }
        }
        std.log.err("that's all that's implemented right now", .{});
        return error.Failed;
    }

    inline fn normalizeCrlf(env: *Env, next: u8, writer: anytype) !void {
        var next_is_newline = switch (next) {
            '\n' => true,
            else => false,
        };

        if (env.newline_style == null) {
            env.newline_style = if (next_is_newline) .crlf else .newline;
        }

        if (env.newline_style) |newlines| {
            switch (newlines) {
                .crlf => try writer.writeByte('\r'),
                else => {},
            }
            // fix bad 'crlf's
            // treat stray '\r's as newlines
            if (!next_is_newline) {
                try writer.writeByte('\n');
            }
        }
    }

    inline fn consumeComment(char: u8, reader: anytype, writer: anytype) !void {
        try writer.writeByte(char);
        while (true) {
            var next = try reader.readByte();
            switch (next) {
                '\r' => {
                    // TODO check for \n
                    try writer.writeByte(char);
                    break;
                },
                '\n' => {
                    try writer.writeByte(char);
                    break;
                },
                else => {
                    try writer.writeByte(char);
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
