//! Allocation-free terminal development log with ANSI colors.
//!
//! A `Sink` renders records into a fixed stack buffer using comptime format
//! strings, then flushes whole batches with one bounded file operation. The
//! transport reaches the owning thread's sink through `thread_sink`, so
//! event-loop callbacks never allocate and never issue more than one write per
//! full batch. HTTP requests render Vite-style as
//! `HH:MM:SS | [METHOD] /path : STATUS` with a dim clock, cyan method, and
//! status-class color. Recording is opt-in: a sink is silent until `enable`
//! binds an output file, which keeps library defaults quiet.

const std = @import("std");
const metrics = @import("metrics.zig");

/// ANSI SGR sequences used by the renderer.
pub const Ansi = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
};

/// Severity of one development-log line.
pub const Level = enum { debug, info, warn, err };

/// Explicit traffic direction carried by every record.
pub const Direction = enum { data_in, data_out };

/// One accepted or released connection.
pub const ConnectionEvent = struct {
    index: usize,
};

/// One completed HTTP request/response cycle.
pub const RequestEvent = struct {
    method: []const u8,
    path: []const u8,
    status: u16,
};

/// One complete WebSocket application message.
pub const MessageEvent = struct {
    payload_len: usize,
    is_text: bool,
};

/// One registry counter rendered with its comptime metric name.
pub const MetricEvent = struct {
    slot: metrics.Slot,
    value: u64,
};

/// Named payload for one development-log record.
pub const Event = union(enum) {
    connection_opened: ConnectionEvent,
    connection_closed: ConnectionEvent,
    http_request: RequestEvent,
    ws_message: MessageEvent,
    metric: MetricEvent,
};

/// One development-log line: wall clock, severity, direction, and payload.
pub const Record = struct {
    timestamp_ms: i64,
    level: Level,
    direction: Direction,
    event: Event,
};

/// Fixed batch capacity; a full buffer flushes before the next line.
pub const capacity = 4096;
/// Flush watermark: a non-empty batch drains below this free space.
pub const max_line_bytes = 256;

/// Exact startup wordmark written once when the development log is enabled.
pub const banner =
    \\██╗  ██╗ ██╗    ██╗███████╗██████╗ ███████╗ ██████╗  ██████╗██╗  ██╗███████╗████████╗███████╗
    \\██║  ██║ ██║    ██║██╔════╝██╔══██╗╚══███╔╝██╔═══██╗██╔════╝██║ ██╔╝██╔════╝╚══██╔══╝██╔════╝
    \\██║  ██║ ██║ █╗ ██║█████╗  ██████╔╝  ███╔╝ ██║   ██║██║     █████╔╝ █████╗     ██║   ███████╗
    \\██║  ██║ ██║███╗██║██╔══╝  ██╔══██╗ ███╔╝  ██║   ██║██║     ██╔═██╗ ██╔══╝     ██║   ╚════██║
    \\╚██████╔╝ ╚███╔███╔╝███████╗██████╔╝███████╗╚██████╔╝╚██████╗██║  ██╗███████╗   ██║   ███████║
    \\██╔════╝   ╚══╝╚══╝ ╚══════╝╚═════╝ ╚══════╝ ╚═════╝  ╚═════╝╚═╝  ╚═╝╚══════╝   ╚═╝   ╚══════╝
    \\██║                                                                                       
    \\╚═╝
;

/// Result of one best-effort terminal write.
pub const FlushOutcome = struct {
    written: usize = 0,
    failed: bool = false,
};

const slot_fields = @typeInfo(metrics.Slot).@"enum".fields;

/// Thread-confined batched terminal sink.
pub const Sink = struct {
    buffer: [capacity]u8 = undefined,
    len: usize = 0,
    io: std.Io = undefined,
    file: std.Io.File = undefined,
    enabled: bool = false,
    dropped: u64 = 0,
    written: u64 = 0,

    /// Binds the sink to an output file and starts accepting records.
    pub fn enable(self: *Sink, io: std.Io, file: std.Io.File) void {
        self.io = io;
        self.file = file;
        self.enabled = true;
    }

    /// Appends the startup wordmark exactly, on its own line.
    pub fn record_banner(self: *Sink) void {
        if (!self.enabled) return;
        if (self.buffer.len - self.len < banner.len + 1) _ = self.flush();
        if (self.buffer.len - self.len < banner.len + 1) {
            self.dropped +|= 1;
            return;
        }
        @memcpy(self.buffer[self.len..][0..banner.len], banner);
        self.len += banner.len;
        self.buffer[self.len] = '\n';
        self.len += 1;
    }

    /// Appends one entry, flushing the batch first when the line cannot fit.
    pub fn record(self: *Sink, entry: Record) void {
        if (!self.enabled) return;
        if (self.append(entry)) return;
        _ = self.flush();
        if (self.append(entry)) return;
        self.dropped +|= 1;
    }

    /// Writes the whole batch with one bounded file operation.
    ///
    /// A short or failed write drops the pending bytes instead of retrying, so
    /// a stalled terminal can never block or spin the event loop.
    pub fn flush(self: *Sink) FlushOutcome {
        if (!self.enabled or self.len == 0) return .{};
        const pending = self.buffer[0..self.len];
        self.len = 0;
        const written = self.file.writeStreaming(self.io, &.{}, &.{pending}, 1) catch {
            // Development diagnostics are best effort; the server keeps
            // running when the terminal disappears.
            self.dropped +|= 1;
            return .{ .failed = true };
        };
        self.written +|= written;
        if (written < pending.len) {
            self.dropped +|= 1;
            return .{ .written = written, .failed = true };
        }
        return .{ .written = written };
    }

    /// Renders every registry counter in declaration order.
    pub fn record_metrics(
        self: *Sink,
        timestamp_ms: i64,
        direction: Direction,
        registry: *const metrics.Registry,
    ) void {
        inline for (slot_fields) |field| {
            const slot: metrics.Slot = @enumFromInt(field.value);
            self.record(.{
                .timestamp_ms = timestamp_ms,
                .level = .info,
                .direction = direction,
                .event = .{ .metric = .{ .slot = slot, .value = registry.get(slot) } },
            });
        }
    }

    fn append(self: *Sink, entry: Record) bool {
        if (self.buffer.len - self.len < max_line_bytes and self.len != 0) return false;
        const line = render(self.buffer[self.len..], entry) catch return false;
        self.len += line.len;
        return true;
    }
};

/// Thread-owned sink shared by the transport callbacks of one event loop.
///
/// Every worker thread owns exactly one instance, so recording and flushing
/// need no lock or atomic: the buffer is never shared across threads. This is
/// the module's only file-scope variable, and it exists so transport
/// callbacks can reach a batch without threading a logger pointer through
/// every call.
threadlocal var thread_sink_storage: Sink = .{};

/// Returns this thread's sink; silent until `Sink.enable` binds an output.
pub fn thread_sink() *Sink {
    return &thread_sink_storage;
}

/// Reads the wall clock in milliseconds; rendering itself stays pure.
pub fn now_ms(io: std.Io) i64 {
    return @intCast(@divTrunc(std.Io.Clock.now(.real, io).nanoseconds, std.time.ns_per_ms));
}

/// Renders one record into `buffer` without I/O or allocation.
pub fn render(buffer: []u8, record: Record) error{NoSpaceLeft}![]const u8 {
    var writer: std.Io.Writer = .fixed(buffer);
    write_record(&writer, record) catch return error.NoSpaceLeft;
    return writer.buffered();
}

fn write_record(writer: *std.Io.Writer, record: Record) std.Io.Writer.Error!void {
    switch (record.event) {
        .http_request => |event| try write_http_line(writer, record.timestamp_ms, event),
        .connection_opened => |event| {
            try write_prefix(writer, record);
            try writer.print("{s}{s:<6}{s} #{d} accepted", .{
                Ansi.magenta, "conn", Ansi.reset, event.index,
            });
        },
        .connection_closed => |event| {
            try write_prefix(writer, record);
            try writer.print("{s}{s:<6}{s} #{d} closed", .{
                Ansi.magenta, "conn", Ansi.reset, event.index,
            });
        },
        .ws_message => |event| {
            try write_prefix(writer, record);
            try writer.print("{s}{s:<6}{s} {s}{s} {s}{d}B", .{
                Ansi.yellow,
                "ws",
                Ansi.reset,
                if (event.is_text) "text" else "binary",
                Ansi.reset,
                Ansi.dim,
                event.payload_len,
            });
        },
        .metric => |event| {
            try write_prefix(writer, record);
            try write_metric(writer, record.direction, event);
        },
    }
    try writer.writeAll(Ansi.reset);
    try writer.writeByte('\n');
}

fn write_prefix(writer: *std.Io.Writer, record: Record) std.Io.Writer.Error!void {
    try write_clock(writer, record.timestamp_ms, record.level);
    try writer.writeByte(' ');
    try writer.writeAll(direction_badge(record.direction));
    try writer.writeByte(' ');
}

/// Writes one Vite-style request line: `HH:MM:SS | [METHOD] /path : STATUS`.
fn write_http_line(
    writer: *std.Io.Writer,
    timestamp_ms: i64,
    event: RequestEvent,
) std.Io.Writer.Error!void {
    try write_clock_short(writer, timestamp_ms);
    try writer.print(" | {s}[{s}]{s} {s} : {s}{d}{s}", .{
        Ansi.cyan,
        event.method,
        Ansi.reset,
        event.path,
        status_color(event.status),
        event.status,
        Ansi.reset,
    });
}

/// Wall-clock fields derived from an epoch-millisecond timestamp.
const ClockParts = struct {
    hours: u64,
    minutes: u64,
    seconds: u64,
    millis: u64,
};

fn clock_parts(timestamp_ms: i64) ClockParts {
    const day_ms = @mod(timestamp_ms, std.time.ms_per_day);
    return .{
        .hours = @intCast(@divTrunc(day_ms, std.time.ms_per_hour)),
        .minutes = @intCast(@divTrunc(@mod(day_ms, std.time.ms_per_hour), std.time.ms_per_min)),
        .seconds = @intCast(@divTrunc(@mod(day_ms, std.time.ms_per_min), std.time.ms_per_s)),
        .millis = @intCast(@mod(day_ms, std.time.ms_per_s)),
    };
}

fn write_clock(writer: *std.Io.Writer, timestamp_ms: i64, level: Level) std.Io.Writer.Error!void {
    const parts = clock_parts(timestamp_ms);
    try writer.print("{s}{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}{s}", .{
        level_color(level),
        parts.hours,
        parts.minutes,
        parts.seconds,
        parts.millis,
        Ansi.reset,
    });
}

fn write_clock_short(writer: *std.Io.Writer, timestamp_ms: i64) std.Io.Writer.Error!void {
    const parts = clock_parts(timestamp_ms);
    try writer.print("{s}{d:0>2}:{d:0>2}:{d:0>2}{s}", .{
        Ansi.dim,
        parts.hours,
        parts.minutes,
        parts.seconds,
        Ansi.reset,
    });
}

fn write_metric(
    writer: *std.Io.Writer,
    direction: Direction,
    event: MetricEvent,
) std.Io.Writer.Error!void {
    const value_color = switch (direction) {
        .data_in => Ansi.green,
        .data_out => Ansi.blue,
    };
    inline for (slot_fields) |field| {
        const slot: metrics.Slot = @enumFromInt(field.value);
        if (event.slot == slot) {
            try writer.print("{s}{s:<6}{s} {s}{s}{s} {d}", .{
                Ansi.magenta,
                "metric",
                Ansi.reset,
                value_color,
                metrics.metric_name(slot),
                Ansi.reset,
                event.value,
            });
        }
    }
}

fn direction_badge(direction: Direction) []const u8 {
    return switch (direction) {
        .data_in => std.fmt.comptimePrint("{s}{s}{s:<3}{s}", .{
            Ansi.bold, Ansi.green, "IN", Ansi.reset,
        }),
        .data_out => std.fmt.comptimePrint("{s}{s}{s:<3}{s}", .{
            Ansi.bold, Ansi.blue, "OUT", Ansi.reset,
        }),
    };
}

fn level_color(level: Level) []const u8 {
    return switch (level) {
        .debug, .info => Ansi.dim,
        .warn => Ansi.yellow,
        .err => Ansi.red,
    };
}

fn status_color(status: u16) []const u8 {
    return switch (status / 100) {
        2 => Ansi.green,
        3 => Ansi.cyan,
        4 => Ansi.yellow,
        5 => Ansi.red,
        else => Ansi.reset,
    };
}
