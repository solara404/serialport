const builtin = @import("builtin");
const std = @import("std");
const serialport = @import("../serialport.zig");

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
            settings.cflag.CRTSCTS = true;
        }

        settings.cflag.PARENB = config.parity != .none;
        switch (config.parity) {
            .none, .even => {},
            .odd => settings.cflag.PARODD = true,
            .mark => {
                settings.cflag.PARODD = true;
                settings.cflag.CMSPAR = true;
            },
            .space => {
                settings.cflag.PARODD = false;
                settings.cflag.CMSPAR = true;
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

        const TCIFLUSH = 0;
        const TCOFLUSH = 1;
        const TCIOFLUSH = 2;
        const TCFLSH = 0x540B;

        const result = std.os.linux.syscall3(
            .ioctl,
            @bitCast(@as(isize, @intCast(self.file.?.handle))),
            TCFLSH,
            if (options.input and options.output)
                TCIOFLUSH
            else if (options.input)
                TCIFLUSH
            else
                TCOFLUSH,
        );
        return switch (std.posix.errno(result)) {
            .SUCCESS => {},
            .BADF => error.FileNotFound,
            .NOTTY => error.FileNotTty,
            else => unreachable,
        };
    }

    pub fn poll(self: @This()) !bool {
        if (self.file == null) return false;

        var pollfds: [1]std.os.linux.pollfd = .{
            .{
                .fd = self.file.?.handle,
                .events = std.os.linux.POLL.IN,
                .revents = undefined,
            },
        };
        if (std.os.linux.poll(&pollfds, 1, 0) == 0) return false;

        if (pollfds[0].revents & std.os.linux.POLL.IN == 0) return false;

        const err_mask = std.os.linux.POLL.ERR |
            std.os.linux.POLL.NVAL | std.os.linux.POLL.HUP;

        if (pollfds[0].revents & err_mask != 0) return false;
        return true;
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

test {
    const c = @cImport({
        @cDefine("_XOPEN_SOURCE", "700");
        @cInclude("stdlib.h");
        @cInclude("fcntl.h");
        @cInclude("unistd.h");
    });

    const master = c.posix_openpt(c.O_RDWR);
    if (master < 0)
        return error.MasterPseudoTerminalSetupError;
    defer _ = c.close(master);

    if (c.grantpt(master) < 0 or c.unlockpt(master) < 0)
        return error.MasterPseudoTerminalSetupError;

    const slave_name = c.ptsname(master) orelse
        return error.SlavePseudoTerminalSetupError;
    const slave_name_len = std.mem.len(slave_name);
    if (slave_name_len == 0)
        return error.SlavePseudoTerminalSetupError;

    var port: Port = .{
        .name = slave_name[0..slave_name_len],
        .file = null,
    };
    try port.open();
    defer port.close();

    try std.testing.expectEqual(false, try port.poll());
}
