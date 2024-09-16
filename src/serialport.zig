const builtin = @import("builtin");
const std = @import("std");

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

pub const Port = backend.Port;

pub const ManagedPort = struct {
    allocator: std.mem.Allocator,
    port: Port,

    pub const Reader = Port.Reader;
    pub const ReadError = Port.ReadError;
    pub const Writer = Port.Writer;
    pub const WriteError = Port.WriteError;

    pub const FlushOptions = struct {
        input: bool = false,
        output: bool = false,
    };

    pub fn open(self: *@This()) !void {
        return self.port.open();
    }

    pub fn close(self: *@This()) void {
        self.port.close();
    }

    pub fn configure(self: @This(), config: Config) !void {
        return self.port.configure(config);
    }

    pub fn flush(self: @This(), options: FlushOptions) !void {
        return self.port.flush(options);
    }

    pub fn poll(self: @This()) !bool {
        return self.port.poll();
    }

    pub fn reader(self: @This()) ?Reader {
        return self.port.reader();
    }

    pub fn writer(self: @This()) ?Writer {
        return self.port.writer();
    }

    pub fn deinit(self: *@This()) void {
        self.port.deinit(self.allocator);
        self.* = undefined;
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
