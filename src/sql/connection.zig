//! Persistent PostgreSQL socket with inline completions and startup-owned slabs.
const std = @import("std");
const builtin = @import("builtin");
const c = @import("c");
const xev = @import("xev");
const loop_module = @import("../core/loop.zig");
const tcp = @import("../core/tcp.zig");
const scheduler_module = @import("../core/timer.zig");
const wheel = @import("../core/timer_wheel.zig");
const tls = @import("../crypto/tls_client.zig");
const wire = @import("pg_wire.zig");
const auth = @import("pg_auth.zig");
const rows = @import("rows.zig");
const types = @import("types.zig");
const runtime = @import("runtime_types.zig");
const log = std.log.scoped(.sql);

/// Notify the owner that startup authentication has reached ReadyForQuery.
pub const ReadyCallback = *const fn (context: *anyopaque, index: usize) void;
/// Notify only after the closed socket's completions cannot fire again.
pub const ClosedCallback = *const fn (context: *anyopaque, index: usize, failure: runtime.RuntimeError) void;
/// Deliver a borrowed response before scheduling another query on the slot.
pub const CompleteCallback = *const fn (context: *anyopaque, index: usize, outcome: runtime.QueryOutcome) void;
/// The SQL protocol state excludes transport teardown bookkeeping.
pub const Phase = enum { dormant, connecting, ssl_response, handshaking, authenticating, ready, querying, canceling, closing };
/// The backend cancellation capability is never sent without the main connection's TLS policy.
pub const CancelKey = struct { pid: u32, secret: u32 };
/// Exact statement identity prevents accidental reuse with different SQL or OIDs.
pub const CachedStatement = struct {
    name: [64]u8 = undefined,
    sql: [4096]u8 = undefined,
    oids: [64]u32 = undefined,
    name_len: usize = 0,
    sql_len: usize = 0,
    oid_count: usize = 0,
    valid: bool = false,
};
/// Explicit inputs borrowed for the persistent socket's lifetime.
pub const StartOptions = struct {
    loop: *loop_module.Loop,
    scheduler: *scheduler_module.Scheduler,
    io: std.Io,
    config: runtime.Config,
    index: usize,
    context: *anyopaque,
    ready: ReadyCallback,
    closed: ClosedCallback,
    complete: CompleteCallback,
    cancel_key: ?CancelKey = null,
};
/// One stable connection address owns every callback and buffer until drained.
pub const Connection = struct {
    receive: []u8 = &.{},
    response: []u8 = &.{},
    transmit: []u8 = &.{},
    columns: [64 * runtime.max_batch_statements]types.Column = undefined,
    fields: [64]types.Field = undefined,
    column_names: [32 * 1024]u8 = undefined,
    result_sets: [runtime.max_batch_statements]runtime.ResultSet = undefined,
    result_tags: [runtime.max_batch_statements][128]u8 = undefined,
    cache_reserved: [32]bool = .{false} ** 32,
    parsed_cache: [runtime.max_batch_statements]?usize = .{null} ** runtime.max_batch_statements,
    cache: [32]CachedStatement = [_]CachedStatement{.{}} ** 32,
    read_buffer: [8192]u8 = undefined,
    ciphertext: [16 * 1024]u8 = undefined,
    command_tag: [128]u8 = undefined,
    auth_output: [4096]u8 = undefined,
    session: tls.Session = .{},
    scram: ?auth.Scram = null,
    options: StartOptions = undefined,
    socket: xev.TCP = undefined,
    connect_completion: xev.Completion = .{},
    read_completion: xev.Completion = .{},
    write_completion: xev.Completion = .{},
    close_completion: xev.Completion = .{},
    connect_cancel: xev.Completion = .{},
    read_cancel: xev.Completion = .{},
    write_cancel: xev.Completion = .{},
    deadline: wheel.TimerNode = .{},
    phase: Phase = .dormant,
    query: ?*runtime.Query = null,
    receive_len: usize = 0,
    response_len: usize = 0,
    response_bytes: usize = 0,
    row_count: usize = 0,
    column_count: usize = 0,
    columns_used: usize = 0,
    column_start: usize = 0,
    column_name_bytes: usize = 0,
    result_start: usize = 0,
    result_count: usize = 0,
    parse_count: usize = 0,
    parse_completed: usize = 0,
    command_len: usize = 0,
    auth_output_len: usize = 0,
    transmit_len: usize = 0,
    transmit_sent: usize = 0,
    cipher_len: usize = 0,
    cipher_sent: usize = 0,
    requested_write: usize = 0,
    pending_cache: ?usize = null,
    transaction_status: u8 = 'I',
    backend_pid: u32 = 0,
    backend_secret: u32 = 0,
    failure: runtime.RuntimeError = error.ConnectionClosed,
    query_failure: ?runtime.RuntimeError = null,
    connect_active: bool = false,
    read_active: bool = false,
    write_active: bool = false,
    writing_ciphertext: bool = false,
    connect_cancel_active: bool = false,
    read_cancel_active: bool = false,
    write_cancel_active: bool = false,
    close_complete: bool = false,
    tls_active: bool = false,
    authenticated: bool = false,
    scram_verified: bool = false,
    ready_pending: bool = false,
    cancel_sent: bool = false,

    pub fn start(self: *Connection, options: StartOptions) runtime.RuntimeError!void {
        if (self.phase != .dormant) return error.AlreadyStarted;
        self.options = options;
        self.failure = error.ConnectionClosed;
        self.receive_len = 0;
        self.response_len = 0;
        self.transmit_len = 0;
        self.transmit_sent = 0;
        self.cipher_len = 0;
        self.cipher_sent = 0;
        self.close_complete = false;
        self.tls_active = false;
        self.authenticated = false;
        self.scram_verified = false;
        self.ready_pending = false;
        self.cancel_sent = false;
        self.query_failure = null;
        self.auth_output_len = 0;
        self.transaction_status = 'I';
        for (&self.cache) |*entry| entry.valid = false;
        const address = std.Io.net.IpAddress.parse(options.config.host, options.config.port) catch return error.InvalidConfiguration;
        self.socket = xev.TCP.init(address) catch return error.ConnectionFailed;
        self.phase = .connecting;
        self.connect_active = true;
        self.socket.connect(options.loop.get_xev_loop(), &self.connect_completion, address, Connection, self, on_connect);
        options.scheduler.schedule_after(&self.deadline, options.config.connect_timeout_ms, on_startup_timeout, self);
    }

    pub fn execute(self: *Connection, query: *runtime.Query) runtime.RuntimeError!void {
        if (self.phase != .ready or self.query != null or self.write_active) return error.ConnectionBusy;
        if (query.batch.len > runtime.max_batch_statements) return error.BatchLimit;
        self.transmit_len = 0;
        self.transmit_sent = 0;
        self.pending_cache = null;
        self.parse_count = 0;
        self.parse_completed = 0;
        @memset(&self.cache_reserved, false);
        if (query.mode == .migration) {
            if (query.params.len != 0 or query.statement.name.len != 0 or query.batch.len != 0) return error.InvalidConfiguration;
            if (query.statement.sql.len > self.options.config.limits.max_statement_bytes) return error.StatementTooLarge;
            self.transmit_len = try simple_query(self.transmit, query.statement.sql);
        } else {
            if (query.batch.len == 0) {
                try self.encode_bound(.{ .statement = query.statement, .params = query.params });
            } else {
                for (query.batch) |operation| try self.encode_bound(operation);
            }
            self.transmit_len += try wire.sync(self.transmit[self.transmit_len..]);
        }
        self.response_len = 0;
        self.response_bytes = 0;
        self.column_count = 0;
        self.columns_used = 0;
        self.column_start = 0;
        self.column_name_bytes = 0;
        self.result_start = 0;
        self.result_count = 0;
        self.row_count = 0;
        self.command_len = 0;
        self.query_failure = null;
        self.query = query;
        self.phase = .querying;
        self.pump_write();
    }

    fn encode_bound(self: *Connection, operation: runtime.BoundStatement) runtime.RuntimeError!void {
        const limits = self.options.config.limits;
        if (operation.statement.sql.len > limits.max_statement_bytes or operation.statement.name.len >= 64) return error.StatementTooLarge;
        if (operation.params.len > limits.max_parameters or operation.statement.param_oids.len > limits.max_parameters) return error.TooManyParameters;
        for (operation.params) |param| {
            const field_bytes: usize = switch (param.value) {
                .text, .varchar, .bytea => |bytes| bytes.len,
                .numeric => |numeric| std.math.add(usize, numeric.digits.len, 8) catch return error.FieldTooLarge,
                .null => 0,
                .bool => 1,
                .int2 => 2,
                .int4, .float4, .date => 4,
                .int8, .float8, .timestamp => 8,
                .uuid => 16,
            };
            if (field_bytes > limits.max_field_bytes) return error.FieldTooLarge;
        }
        var oids: [64]u32 = undefined;
        var statement = operation.statement;
        if (statement.param_oids.len == 0 and operation.params.len > 0) {
            for (operation.params, 0..) |param, index| oids[index] = if (param.oid != 0) param.oid else types.value_oid(param.value);
            statement.param_oids = oids[0..operation.params.len];
        }
        self.pending_cache = null;
        if (!try self.find_statement(statement)) {
            self.transmit_len += try wire.parse(self.transmit[self.transmit_len..], statement);
            self.parsed_cache[self.parse_count] = self.pending_cache;
            self.parse_count += 1;
        }
        self.transmit_len += try wire.bind(self.transmit[self.transmit_len..], "", statement.name, operation.params);
        self.transmit_len += try wire.describe(self.transmit[self.transmit_len..], .portal, "");
        self.transmit_len += try wire.execute(self.transmit[self.transmit_len..], "", 0);
    }

    pub fn stop(self: *Connection, failure: runtime.RuntimeError) void {
        if (self.phase == .dormant or self.phase == .closing) return;
        self.failure = failure;
        self.phase = .closing;
        _ = self.options.scheduler.cancel(&self.deadline);
        const loop = self.options.loop.get_xev_loop();
        if (xev.submit_before_cancel() or builtin.os.tag == .windows) {
            xev.submit(loop) catch |err| log.err("SQL submit before close failed: {}", .{err});
        }
        if (self.connect_active) {
            self.connect_cancel_active = true;
            loop_module.cancel(loop, &self.connect_completion, &self.connect_cancel, Connection, self, on_connect_cancel);
        }
        if (self.read_active) {
            self.read_cancel_active = true;
            loop_module.cancel(loop, &self.read_completion, &self.read_cancel, Connection, self, on_read_cancel);
        }
        if (self.write_active) {
            self.write_cancel_active = true;
            loop_module.cancel(loop, &self.write_completion, &self.write_cancel, Connection, self, on_write_cancel);
        }
        if (builtin.os.tag == .windows) {
            tcp.close_socket(xev.tcp_fd(self.socket));
            self.close_complete = true;
            if (self.connect_completion.state() != .active) self.connect_active = false;
            if (self.read_completion.state() != .active) self.read_active = false;
            if (self.write_completion.state() != .active) self.write_active = false;
            self.finish_close();
            return;
        }
        self.socket.close(loop, &self.close_completion, Connection, self, on_close);
    }

    fn finish_close(self: *Connection) void {
        if (self.phase != .closing or !self.close_complete) return;
        if (self.connect_active or self.read_active or self.write_active) return;
        if (self.connect_cancel_active or self.read_cancel_active or self.write_cancel_active) return;
        if (self.scram) |*scram| scram.deinit();
        self.scram = null;
        self.session.deinit();
        self.options.cancel_key = null;
        self.backend_pid = 0;
        self.backend_secret = 0;
        std.crypto.secureZero(u8, &self.auth_output);
        std.crypto.secureZero(u8, self.transmit[0..self.transmit_len]);
        self.query = null;
        self.phase = .dormant;
        self.options.closed(self.options.context, self.options.index, self.failure);
    }

    fn find_statement(self: *Connection, statement: types.Statement) runtime.RuntimeError!bool {
        if (statement.name.len == 0) return false;
        const entries = self.cache[0..self.options.config.statement_cache_entries];
        for (entries, 0..) |*entry, index| {
            if ((!entry.valid and !self.cache_reserved[index]) or !std.mem.eql(u8, statement.name, entry.name[0..entry.name_len])) continue;
            if (!std.mem.eql(u8, statement.sql, entry.sql[0..entry.sql_len])) return error.UnknownStatement;
            if (!std.mem.eql(u32, statement.param_oids, entry.oids[0..entry.oid_count])) return error.UnknownStatement;
            return true;
        }
        for (entries, 0..) |*entry, index| {
            if (entry.valid or self.cache_reserved[index]) continue;
            self.cache_reserved[index] = true;
            @memcpy(entry.name[0..statement.name.len], statement.name);
            @memcpy(entry.sql[0..statement.sql.len], statement.sql);
            @memcpy(entry.oids[0..statement.param_oids.len], statement.param_oids);
            entry.name_len = statement.name.len;
            entry.sql_len = statement.sql.len;
            entry.oid_count = statement.param_oids.len;
            self.pending_cache = index;
            return false;
        }
        return error.StatementCacheFull;
    }

    fn queue_startup(self: *Connection) void {
        if (self.options.cancel_key) |key| {
            self.transmit_len = wire.cancel(self.transmit, key.pid, key.secret) catch |err| {
                self.stop(err);
                return;
            };
            self.transmit_sent = 0;
            self.phase = .canceling;
            self.pump_write();
            return;
        }
        self.transmit_len = wire.startup(self.transmit, self.options.config.user, self.options.config.database) catch |err| {
            self.stop(err);
            return;
        };
        self.transmit_sent = 0;
        self.phase = .authenticating;
        self.pump_write();
    }

    fn pump_write(self: *Connection) void {
        if (self.phase == .closing or self.phase == .dormant or self.write_active) return;
        if (self.transmit_sent == self.transmit_len and self.auth_output_len > 0) {
            if (self.auth_output_len > self.transmit.len) {
                self.stop(error.BufferTooSmall);
                return;
            }
            @memcpy(self.transmit[0..self.auth_output_len], self.auth_output[0..self.auth_output_len]);
            self.transmit_len = self.auth_output_len;
            self.transmit_sent = 0;
            std.crypto.secureZero(u8, self.auth_output[0..self.auth_output_len]);
            self.auth_output_len = 0;
        }
        if (self.tls_active) {
            self.pump_tls();
            return;
        }
        if (self.transmit_sent == self.transmit_len) {
            if (self.phase == .canceling) self.cancel_sent = true;
            self.deliver_ready();
            return;
        }
        self.arm_write(self.transmit[self.transmit_sent..self.transmit_len]);
    }

    fn arm_write(self: *Connection, bytes: []const u8) void {
        self.requested_write = bytes.len;
        self.writing_ciphertext = self.tls_active;
        self.write_active = true;
        self.socket.write(self.options.loop.get_xev_loop(), &self.write_completion, .{ .slice = bytes }, Connection, self, on_write);
    }

    fn arm_read(self: *Connection) void {
        if (self.read_active or self.phase == .closing or self.phase == .dormant) return;
        self.read_active = true;
        self.socket.read(self.options.loop.get_xev_loop(), &self.read_completion, .{ .slice = &self.read_buffer }, Connection, self, on_read);
    }

    fn pump_tls(self: *Connection) void {
        if (self.write_active) return;
        if (self.cipher_sent < self.cipher_len) {
            self.arm_write(self.ciphertext[self.cipher_sent..self.cipher_len]);
            return;
        }
        const ssl = self.session.ssl.?;
        if (self.phase == .handshaking) {
            const result = c.SSL_do_handshake(ssl);
            if (result == 1) {
                if (c.SSL_get_verify_result(ssl) != c.X509_V_OK) {
                    self.stop(error.CertificateVerificationFailed);
                    return;
                }
                self.queue_startup();
                return;
            } else if (!self.tls_retry(result)) return;
        }
        if (self.phase != .handshaking and self.transmit_sent < self.transmit_len) {
            const bytes = self.transmit[self.transmit_sent..self.transmit_len];
            const written = c.SSL_write(ssl, bytes.ptr, @intCast(@min(bytes.len, 16 * 1024)));
            if (written > 0) self.transmit_sent += @intCast(written) else if (!self.tls_retry(written)) return;
        }
        const pending = c.BIO_ctrl_pending(self.session.network_bio.?);
        if (pending > 0) {
            const read = c.BIO_read(self.session.network_bio.?, &self.ciphertext, self.ciphertext.len);
            if (read <= 0) {
                self.stop(error.TlsFailed);
                return;
            }
            self.cipher_len = @intCast(read);
            self.cipher_sent = 0;
            self.arm_write(self.ciphertext[0..self.cipher_len]);
            return;
        }
        self.deliver_ready();
        if (self.phase == .canceling and self.transmit_sent == self.transmit_len) self.cancel_sent = true;
    }

    fn tls_retry(self: *Connection, result: c_int) bool {
        switch (c.SSL_get_error(self.session.ssl.?, result)) {
            c.SSL_ERROR_WANT_READ, c.SSL_ERROR_WANT_WRITE => return true,
            c.SSL_ERROR_ZERO_RETURN => {
                self.peer_closed();
                return false;
            },
            else => {
                self.stop(if (c.SSL_get_verify_result(self.session.ssl.?) != c.X509_V_OK) error.CertificateVerificationFailed else error.TlsFailed);
                return false;
            },
        }
    }

    fn consume_tls(self: *Connection, bytes: []const u8) void {
        const written = c.BIO_write(self.session.network_bio.?, bytes.ptr, @intCast(bytes.len));
        if (written != bytes.len) {
            self.stop(error.TlsFailed);
            return;
        }
        self.pump_write();
        if (self.phase == .handshaking or self.phase == .closing) return;
        var plaintext: [8192]u8 = undefined;
        while (self.phase != .closing) {
            const count = c.SSL_read(self.session.ssl.?, &plaintext, plaintext.len);
            if (count <= 0) {
                _ = self.tls_retry(count);
                break;
            }
            self.consume(plaintext[0..@intCast(count)]);
        }
        self.pump_write();
    }

    fn consume(self: *Connection, bytes: []const u8) void {
        var offset: usize = 0;
        while (offset < bytes.len and self.phase != .closing) {
            const take = @min(bytes.len - offset, self.receive.len - self.receive_len);
            if (take == 0) {
                self.stop(error.MessageTooLarge);
                return;
            }
            @memcpy(self.receive[self.receive_len..][0..take], bytes[offset..][0..take]);
            self.receive_len += take;
            offset += take;
            self.consume_frames() catch |err| {
                self.stop(err);
                return;
            };
        }
    }

    fn consume_frames(self: *Connection) runtime.RuntimeError!void {
        var consumed: usize = 0;
        while (try wire.decode(self.receive[consumed..self.receive_len], self.options.config.limits.max_message_bytes)) |frame| {
            if (self.phase == .closing) break;
            try self.process_frame(frame);
            consumed += frame.consumed;
            if (consumed == self.receive_len) break;
        }
        if (consumed > 0) {
            std.mem.copyForwards(u8, self.receive[0 .. self.receive_len - consumed], self.receive[consumed..self.receive_len]);
            self.receive_len -= consumed;
        }
        self.deliver_ready();
    }

    fn process_frame(self: *Connection, frame: wire.Frame) runtime.RuntimeError!void {
        if (self.phase == .authenticating) {
            try self.process_startup(frame);
            return;
        }
        if (self.phase != .querying) {
            if (frame.tag == 'N' or frame.tag == 'S' or frame.tag == 'A') return;
            return error.ProtocolError;
        }
        self.response_bytes = std.math.add(usize, self.response_bytes, frame.consumed) catch return error.ResponseTooLarge;
        if (self.response_bytes > self.options.config.limits.max_response_bytes) return error.ResponseTooLarge;
        switch (frame.tag) {
            '1' => {
                if (frame.payload.len != 0) return error.ProtocolError;
                if (self.parse_completed >= self.parse_count) return error.ProtocolError;
                if (self.parsed_cache[self.parse_completed]) |index| {
                    self.cache[index].valid = true;
                    self.cache_reserved[index] = false;
                }
                self.parse_completed += 1;
            },
            '2' => if (frame.payload.len != 0) return error.ProtocolError,
            'n' => {
                if (frame.payload.len != 0) return error.ProtocolError;
                self.column_start = self.columns_used;
                self.column_count = 0;
            },
            'T' => try self.store_columns(frame.payload),
            'D' => try self.store_row(frame),
            'C' => {
                if (frame.payload.len == 0 or frame.payload[frame.payload.len - 1] != 0) return error.ProtocolError;
                if (frame.payload.len > self.command_tag.len) return error.ResponseTooLarge;
                self.command_len = frame.payload.len - 1;
                @memcpy(self.command_tag[0..self.command_len], frame.payload[0..self.command_len]);
                try self.store_result();
            },
            'E' => self.query_failure = error.ServerError,
            'N', 'S', 'A', 't', 'I' => {},
            'Z' => {
                try self.set_ready_status(frame.payload);
                self.ready_pending = true;
            },
            else => return error.ProtocolError,
        }
    }

    fn store_columns(self: *Connection, payload: []const u8) runtime.RuntimeError!void {
        self.column_start = self.columns_used;
        const columns = try rows.decode_columns(payload, self.columns[self.columns_used..], self.options.config.limits);
        self.columns_used += columns.len;
        var name_bytes = self.column_name_bytes;
        for (columns) |*column| {
            if (column.name.len > self.column_names.len - name_bytes) return error.FieldTooLarge;
            @memcpy(self.column_names[name_bytes..][0..column.name.len], column.name);
            column.name = self.column_names[name_bytes..][0..column.name.len];
            name_bytes += column.name.len;
        }
        self.column_count = columns.len;
        self.column_name_bytes = name_bytes;
    }

    fn store_result(self: *Connection) runtime.RuntimeError!void {
        if (self.result_count == self.result_sets.len) return error.BatchLimit;
        const tag = self.result_tags[self.result_count][0..self.command_len];
        @memcpy(tag, self.command_tag[0..self.command_len]);
        self.result_sets[self.result_count] = .{
            .rows = .{
                .data = self.response[self.result_start..self.response_len],
                .columns = self.columns[self.column_start..][0..self.column_count],
                .fields = &self.fields,
                .limits = self.options.config.limits,
            },
            .command_tag = tag,
        };
        self.result_count += 1;
        self.result_start = self.response_len;
        self.column_start = self.columns_used;
        self.column_count = 0;
    }

    fn store_row(self: *Connection, frame: wire.Frame) runtime.RuntimeError!void {
        if (self.row_count >= self.options.config.limits.max_rows) return error.TooManyRows;
        _ = try rows.decode_row(frame.payload, self.columns[self.column_start..][0..self.column_count], &self.fields, self.options.config.limits);
        if (frame.consumed > self.response.len - self.response_len) return error.ResponseTooLarge;
        const out = self.response[self.response_len..][0..frame.consumed];
        out[0] = 'D';
        std.mem.writeInt(u32, out[1..5], @intCast(frame.payload.len + 4), .big);
        @memcpy(out[5..], frame.payload);
        self.response_len += frame.consumed;
        self.row_count += 1;
    }

    fn process_startup(self: *Connection, frame: wire.Frame) runtime.RuntimeError!void {
        switch (frame.tag) {
            'R' => try self.authenticate(frame.payload),
            'S', 'N' => {},
            'K' => {
                if (frame.payload.len != 8) return error.ProtocolError;
                self.backend_pid = std.mem.readInt(u32, frame.payload[0..4], .big);
                self.backend_secret = std.mem.readInt(u32, frame.payload[4..8], .big);
            },
            'E' => return error.AuthenticationFailed,
            'Z' => {
                if (!self.authenticated) return error.AuthenticationFailed;
                try self.set_ready_status(frame.payload);
                if (self.transaction_status != 'I') return error.ProtocolError;
                self.ready_pending = true;
            },
            else => return error.ProtocolError,
        }
    }

    fn authenticate(self: *Connection, payload: []const u8) runtime.RuntimeError!void {
        if (payload.len < 4 or self.authenticated) return error.ProtocolError;
        const kind = std.mem.readInt(u32, payload[0..4], .big);
        const challenge = payload[4..];
        var out: [4096]u8 = undefined;
        defer std.crypto.secureZero(u8, &out);
        var response: []const u8 = undefined;
        var sasl_initial = false;
        switch (kind) {
            0 => {
                if (challenge.len != 0 or (self.scram != null and !self.scram_verified)) return error.AuthenticationFailed;
                self.authenticated = true;
                return;
            },
            5 => {
                if (challenge.len != 4 or self.scram != null) return error.AuthenticationFailed;
                auth.md5_password(out[0..36], self.options.config.password, self.options.config.user, challenge[0..4].*);
                response = out[0..36];
            },
            10 => {
                if (self.scram != null or !supports_scram(challenge)) return error.UnsupportedAuthentication;
                var random: [24]u8 = undefined;
                std.Io.randomSecure(self.options.io, &random) catch return error.AuthenticationFailed;
                var nonce: [32]u8 = undefined;
                _ = std.base64.standard.Encoder.encode(&nonce, &random);
                self.scram = try auth.Scram.init(self.options.config.user, &nonce);
                response = try self.scram.?.client_first(&out);
                sasl_initial = true;
            },
            11 => {
                const scram = if (self.scram) |*value| value else return error.AuthenticationFailed;
                response = try scram.respond(self.options.config.password, challenge, &out);
            },
            12 => {
                const scram = if (self.scram) |*value| value else return error.AuthenticationFailed;
                try scram.verify(challenge);
                self.scram_verified = true;
                return;
            },
            else => return error.UnsupportedAuthentication,
        }
        if (self.auth_output_len != 0) return error.ProtocolError;
        self.auth_output_len = if (sasl_initial) try wire.sasl_initial(&self.auth_output, "SCRAM-SHA-256", response) else try wire.password(&self.auth_output, response);
        self.pump_write();
    }

    fn set_ready_status(self: *Connection, payload: []const u8) runtime.RuntimeError!void {
        if (payload.len != 1) return error.ProtocolError;
        switch (payload[0]) {
            'I', 'T', 'E' => self.transaction_status = payload[0],
            else => return error.ProtocolError,
        }
    }

    fn deliver_ready(self: *Connection) void {
        if (!self.ready_pending or self.write_active or self.transmit_sent != self.transmit_len) return;
        if (self.tls_active and (self.cipher_sent != self.cipher_len or c.BIO_ctrl_pending(self.session.network_bio.?) != 0)) return;
        self.ready_pending = false;
        if (self.phase == .authenticating) {
            _ = self.options.scheduler.cancel(&self.deadline);
            if (self.scram) |*scram| scram.deinit();
            self.scram = null;
            self.phase = .ready;
            self.options.ready(self.options.context, self.options.index);
            return;
        }
        if (self.phase != .querying) return;
        self.phase = .ready;
        self.query = null;
        const outcome: runtime.QueryOutcome = if (self.query_failure) |failure| .{ .failure = failure } else .{ .success = .{
            .rows = if (self.result_count > 0) self.result_sets[0].rows else .{ .data = self.response[0..self.response_len], .columns = &.{}, .fields = &self.fields, .limits = self.options.config.limits },
            .results = self.result_sets[0..self.result_count],
            .transaction_status = self.transaction_status,
            .command_tag = self.command_tag[0..self.command_len],
        } };
        self.options.complete(self.options.context, self.options.index, outcome);
    }

    fn on_connect(user_data: ?*Connection, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, result: xev.ConnectError!void) xev.CallbackAction {
        const self = user_data.?;
        self.connect_active = false;
        if (self.phase == .closing) {
            self.finish_close();
            return .disarm;
        }
        result catch {
            self.stop(error.ConnectionFailed);
            return .disarm;
        };
        self.arm_read();
        if (self.options.config.tls != null) {
            self.phase = .ssl_response;
            self.transmit_len = wire.ssl_request(self.transmit) catch |err| {
                self.stop(err);
                return .disarm;
            };
            self.transmit_sent = 0;
            self.pump_write();
        } else self.queue_startup();
        return .disarm;
    }

    fn on_read(user_data: ?*Connection, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.ReadBuffer, result: xev.ReadError!usize) xev.CallbackAction {
        const self = user_data.?;
        self.read_active = false;
        if (self.phase == .closing) {
            self.finish_close();
            return .disarm;
        }
        const count = result catch |err| {
            if (err == error.EOF) self.peer_closed() else self.stop(error.ConnectionClosed);
            return .disarm;
        };
        if (count == 0 or count > self.read_buffer.len) {
            if (count == 0) self.peer_closed() else self.stop(error.ConnectionClosed);
            return .disarm;
        }
        const bytes = self.read_buffer[0..count];
        if (self.phase == .ssl_response) {
            if (bytes.len != 1 or bytes[0] != 'S') {
                self.stop(error.TlsRequired);
                return .disarm;
            }
            self.tls_active = true;
            self.phase = .handshaking;
            self.pump_write();
        } else if (self.tls_active) self.consume_tls(bytes) else self.consume(bytes);
        self.arm_read();
        return .disarm;
    }

    fn on_write(user_data: ?*Connection, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, _: xev.WriteBuffer, result: xev.WriteError!usize) xev.CallbackAction {
        const self = user_data.?;
        self.write_active = false;
        if (self.phase == .closing) {
            self.finish_close();
            return .disarm;
        }
        const count = result catch {
            self.stop(error.ConnectionClosed);
            return .disarm;
        };
        if (count == 0 or count > self.requested_write) {
            self.stop(error.ConnectionClosed);
            return .disarm;
        }
        if (self.writing_ciphertext) self.cipher_sent += count else self.transmit_sent += count;
        self.pump_write();
        return .disarm;
    }

    fn on_close(user_data: ?*Connection, _: *xev.Loop, _: *xev.Completion, _: xev.TCP, result: xev.CloseError!void) xev.CallbackAction {
        const self = user_data.?;
        result catch |err| log.debug("SQL close failed: {}", .{err});
        self.close_complete = true;
        if (xev.cancel_abandons_target()) {
            self.connect_active = false;
            self.read_active = false;
            self.write_active = false;
        }
        self.finish_close();
        return .disarm;
    }

    fn on_connect_cancel(user_data: ?*Connection, _: *xev.Loop, _: *xev.Completion, result: xev.CancelError!void) xev.CallbackAction {
        const self = user_data.?;
        result catch |err| {
            if (err != error.NotFound) log.debug("SQL connect cancellation failed: {}", .{err});
        };
        self.connect_cancel_active = false;
        self.finish_close();
        return .disarm;
    }

    fn on_read_cancel(user_data: ?*Connection, _: *xev.Loop, _: *xev.Completion, result: xev.CancelError!void) xev.CallbackAction {
        const self = user_data.?;
        result catch |err| {
            if (err != error.NotFound) log.debug("SQL read cancellation failed: {}", .{err});
        };
        self.read_cancel_active = false;
        self.finish_close();
        return .disarm;
    }

    fn on_write_cancel(user_data: ?*Connection, _: *xev.Loop, _: *xev.Completion, result: xev.CancelError!void) xev.CallbackAction {
        const self = user_data.?;
        result catch |err| {
            if (err != error.NotFound) log.debug("SQL write cancellation failed: {}", .{err});
        };
        self.write_cancel_active = false;
        self.finish_close();
        return .disarm;
    }

    fn on_startup_timeout(context: *anyopaque) void {
        const self: *Connection = @ptrCast(@alignCast(context));
        self.stop(error.QueryTimeout);
    }

    fn peer_closed(self: *Connection) void {
        if (self.phase == .canceling) {
            self.cancel_sent = true;
            self.stop(error.Canceled);
            return;
        }
        self.stop(if (self.receive_len != 0) error.TruncatedMessage else error.ConnectionClosed);
    }
};

fn supports_scram(mechanisms: []const u8) bool {
    var iterator = std.mem.splitScalar(u8, mechanisms, 0);
    while (iterator.next()) |mechanism| {
        if (std.mem.eql(u8, mechanism, "SCRAM-SHA-256")) return true;
    }
    return false;
}

fn simple_query(buffer: []u8, sql: []const u8) runtime.RuntimeError!usize {
    if (std.mem.indexOfScalar(u8, sql, 0) != null) return error.InvalidString;
    if (sql.len > buffer.len or buffer.len - sql.len < 6) return error.BufferTooSmall;
    buffer[0] = 'Q';
    std.mem.writeInt(u32, buffer[1..5], @intCast(sql.len + 5), .big);
    @memcpy(buffer[5..][0..sql.len], sql);
    buffer[sql.len + 5] = 0;
    return sql.len + 6;
}
