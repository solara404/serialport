const builtin = @import("builtin");
const std = @import("std");

const serialport = @This();

pub fn iterate() !Iterator {
    return .{
        ._impl = try backend.iterate(),
    };
}

pub fn open(file_path: []const u8) !Port {
    return .{ ._impl = try backend.open(file_path) };
}

pub const Port = struct {
    _impl: backend.PortImpl,

    pub const Reader = backend.Reader;
    pub const ReadError = backend.ReadError;
    pub const Writer = backend.Writer;
    pub const WriteError = backend.WriteError;

    pub const FlushOptions = struct {
        input: bool = false,
        output: bool = false,
    };

    pub fn close(self: *@This()) void {
        const fnti = @typeInfo(@TypeOf(backend.close)).@"fn";
        const param_type = @typeInfo(fnti.params[0].type.?);
        switch (comptime param_type) {
            .pointer => backend.close(&self._impl),
            .@"struct" => backend.close(self._impl),
            else => @compileError("invalid function signature"),
        }
    }

    pub fn configure(self: *@This(), config: Config) !void {
        const fnti = @typeInfo(@TypeOf(backend.configure)).@"fn";
        const param_type = @typeInfo(fnti.params[0].type.?);
        return switch (comptime param_type) {
            .pointer => backend.configure(&self._impl, config),
            .@"struct" => backend.configure(self._impl, config),
            else => @compileError("invalid function signature"),
        };
    }

    pub fn flush(self: *@This(), options: FlushOptions) !void {
        const fnti = @typeInfo(@TypeOf(backend.flush)).@"fn";
        const param_type = @typeInfo(fnti.params[0].type.?);
        return switch (comptime param_type) {
            .pointer => backend.flush(&self._impl, options),
            .@"struct" => backend.flush(self._impl, options),
            else => @compileError("invalid function signature"),
        };
    }

    pub fn poll(self: *@This()) !bool {
        const fnti = @typeInfo(@TypeOf(backend.poll)).@"fn";
        const param_type = @typeInfo(fnti.params[0].type.?);
        return switch (comptime param_type) {
            .pointer => backend.poll(&self._impl),
            .@"struct" => backend.poll(self._impl),
            else => @compileError("invalid function signature"),
        };
    }

    pub fn reader(self: *@This()) Reader {
        const fnti = @typeInfo(@TypeOf(backend.reader)).@"fn";
        const param_type = @typeInfo(fnti.params[0].type.?);
        return switch (comptime param_type) {
            .pointer => backend.reader(&self._impl),
            .@"struct" => backend.reader(self._impl),
            else => @compileError("invalid function signature"),
        };
    }

    pub fn writer(self: *@This()) Writer {
        const fnti = @typeInfo(@TypeOf(backend.writer)).@"fn";
        const param_type = @typeInfo(fnti.params[0].type.?);
        return switch (comptime param_type) {
            .pointer => backend.writer(&self._impl),
            .@"struct" => backend.writer(self._impl),
            else => @compileError("invalid function signature"),
        };
    }
};

pub const Config = struct {
    baud_rate: BaudRate,
    parity: Parity = .none,
    stop_bits: StopBits = .one,
    word_size: WordSize = .eight,
    handshake: Handshake = .none,

    pub const BaudRate = if (@hasDecl(backend, "BaudRate"))
        backend.BaudRate
    else if (@TypeOf(std.posix.speed_t) != void)
        std.posix.speed_t
    else
        @compileError("unsupported backend/OS");

    pub const Parity = enum(u3) {
        /// No parity bit is used.
        none,
        /// Parity bit is `0` when an odd number of bits is set in the data.
        odd,
        /// Parity bit is `0` when an even number of bits is set in the data.
        even,
        /// Parity bit is always `1`.
        mark,
        /// Parity bit is always `0`.
        space,
    };

    pub const StopBits = enum(u1) {
        /// Length of stop bits is one bit.
        one,
        /// Length of stop bits is two bits.
        two,
    };

    pub const WordSize = enum(u2) {
        /// There are five data bits per word.
        five,
        /// There are six data bits per word.
        six,
        /// There are seven data bits per word.
        seven,
        /// There are eight data bits per word.
        eight,
    };

    pub const Handshake = enum(u2) {
        /// No handshake is used.
        none,
        /// XON-XOFF software handshake is used.
        software,
        /// Hardware handshake with RTS (RFR) / CTS is used.
        hardware,
    };
};

pub const Iterator = struct {
    _impl: backend.IteratorImpl,

    /// Serial port stub that contains minimal information necessary to
    /// identify and open a serial port. Stubs may be dependent on its source
    /// iterator, and are not guaranteed to stay valid after iterator state
    /// is changed.
    pub const Stub = struct {
        name: []const u8,
        path: []const u8,

        pub fn open(self: @This()) !Port {
            return serialport.open(self.path);
        }
    };

    pub fn next(self: *@This()) !?Stub {
        return self._impl.next();
    }

    pub fn deinit(self: *@This()) void {
        self._impl.deinit();
    }
};

const backend = switch (builtin.os.tag) {
    .windows => @import("backend/windows.zig"),
    .macos => @import("backend/macos.zig"),
    .linux => @import("backend/linux.zig"),
    else => @compileError("unsupported OS"),
};

test {
    std.testing.refAllDeclsRecursive(@This());
}
