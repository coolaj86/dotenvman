const std = @import("std");

const builtin = @import("builtin");

const String = std.ArrayListUnmanaged(u8);
const HashMap = std.StringHashMapUnmanaged([]const u8);
const ErrorMessages = struct {
    const all_caps = "ENVs must begin with 'export' or 'ALL_CAPS=', saw '{s}'";
    const all_caps_esc = "ENVs must begin with 'export' or 'ALL_CAPS=', saw \"{}\"";
    const expect_alpha_start = "ENVs must begin with 'A-Z', not '{c}'";
    const expect_alpha_middle = "ENVs may only use [0-9_A-Z], not '{c}'";
    const expect_alpha_end = "ENVs must end with 'A-Z0-9', not '{c}'";
    const export_space = "expected <space> or <tab> after 'export', saw '{c}'";
    const expect_eol = "expected end of line (or file), saw '{c}'";
    const quote_dollar = "'$' must be quoted, ex: '$1.00' or \"$FOOBAR\"";
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
        var envMap = try std.process.getEnvMap(env.allocator);
        defer envMap.deinit();
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
                                std.log.err(ErrorMessages.expect_alpha_start, .{char});
                                return error.Failed;
                            }
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
                        '$' => {
                            std.log.err(ErrorMessages.quote_dollar, .{});
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
                            var_buf.items.len = 0;

                            var next = try reader.readByte();
                            var is_curly_var = next == '{';
                            if (!is_curly_var) {
                                try peek_reader.putBackByte(next);
                            }
                            // TODO get feedback / code review on use of 0
                            next = env.readName(reader, &var_buf) catch |err| switch (err) {
                                error.EndOfStream => 0,
                                else => return err,
                            };
                            switch (next) {
                                0, '}' => {},
                                else => try peek_reader.putBackByte(next),
                            }

                            if (is_curly_var) {
                                if (next != '}') {
                                    std.log.err("variable not closed, saw ${c}{s}", .{ '{', var_buf.items });
                                    return error.Failed;
                                }
                            }

                            if (env.debug) {
                                try val_buf.append(env.allocator, '$');
                                if (is_curly_var) {
                                    try val_buf.append(env.allocator, '{');
                                }
                                try val_buf.appendSlice(env.allocator, var_buf.items);
                                try val_buf.append(env.allocator, '=');
                            }

                            if (env.map.get(var_buf.items)) |val| {
                                try val_buf.appendSlice(env.allocator, val);
                            } else if (envMap.get(var_buf.items)) |val| {
                                try val_buf.appendSlice(env.allocator, val);
                            } else {
                                std.log.err("[warn] accessed undefined ENV '${s}'", .{var_buf.items});
                            }

                            if (env.debug) {
                                if (is_curly_var) {
                                    try val_buf.append(env.allocator, '}');
                                }
                            }
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

    /// Reads a POSIX Environment Variable (strict subset of POSIX Name)
    ///
    /// TODO --lax-name to permit any POSIX Name as an ENV Name
    ///
    /// From POSIX 8.1:
    ///   Environment variable names consist solely of uppercase letters,
    ///   digits, and the <underscore> ( '_' )
    ///
    /// From POSIX 3.235:
    ///   A name is a word consisting of underscores, digits, and alphabetics
    ///   from the portable character set.
    ///   The first character of a name is not a digit.
    ///
    /// We further restrict the POSIX Environment Variable Name in which
    ///   - the first character is not '_' (must be [A-Z])
    ///   - the last character is not '_' (must be [A-Z0-9])
    ///
    /// See also:
    ///
    ///   - POSIX Environment Variable Definition
    ///     https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap08.html#tag_08_01
    ///   - POSIX Other Environment Variables
    ///     https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap08.html#tag_08_03
    ///   - POSIX Name ([A-Z_a-z][0-9A-Z_a-z]+)
    ///     https://pubs.opengroup.org/onlinepubs/9699919799/basedefs/V1_chap03.html#tag_03_235
    ///   - POSIX Portable Character Set (ASCII bytes 0, 7-9, 10-13, 32-126)
    ///     https://pubs.opengroup.org/onlinepubs/009696899/basedefs/xbd_chap06.html#tag_06_01
    fn readName(env: *Env, reader: anytype, var_buf: *String) !u8 {
        // Start Pattern: [A-Z]
        var char = try reader.readByte();
        switch (char) {
            'A'...'Z' => {
                try var_buf.append(env.allocator, char);
            },
            // TODO: error message for '_': consider commenting out unused ENVs
            else => {
                std.log.err(ErrorMessages.expect_alpha_start, .{char});
                return error.Failed;
            },
        }

        // Word Pattern: [0-9_A-Z]
        var prev = char;
        while (true) {
            char = try reader.readByte();
            switch (char) {
                'A'...'Z', '0'...'9', '_' => {
                    try var_buf.append(env.allocator, char);
                },
                else => {
                    break;
                },
            }
            prev = char;
        }

        // End Pattern: [A-Z0-9]
        if (prev == '_') {
            // TODO: error message for '_': consider commenting out unused ENVs
            std.log.err(ErrorMessages.expect_alpha_end, .{char});
            return error.Failed;
        }

        return char;
    }

    fn normalizeCrlf(env: *Env, next: u8, writer: anytype) !void {
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

    fn consumeComment(char: u8, reader: anytype, writer: anytype) !void {
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

    fn mustConsumeExport(reader: anytype, writer: anytype) !void {
        const chars = try reader.readBytesNoEof(6);
        if (!std.mem.eql(u8, "export", &chars)) {
            std.log.err(ErrorMessages.all_caps, .{chars});
            return error.Failed;
        }
        try writer.writeAll(&chars);
    }

    fn mustConsumeSpaces(reader: anytype) !u8 {
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

    fn consumeValue(env: *Env, reader: anytype, value_buf: *String) !void {
        _ = env;
        _ = reader;
        _ = value_buf;
        // const first = try reader.readByte();
        // switch (first) {
        // }
    }
};

fn openFile(filepath: []const u8, write: bool) error{Failed}!std.fs.File {
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
