const builtin = @import("builtin");
const std = @import("std");
const serialport = @import("../serialport.zig");
const c = @cImport({
    @cInclude("termios.h");
});

pub const Port = struct {
    name: []const u8,
    file: ?std.fs.File,

    pub const ReadError = std.fs.File.ReadError;
    pub const Reader = std.fs.File.Reader;
    pub const WriteError = std.fs.File.WriteError;
    pub const Writer = std.fs.File.Writer;

    pub fn open(self: *@This()) !void {
        if (self.file != null) return;
        self.file = try std.fs.cwd().openFile(self.name, .{
            .mode = .read_write,
            .allow_ctty = false,
        });
    }

    pub fn close(self: *@This()) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
    }

    pub fn configure(self: @This(), config: serialport.Config) !void {
        if (self.file == null) return;

        var settings = try std.posix.tcgetattr(self.file.?.handle);

        settings.iflag = .{};
        settings.iflag.INPCK = config.parity != .none;
        settings.iflag.IXON = config.handshake == .software;
        settings.iflag.IXOFF = config.handshake == .software;

        settings.cflag = .{};
        settings.cflag.CREAD = true;
        settings.cflag.CSTOPB = config.stop_bits == .two;
        settings.cflag.CSIZE = @enumFromInt(@intFromEnum(config.word_size));
        if (config.handshake == .hardware) {
            if (comptime builtin.os.tag.isDarwin() or
                builtin.os.tag == .freebsd or builtin.os.tag == .dragonfly)
            {
                settings.cflag.CCTS_OFLOW = true;
                settings.cflag.CRTS_IFLOW = true;
            } else if (comptime builtin.os.tag == .haiku) {
                settings.cflag.CTSFLOW = true;
                settings.cflag.RTSFLOW = true;
            } else {
                settings.cflag.CRTSCTS = true;
            }
        }

        settings.cflag.PARENB = config.parity != .none;
        switch (config.parity) {
            .none, .even => {},
            .odd => settings.cflag.PARODD = true,
            .mark => {
                if (comptime @hasDecl(std.posix.tc_cflag_t, "CMSPAR")) {
                    settings.cflag.PARODD = true;
                    settings.cflag.CMSPAR = true;
                } else return error.ParityMarkSpaceUnsupported;
            },
            .space => {
                if (comptime @hasDecl(std.posix.tc_cflag_t, "CMSPAR")) {
                    settings.cflag.PARODD = false;
                    settings.cflag.CMSPAR = true;
                } else return error.ParityMarkSpaceUnsupported;
            },
        }

        settings.oflag = .{};
        settings.lflag = .{};
        settings.ispeed = config.baud_rate;
        settings.ospeed = config.baud_rate;

        // Minimum arrived bytes before read returns.
        settings.cc[@intFromEnum(std.posix.V.MIN)] = 0;
        // Inter-byte timeout before read returns.
        settings.cc[@intFromEnum(std.posix.V.TIME)] = 0;
        settings.cc[@intFromEnum(std.posix.V.START)] = 0x11;
        settings.cc[@intFromEnum(std.posix.V.STOP)] = 0x13;

        try std.posix.tcsetattr(self.file.?.handle, .NOW, settings);
    }

    pub fn flush(
        self: @This(),
        options: serialport.ManagedPort.FlushOptions,
    ) !void {
        if ((!options.input and !options.output) or self.file == null) return;
        try tcflush(
            self.file.?.handle,
            if (options.input and options.output)
                .IO
            else if (options.input)
                .I
            else
                .O,
        );
    }

    pub fn reader(self: @This()) ?Reader {
        return (self.file orelse return null).reader();
    }

    pub fn writer(self: @This()) ?Writer {
        return (self.file orelse return null).writer();
    }

    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
        allocator.free(self.name);
        self.* = undefined;
    }
};

const TCFLUSH = switch (builtin.os.tag) {
    .openbsd => std.c.TCFLUSH,
    .macos => enum(c_int) {
        I = c.TCIFLUSH,
        O = c.TCOFLUSH,
        IO = c.TCIOFLUSH,
    },
    .linux => enum(usize) {
        I = 0,
        O = 1,
        IO = 2,
    },
    else => @compileError("tcflush unimplemented on this OS"),
};

fn tcflush(fd: std.posix.fd_t, action: TCFLUSH) !void {
    const result = switch (comptime builtin.os.tag) {
        .linux => b: {
            const TCFLSH = 0x540B;
            break :b std.os.linux.syscall3(
                .ioctl,
                @bitCast(@as(isize, @intCast(fd))),
                TCFLSH,
                @intFromEnum(action),
            );
        },
        .macos => b: {
            break :b c.tcflush(fd, @intFromEnum(action));
        },
        else => @compileError("tcflush unimplemented on this OS"),
    };
    return switch (std.posix.errno(result)) {
        .SUCCESS => {},
        .BADF => error.FileNotFound,
        .NOTTY => error.FileNotTty,
        else => unreachable,
    };
}
