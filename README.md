# serialport

![Linux Port Iteration Result](assets/Linux_Iteration_Demo.png)

## Todo

- [ ] Refactor backends to expose public API best suited for OS, then use these
      APIs in platform-agnostic API implementation
- [ ] Offer both blocking and non-blocking reads/writes
- [ ] Port descriptions and information
- [ ] Export C library
- [ ] Async port interface (dependent on re-introduction of Zig async)

## Examples

### Port Iteration

```zig
// ...
var it = try serialport.iterate();
defer it.deinit();

while (try it.next()) |stub| {
  // Stub name used only to identify port, not to open it.
  std.log.info("Found COM port {s}", .{stub.name});

  std.log.info("Port file path: {s}", .{stub.path});
}
// ...
```

### Polling Reads

```zig
// ...
var port = try serialport.open(my_port_path);
defer port.close();

try port.configure(.{
  .baud_rate = .B115200,
});

const reader = port.reader();

var read_buffer: [128]u8 = undefined;
const timeout = 1_000 * std.time.ns_per_ms;

var timer = try std.time.Timer.start();
// Keep polling and reading until no bytes arrive for 1000ms.
while (timer.read() < timeout) {
  if (try port.poll()) {
    const read_size = try reader.read(&read_buffer);
    std.log.info("Port bytes arrived: {any}", .{read_buffer[0..read_size]});
    timer.reset();
  }
}
// ...
```
