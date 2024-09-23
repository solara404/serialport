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

    const close_ptr = switch (@typeInfo(
        @typeInfo(@TypeOf(backend.close)).@"fn".params[0].type.?,
    )) {
        .pointer => true,
        .@"struct" => false,
        else => @compileError("invalid function signature"),
    };
    pub fn close(self: *@This()) void {
        backend.close(if (comptime close_ptr) &self._impl else self._impl);
        self.* = undefined;
    }

    const configure_ptr = switch (@typeInfo(
        @typeInfo(@TypeOf(backend.configure)).@"fn".params[0].type.?,
    )) {
        .pointer => true,
        .@"struct" => false,
        else => @compileError("invalid function signature"),
    };
    pub fn configure(
        self: if (configure_ptr) *@This() else @This(),
        config: Config,
    ) !void {
        return backend.configure(
            if (comptime configure_ptr) &self._impl else self._impl,
            config,
        );
    }

    const flush_ptr = switch (@typeInfo(
        @typeInfo(@TypeOf(backend.flush)).@"fn".params[0].type.?,
    )) {
        .pointer => true,
        .@"struct" => false,
        else => @compileError("invalid function signature"),
    };
    pub fn flush(
        self: if (flush_ptr) *@This() else @This(),
        options: FlushOptions,
    ) !void {
        return backend.flush(
            if (comptime flush_ptr) &self._impl else self._impl,
            options,
        );
    }

    const poll_ptr = switch (@typeInfo(
        @typeInfo(@TypeOf(backend.poll)).@"fn".params[0].type.?,
    )) {
        .pointer => true,
        .@"struct" => false,
        else => @compileError("invalid function signature"),
    };
    pub fn poll(self: if (poll_ptr) *@This() else @This()) !bool {
        return backend.poll(
            if (comptime poll_ptr) &self._impl else self._impl,
        );
    }

    const reader_ptr = switch (@typeInfo(
        @typeInfo(@TypeOf(backend.reader)).@"fn".params[0].type.?,
    )) {
        .pointer => true,
        .@"struct" => false,
        else => @compileError("invalid function signature"),
    };
    pub fn reader(self: if (reader_ptr) *@This() else @This()) Reader {
        return backend.reader(
            if (comptime reader_ptr) &self._impl else self._impl,
        );
    }

    const writer_ptr = switch (@typeInfo(
        @typeInfo(@TypeOf(backend.writer)).@"fn".params[0].type.?,
    )) {
        .pointer => true,
        .@"struct" => false,
        else => @compileError("invalid function signature"),
    };
    pub fn writer(self: if (writer_ptr) *@This() else @This()) Writer {
        return backend.writer(
            if (comptime writer_ptr) &self._impl else self._impl,
        );
    }
};

pub const Config = struct {
    /// Baud rate. Used as both output and input baud rate, unless an input
    /// baud is separately provided.
    baud_rate: BaudRate,
    /// Input-specific baud rate. Use only when a custom input baud rate
    /// different than the output baud rate must be specified.
    input_baud_rate: ?BaudRate = null,
    /// Per-character parity bit use. Data bits must be less than eight to use
    /// parity bit (eighth bit is used as parity bit).
    parity: Parity = .none,
    /// Number of bits used to signal end of character. Appended after all data
    /// and parity bits.
    stop_bits: StopBits = .one,
    /// Number of data bits to use per character.
    data_bits: DataBits = .eight,
    flow_control: FlowControl = .none,

    pub const BaudRate = if (@hasDecl(backend, "BaudRate"))
        backend.BaudRate
    else if (@TypeOf(std.posix.speed_t) != void)
        std.posix.speed_t
    else
        @compileError("unsupported backend/OS");

    pub const Parity = enum(u3) {
        /// Do not create or check for parity bit per character.
        none,
        /// Parity bit set to `0` when data has odd number of `1` bits.
        odd,
        /// Parity bit set to `0` when data has even number of `1` bits.
        even,
        /// Parity bit always set to `1`.
        mark,
        /// Parity bit always set to `0`. A.k.a. bit filling.
        space,
    };

    pub const StopBits = enum(u1) {
        /// One bit to signal end of character.
        one,
        /// Two bits to signal end of character.
        two,
    };

    pub const DataBits = enum(u2) {
        /// Five data bits per character.
        five,
        /// Six data bits per character.
        six,
        /// Seven data bits per character.
        seven,
        /// Eight data bits per character.
        eight,
    };

    pub const FlowControl = enum(u2) {
        /// No flow control is used.
        none,
        /// XON-XOFF software flow control is used.
        software,
        /// Hardware flow control with RTS (RFR) / CTS is used. A.k.a. hardware
        /// handshaking, pacing.
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
