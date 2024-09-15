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

    pub fn configure(self: *@This(), config: serialport.Config) !void {
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
        settings.cflag.CRTSCTS = config.handshake == .hardware;
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

    pub fn close(self: *@This()) void {
        if (self.file) |f| {
            f.close();
            self.file = null;
        }
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
