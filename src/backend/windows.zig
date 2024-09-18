const std = @import("std");
const serialport = @import("../serialport.zig");
const windows = std.os.windows;

/// Windows baud rate table, sourced from Microsoft `DCB` documentation in
/// `win32`'s `winbase.h`. Non-exhaustive enum to allow for custom baud rate
/// values.
pub const BaudRate = enum(windows.DWORD) {
    B110 = 110,
    B300 = 300,
    B600 = 600,
    B1200 = 1200,
    B2400 = 2400,
    B9600 = 9600,
    B14400 = 14400,
    B19200 = 19200,
    B38400 = 38400,
    B57600 = 57600,
    B115200 = 115200,
    B128000 = 128000,
    B256000 = 256000,
    _,
};

pub const PortImpl = std.fs.File;

pub const ReadError =
    windows.ReadFileError ||
    windows.OpenError ||
    windows.WaitForSingleObjectError;
pub const Reader = std.io.GenericReader(
    ReadContext,
    ReadError,
    readFn,
);
pub const WriteError =
    windows.WriteFileError ||
    windows.OpenError ||
    windows.WaitForSingleObjectError;
pub const Writer = std.io.GenericWriter(
    WriteContext,
    WriteError,
    writeFn,
);

pub fn open(path: []const u8) !PortImpl {
    const path_w = try windows.sliceToPrefixedFileW(std.fs.cwd().fd, path);
    var result: PortImpl = .{
        .handle = windows.kernel32.CreateFileW(
            path_w.span(),
            windows.GENERIC_READ | windows.GENERIC_WRITE,
            0,
            null,
            windows.OPEN_EXISTING,
            windows.FILE_FLAG_OVERLAPPED,
            null,
        ),
    };
    if (result.handle == windows.INVALID_HANDLE_VALUE) {
        switch (windows.GetLastError()) {
            windows.Win32Error.FILE_NOT_FOUND => {
                return error.FileNotFound;
            },
            else => |e| return windows.unexpectedError(e),
        }
    }
    errdefer result.close();

    if (SetCommMask(result.handle, .{ .RXCHAR = true }) == 0) {
        return windows.unexpectedError(windows.GetLastError());
    }

    return result;
}

pub fn close(port: PortImpl) void {
    port.close();
}

pub fn configure(port: PortImpl, config: serialport.Config) !void {
    var dcb: DCB = std.mem.zeroes(DCB);
    dcb.DCBlength = @sizeOf(DCB);

    if (GetCommState(port.handle, &dcb) == 0)
        return windows.unexpectedError(windows.GetLastError());

    dcb.BaudRate = config.baud_rate;
    dcb.flags = .{
        .Parity = config.parity != .none,
        .OutxCtsFlow = config.handshake == .hardware,
        .OutX = config.handshake == .software,
        .InX = config.handshake == .software,
        .RtsControl = config.handshake == .hardware,
    };
    dcb.ByteSize = 5 + @as(windows.BYTE, @intFromEnum(config.word_size));
    dcb.Parity = @intFromEnum(config.parity);
    dcb.StopBits = if (config.stop_bits == .two) 2 else 0;
    dcb.XonChar = 0x11;
    dcb.XoffChar = 0x13;

    if (SetCommState(port.handle, &dcb) == 0) {
        return windows.unexpectedError(windows.GetLastError());
    }
}

pub fn flush(port: PortImpl, options: serialport.Port.FlushOptions) !void {
    if (!options.input and !options.output) return;
    if (PurgeComm(port.handle, .{
        .PURGE_TXCLEAR = options.output,
        .PURGE_RXCLEAR = options.input,
    }) == 0) {
        return windows.unexpectedError(windows.GetLastError());
    }
}

pub fn poll(port: PortImpl) !bool {
    var events: EventMask = undefined;

    var overlapped: windows.OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{
            .DUMMYSTRUCTNAME = .{
                .Offset = 0,
                .OffsetHigh = 0,
            },
        },
        .hEvent = try windows.CreateEventEx(
            null,
            "",
            windows.CREATE_EVENT_MANUAL_RESET,
            windows.EVENT_ALL_ACCESS,
        ),
    };
    if (WaitCommEvent(port.handle, &events, &overlapped) == 0) {
        switch (windows.GetLastError()) {
            windows.Win32Error.IO_PENDING => return false,
            else => |e| return windows.unexpectedError(e),
        }
    }

    return events.RXCHAR;
}

pub fn reader(port: PortImpl) Reader {
    return .{ .context = port };
}

pub fn writer(port: PortImpl) Writer {
    return .{ .context = port };
}

const ReadContext = std.fs.File;
fn readFn(context: ReadContext, buffer: []u8) ReadError!usize {
    var overlapped: windows.OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{
            .DUMMYSTRUCTNAME = .{
                .Offset = 0,
                .OffsetHigh = 0,
            },
        },
        .hEvent = try windows.CreateEventEx(
            null,
            "",
            windows.CREATE_EVENT_MANUAL_RESET,
            windows.EVENT_ALL_ACCESS,
        ),
    };

    const want_read_count: windows.DWORD = @min(
        @as(windows.DWORD, std.math.maxInt(windows.DWORD)),
        buffer.len,
    );
    var amt_read: windows.DWORD = undefined;
    if (try windows.kernel32.ReadFile(
        context.handle,
        buffer.ptr,
        want_read_count,
        &amt_read,
        &overlapped,
    ) == 0) {
        switch (windows.GetLastError()) {
            windows.Win32Error.IO_PENDING => {
                try windows.WaitForSingleObject(
                    overlapped.hEvent.?,
                    windows.INFINITE,
                );
                const read_amount = try windows.GetOverlappedResult(
                    context.handle,
                    &overlapped,
                    true,
                );
                return read_amount;
            },
            else => |e| return windows.unexpectedError(e),
        }
    }
    return amt_read;
}

const WriteContext = std.fs.File;
fn writeFn(context: WriteContext, bytes: []const u8) WriteError!usize {
    var bytes_written: windows.DWORD = undefined;
    var overlapped: windows.OVERLAPPED = .{
        .Internal = 0,
        .InternalHigh = 0,
        .DUMMYUNIONNAME = .{
            .DUMMYSTRUCTNAME = .{
                .Offset = 0,
                .OffsetHigh = 0,
            },
        },
        .hEvent = try windows.CreateEventEx(
            null,
            "",
            windows.CREATE_EVENT_MANUAL_RESET,
            windows.EVENT_ALL_ACCESS,
        ),
    };
    defer windows.CloseHandle(overlapped.hEvent.?);
    const adjusted_len =
        std.math.cast(u32, bytes.len) orelse std.math.maxInt(u32);

    if (windows.kernel32.WriteFile(
        context.handle,
        bytes.ptr,
        adjusted_len,
        &bytes_written,
        &overlapped,
    ) == 0) {
        switch (windows.GetLastError()) {
            .INVALID_USER_BUFFER => return error.SystemResources,
            .NOT_ENOUGH_MEMORY => return error.SystemResources,
            .OPERATION_ABORTED => return error.OperationAborted,
            .NOT_ENOUGH_QUOTA => return error.SystemResources,
            .IO_PENDING => {
                try windows.WaitForSingleObject(
                    overlapped.hEvent.?,
                    windows.INFINITE,
                );
                const amount_written = try windows.GetOverlappedResult(
                    context.handle,
                    &overlapped,
                    true,
                );
                return amount_written;
            },
            .BROKEN_PIPE => return error.BrokenPipe,
            .INVALID_HANDLE => return error.NotOpenForWriting,
            .LOCK_VIOLATION => return error.LockViolation,
            .NETNAME_DELETED => return error.ConnectionResetByPeer,
            else => |e| return windows.unexpectedError(e),
        }
    }
    return adjusted_len;
}

/// Windows control settings for a serial communications device, sourced from
/// Microsoft `DCB` documentation in `win32`'s `winbase.h`.
const DCB = extern struct {
    DCBlength: windows.DWORD,
    BaudRate: BaudRate,
    flags: Flags,
    Reserved: windows.WORD,
    XonLim: windows.WORD,
    XoffLim: windows.WORD,
    ByteSize: windows.BYTE,
    Parity: windows.BYTE,
    StopBits: windows.BYTE,
    XonChar: u8,
    XoffChar: u8,
    ErrorChar: u8,
    EofChar: u8,
    EvtChar: u8,
    Reserved1: windows.WORD,

    const Flags = packed struct(windows.DWORD) {
        Binary: bool = true,
        Parity: bool = false,
        OutxCtsFlow: bool = false,
        OutxDsrFlow: bool = false,
        DtrControl: u2 = 1,
        DsrSensitivity: bool = false,
        TXContinueOnXoff: bool = false,
        OutX: bool = false,
        InX: bool = false,
        ErrorChar: bool = false,
        Null: bool = false,
        RtsControl: bool = false,
        _unused: u1 = 0,
        AbortOnError: bool = false,
        _: u17 = 0,
    };
};

extern "kernel32" fn SetCommState(
    hFile: windows.HANDLE,
    lpDCB: *DCB,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn GetCommState(
    hFile: windows.HANDLE,
    lpDCB: *DCB,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn SetCommMask(
    hFile: windows.HANDLE,
    dwEvtMask: EventMask,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn WaitCommEvent(
    hFile: windows.HANDLE,
    lpEvtMask: *EventMask,
    lpOverlapped: ?*windows.OVERLAPPED,
) callconv(windows.WINAPI) windows.BOOL;

extern "kernel32" fn PurgeComm(
    hFile: windows.HANDLE,
    dwFlags: packed struct(windows.DWORD) {
        PURGE_TXABORT: bool = false,
        PURGE_RXABORT: bool = false,
        PURGE_TXCLEAR: bool = false,
        PURGE_RXCLEAR: bool = false,
        _: u28 = 0,
    },
) callconv(windows.WINAPI) windows.BOOL;

const EventMask = packed struct(windows.DWORD) {
    RXCHAR: bool = false,
    RXFLAG: bool = false,
    TXEMPTY: bool = false,
    CTS: bool = false,
    DSR: bool = false,
    RLSD: bool = false,
    BREAK: bool = false,
    ERR: bool = false,
    RING: bool = false,
    _: u23 = 0,
};
