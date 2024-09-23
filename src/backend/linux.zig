const builtin = @import("builtin");
const std = @import("std");
const serialport = @import("../serialport.zig");
const linux = std.os.linux;

pub const BaudRate = b: {
    const ti = @typeInfo(std.os.linux.speed_t).@"enum";
    const baud_rate_ti: std.builtin.Type.Enum = .{
        .tag_type = ti.tag_type,
        .fields = ti.fields,
        .decls = &.{},
        .is_exhaustive = false,
    };
    break :b @Type(std.builtin.Type{ .@"enum" = baud_rate_ti });
};

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

fn configureParity(
    termios: *std.os.linux.termios,
    parity: serialport.Config.Parity,
) void {
    termios.cflag.PARENB = parity != .none;
    termios.cflag.PARODD = parity == .odd or parity == .mark;
    termios.cflag.CMSPAR = parity == .mark or parity == .space;

    termios.iflag.INPCK = parity != .none;
    termios.iflag.IGNPAR = parity == .none;
}

fn configureFlowControl(
    termios: *std.os.linux.termios,
    flow_control: serialport.Config.FlowControl,
) void {
    termios.cflag.CLOCAL = flow_control == .none;
    termios.cflag.CRTSCTS = flow_control == .hardware;

    termios.iflag.IXANY = flow_control == .software;
    termios.iflag.IXON = flow_control == .software;
    termios.iflag.IXOFF = flow_control == .software;
}

pub fn configure(port: PortImpl, config: serialport.Config) !void {
    const CBAUD: u32 = switch (comptime builtin.target.cpu.arch) {
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => 0x000000FF,
        else => 0x0000100F,
    };
    const CIBAUD: u32 = switch (comptime builtin.target.cpu.arch) {
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => 0x00FF0000,
        else => 0x100F0000,
    };
    const BOTHER = switch (comptime builtin.target.cpu.arch) {
        .powerpc, .powerpcle, .powerpc64, .powerpc64le => 0x0000001F,
        else => 0x00001000,
    };
    const IBSHIFT = 16;

    const custom_output_baud: bool = std.enums.tagName(
        serialport.Config.BaudRate,
        config.baud_rate,
    ) == null;
    const custom_input_baud: bool = if (config.input_baud_rate) |ibr|
        std.enums.tagName(serialport.Config.BaudRate, ibr) == null
    else
        custom_output_baud;

    var settings = try std.posix.tcgetattr(port.handle);

    // `cfmakeraw`
    settings.iflag.IGNBRK = false;
    settings.iflag.BRKINT = false;
    settings.iflag.PARMRK = false;
    settings.iflag.ISTRIP = false;
    settings.iflag.INLCR = false;
    settings.iflag.IGNCR = false;
    settings.iflag.ICRNL = false;
    settings.iflag.IXON = false;

    settings.oflag.OPOST = false;

    settings.lflag.ECHO = false;
    settings.lflag.ECHONL = false;
    settings.lflag.ICANON = false;
    settings.lflag.ISIG = false;
    settings.lflag.IEXTEN = false;

    var cflag: u32 = @bitCast(settings.cflag);

    // Set CBAUD and CIBAUD in cflag.
    const baud_bits: u32 = @bitCast(@intFromEnum(config.baud_rate));
    cflag &= ~CBAUD;
    cflag &= ~CIBAUD;
    cflag |= if (custom_output_baud) BOTHER else baud_bits;
    if (config.input_baud_rate) |ibr| {
        const input_baud_bits: u32 = @bitCast(@intFromEnum(ibr));
        cflag |=
            (if (custom_input_baud) input_baud_bits else BOTHER) << IBSHIFT;
    }

    settings.cflag = @bitCast(cflag);
    settings.cflag.CREAD = true;
    settings.cflag.CSTOPB = config.stop_bits == .two;
    settings.cflag.CSIZE = @enumFromInt(@intFromEnum(config.data_bits));

    configureParity(&settings, config.parity);
    configureFlowControl(&settings, config.flow_control);

    const ispeed: *serialport.Config.BaudRate = @ptrCast(&settings.ispeed);
    ispeed.* = if (config.input_baud_rate) |ibr| ibr else config.baud_rate;
    const ospeed: *serialport.Config.BaudRate = @ptrCast(&settings.ospeed);
    ospeed.* = config.baud_rate;

    // Minimum arrived bytes before read returns.
    settings.cc[@intFromEnum(linux.V.MIN)] = 0;
    // Inter-byte timeout before read returns.
    settings.cc[@intFromEnum(linux.V.TIME)] = 0;
    settings.cc[@intFromEnum(linux.V.START)] = 0x11;
    settings.cc[@intFromEnum(linux.V.STOP)] = 0x13;

    try std.posix.tcsetattr(port.handle, .NOW, settings);
}

pub fn flush(port: PortImpl, options: serialport.Port.FlushOptions) !void {
    if (!options.input and !options.output) return;

    const TCIFLUSH = 0;
    const TCOFLUSH = 1;
    const TCIOFLUSH = 2;
    const TCFLSH = 0x540B;

    const result = linux.syscall3(
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
    var pollfds: [1]linux.pollfd = .{
        .{
            .fd = port.handle,
            .events = linux.POLL.IN,
            .revents = undefined,
        },
    };
    if (linux.poll(&pollfds, 1, 0) == 0) return false;

    if (pollfds[0].revents & linux.POLL.IN == 0) return false;

    const err_mask = linux.POLL.ERR | linux.POLL.NVAL | linux.POLL.HUP;
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

fn openVirtualPorts(master_port: *PortImpl, slave_port: *PortImpl) !void {
    const c = @cImport({
        @cDefine("_XOPEN_SOURCE", "700");
        @cInclude("stdlib.h");
        @cInclude("fcntl.h");
        @cInclude("unistd.h");
    });

    master_port.* = try open("/dev/ptmx");
    errdefer close(master_port.*);

    if (c.grantpt(master_port.handle) < 0 or
        c.unlockpt(master_port.handle) < 0)
        return error.MasterPseudoTerminalSetupError;

    const slave_name = c.ptsname(master_port.handle) orelse
        return error.SlavePseudoTerminalSetupError;
    const slave_name_len = std.mem.len(slave_name);
    if (slave_name_len == 0)
        return error.SlavePseudoTerminalSetupError;

    slave_port.* = try open(slave_name[0..slave_name_len]);
}

test {
    var master: PortImpl = undefined;
    var slave: PortImpl = undefined;
    try openVirtualPorts(&master, &slave);
    defer close(master);
    defer close(slave);

    const config: serialport.Config = .{
        .baud_rate = .B230400,
        .flow_control = .software,
    };

    try configure(master, config);
    try configure(slave, config);

    const writer_m = writer(master);
    const reader_s = reader(slave);

    try std.testing.expectEqual(false, try poll(slave));
    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(12, try reader_s.read(&buffer));
    try std.testing.expectEqualSlices(u8, "test message", buffer[0..12]);
    try std.testing.expectEqual(false, try poll(slave));

    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));

    var small_buffer: [8]u8 = undefined;
    try std.testing.expectEqual(8, try reader_s.read(&small_buffer));
    try std.testing.expectEqualSlices(u8, "test mes", &small_buffer);
    try std.testing.expectEqual(true, try poll(slave));
    try std.testing.expectEqual(4, try reader_s.read(&small_buffer));
    try std.testing.expectEqualSlices(u8, "sage", small_buffer[0..4]);
    try std.testing.expectEqual(false, try poll(slave));

    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));
    try flush(slave, .{ .input = true });
    try std.testing.expectEqual(false, try poll(slave));
}

test {
    var master: PortImpl = undefined;
    var slave: PortImpl = undefined;
    try openVirtualPorts(&master, &slave);
    defer close(master);
    defer close(slave);

    const config: serialport.Config = .{ .baud_rate = .B115200 };
    try configure(master, config);
    try configure(slave, config);

    const writer_m = writer(master);
    const reader_s = reader(slave);

    try std.testing.expectEqual(false, try poll(slave));
    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));

    var buffer: [16]u8 = undefined;
    try std.testing.expectEqual(12, try reader_s.read(&buffer));
    try std.testing.expectEqualSlices(u8, "test message", buffer[0..12]);
    try std.testing.expectEqual(false, try poll(slave));

    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));

    var small_buffer: [8]u8 = undefined;
    try std.testing.expectEqual(8, try reader_s.read(&small_buffer));
    try std.testing.expectEqualSlices(u8, "test mes", &small_buffer);
    try std.testing.expectEqual(true, try poll(slave));
    try std.testing.expectEqual(4, try reader_s.read(&small_buffer));
    try std.testing.expectEqualSlices(u8, "sage", small_buffer[0..4]);
    try std.testing.expectEqual(false, try poll(slave));

    try std.testing.expectEqual(12, try writer_m.write("test message"));
    try std.testing.expectEqual(true, try poll(slave));
    try flush(slave, .{ .input = true });
    try std.testing.expectEqual(false, try poll(slave));
}
