const builtin = @import("builtin");
const std = @import("std");
const serialport = @import("../serialport.zig");

pub const PortImpl = std.fs.File;

pub const ReadError = std.fs.File.ReadError;
pub const Reader = std.fs.File.Reader;
pub const WriteError = std.fs.File.WriteError;
pub const Writer = std.fs.File.Writer;

pub fn open(path: []const u8) !PortImpl {
    return try std.fs.cwd().openFile(path, .{
        .mode = .read_write,
        .allow_ctty = false,
    });
}

pub fn close(port: PortImpl) void {
    port.close();
}

pub fn configure(port: PortImpl, config: serialport.Config) !void {
    var settings = try std.posix.tcgetattr(port.handle);

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

    try std.posix.tcsetattr(port.handle, .NOW, settings);
}

pub fn flush(port: PortImpl, options: serialport.Port.FlushOptions) !void {
    if (!options.input and !options.output) return;

    const TCIFLUSH = 0;
    const TCOFLUSH = 1;
    const TCIOFLUSH = 2;
    const TCFLSH = 0x540B;

    const result = std.os.linux.syscall3(
        .ioctl,
        @bitCast(@as(isize, @intCast(port.handle))),
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

pub fn poll(port: PortImpl) !bool {
    var pollfds: [1]std.os.linux.pollfd = .{
        .{
            .fd = port.handle,
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

pub fn reader(port: PortImpl) Reader {
    return port.reader();
}

pub fn writer(port: PortImpl) Writer {
    return port.writer();
}

pub fn iterate() !IteratorImpl {
    var result: IteratorImpl = .{
        .dir = std.fs.cwd().openDir(
            "/dev/serial/by-id",
            .{ .iterate = true },
        ) catch |e| switch (e) {
            error.FileNotFound => null,
            else => return e,
        },
        .iterator = undefined,
    };
    if (result.dir) |d| {
        result.iterator = d.iterate();
    }
    return result;
}

pub const IteratorImpl = struct {
    dir: ?std.fs.Dir,
    iterator: std.fs.Dir.Iterator,
    name_buffer: [256]u8 = undefined,
    path_buffer: [std.fs.max_path_bytes]u8 = undefined,

    pub fn next(self: *@This()) !?serialport.Iterator.Stub {
        if (self.dir == null) return null;

        var result: serialport.Iterator.Stub = undefined;
        while (try self.iterator.next()) |entry| {
            if (entry.kind != .sym_link) continue;
            @memcpy(self.name_buffer[0..entry.name.len], entry.name);
            result.name = self.name_buffer[0..entry.name.len];
            @memcpy(self.path_buffer[0..18], "/dev/serial/by-id/");
            @memcpy(self.path_buffer[18 .. 18 + entry.name.len], entry.name);
            result.path = try std.fs.realpath(
                self.path_buffer[0 .. entry.name.len + 18],
                &self.path_buffer,
            );
            return result;
        } else {
            return null;
        }
    }

    pub fn deinit(self: *@This()) void {
        if (self.dir) |*d| {
            d.close();
        }
        self.* = undefined;
    }
};

pub const StubImpl = void;

test {
    const c = @cImport({
        @cDefine("_XOPEN_SOURCE", "700");
        @cInclude("stdlib.h");
        @cInclude("fcntl.h");
        @cInclude("unistd.h");
    });

    const master: PortImpl = try open("/dev/ptmx");
    defer close(master);

    if (c.grantpt(master.handle) < 0 or
        c.unlockpt(master.handle) < 0)
        return error.MasterPseudoTerminalSetupError;

    const slave_name = c.ptsname(master.handle) orelse
        return error.SlavePseudoTerminalSetupError;
    const slave_name_len = std.mem.len(slave_name);
    if (slave_name_len == 0)
        return error.SlavePseudoTerminalSetupError;

    try configure(master, .{
        .baud_rate = .B115200,
    });

    const master_writer = writer(master);

    const port: PortImpl = try open(slave_name[0..slave_name_len]);
    defer close(port);

    try configure(port, .{
        .baud_rate = .B115200,
    });

    const reader_ = reader(port);

    try std.testing.expectEqual(false, try poll(port));
    try std.testing.expectEqual(12, try master_writer.write("test message"));
    try std.testing.expectEqual(true, try poll(port));

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(12, try reader_.read(&buffer));
    try std.testing.expectEqualSlices(u8, "test message", buffer[0..12]);
}
