const std = @import("std");
const serialport = @import("../serialport.zig");
const c = @cImport({
    @cInclude("termios.h");
});

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
        settings.cflag.CCTS_OFLOW = true;
        settings.cflag.CRTS_IFLOW = true;
    }

    settings.cflag.PARENB = config.parity != .none;
    switch (config.parity) {
        .none, .even => {},
        .odd => settings.cflag.PARODD = true,
        .mark => {
            return error.ParityMarkSpaceUnsupported;
        },
        .space => {
            return error.ParityMarkSpaceUnsupported;
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
    const result = c.tcflush(
        port.handle,
        if (options.input and options.output)
            c.TCIOFLUSH
        else if (options.input)
            c.TCIFLUSH
        else
            c.TCOFLUSH,
    );
    return switch (std.posix.errno(result)) {
        .SUCCESS => {},
        .BADF => error.FileNotFound,
        .NOTTY => error.FileNotTty,
        else => unreachable,
    };
}

pub fn poll(port: PortImpl) !bool {
    var pollfds: [1]std.posix.pollfd = .{
        .{
            .fd = port.handle,
            .events = std.posix.POLL.IN,
            .revents = undefined,
        },
    };
    if (try std.posix.poll(&pollfds, 0) == 0) return false;
    if (pollfds[0].revents & std.posix.POLL.IN == 0) return false;

    const err_mask = std.posix.POLL.ERR | std.posix.POLL.NVAL |
        std.posix.POLL.HUP;
    if (pollfds[0].revents & err_mask != 0) return false;
    return true;
}

pub fn reader(port: PortImpl) Reader {
    return port.reader();
}

pub fn writer(port: PortImpl) Writer {
    return port.writer();
}

pub const StubImpl = void;

pub fn iterate() !IteratorImpl {
    @compileError("unimplemented");
}

pub const IteratorImpl = struct {
    pub fn next(_: *@This()) !?serialport.Iterator.Stub {
        @compileError("unimplemented");
    }

    pub fn deinit(_: *@This()) void {
        @compileError("unimplemented");
    }
};
