const std = @import("std");

const dynamic_entry_overhead: usize = 32;
const first_dynamic_index: usize = 62;

/// Errors produced by bounded HPACK decoding and response encoding.
pub const Error = error{
    /// Input ended within an HPACK representation.
    TruncatedInput,
    /// An integer or length cannot fit the host representation.
    IntegerOverflow,
    /// An integer used a redundant terminal continuation byte.
    NonCanonicalInteger,
    /// A static or dynamic table index was zero or unavailable.
    InvalidIndex,
    /// A Huffman string contains EOS or invalid padding/code bits.
    InvalidHuffman,
    /// Caller-owned decoded or encoded byte storage is exhausted.
    OutputTooSmall,
    /// Caller-owned header metadata slots are exhausted.
    HeaderCapacityExceeded,
    /// The RFC field-list size exceeds the configured limit.
    HeaderListTooLarge,
    /// Caller-owned dynamic-table byte storage is insufficient.
    DynamicTableStorageTooSmall,
    /// Caller-owned dynamic-table metadata slots are insufficient.
    DynamicTableEntryCapacity,
    /// A table-size update exceeds the negotiated ceiling.
    DynamicTableSizeTooLarge,
    /// A table-size update appeared after a header representation.
    DynamicTableUpdateAfterHeader,
    /// A field name was empty.
    EmptyHeaderName,
    /// A field name contained an uppercase ASCII letter.
    UppercaseHeaderName,
    /// A field name contained a byte outside the allowed token grammar.
    InvalidHeaderName,
    /// A field value contained forbidden or surrounding whitespace bytes.
    InvalidHeaderValue,
    /// A request contained an unknown pseudo-field.
    InvalidPseudoHeader,
    /// A request repeated a recognized pseudo-field.
    DuplicatePseudoHeader,
    /// A request contained more than one Host field.
    DuplicateHost,
    /// Host and `:authority` identified different authorities.
    AuthorityHostMismatch,
    /// A pseudo-field followed a regular field.
    PseudoHeaderAfterRegular,
    /// A request omitted `:method`.
    MissingMethod,
    /// A non-CONNECT request omitted `:scheme`.
    MissingScheme,
    /// A non-CONNECT request omitted `:path`.
    MissingPath,
    /// A CONNECT request omitted `:authority`.
    MissingAuthority,
    /// Extended CONNECT pseudo-fields were incomplete or used on another method.
    InvalidExtendedConnectPseudoHeaders,
    /// The method was empty or contained a non-token byte.
    InvalidMethod,
    /// The scheme did not match the URI scheme grammar.
    InvalidScheme,
    /// The authority was empty or contained a forbidden delimiter/control.
    InvalidAuthority,
    /// The path was neither absolute nor the OPTIONS asterisk form.
    InvalidPath,
    /// A regular CONNECT request included `:scheme` or `:path`.
    InvalidConnectPseudoHeaders,
    /// A field forbidden by HTTP/2 connection semantics was present.
    ConnectionSpecificHeader,
    /// A `te` field had a value other than `trailers`.
    InvalidTe,
    /// A response status was outside 100 through 599.
    InvalidStatus,
    /// A response header list supplied an application pseudo-field.
    ResponsePseudoHeader,
    /// A trailer section contained a pseudo-field or forbidden framing field.
    InvalidTrailer,
};

/// One decoded or caller-provided HTTP field.
pub const Header = struct {
    /// Lowercase HTTP field or pseudo-field name.
    name: []const u8,
    /// Field value bytes.
    value: []const u8,
};

/// Caller-owned metadata for one dynamic-table entry.
///
/// Callers allocate these slots but must not depend on their contents.
pub const DynamicEntry = struct {
    /// Offset of name bytes in `DynamicTable.storage`.
    name_offset: usize = 0,
    /// Number of name bytes.
    name_length: usize = 0,
    /// Offset of value bytes in `DynamicTable.storage`.
    value_offset: usize = 0,
    /// Number of value bytes.
    value_length: usize = 0,
    /// RFC table size, including the fixed per-entry overhead.
    field_size: usize = 0,
};

/// Bounded RFC 7541 dynamic table backed entirely by caller-owned memory.
///
/// The byte buffer must be at least `maximum_size` bytes and the metadata
/// buffer must contain `ceil(maximum_size / 32)` entries. Passing zero for
/// `maximum_size` explicitly disables dynamic indexing and permits empty
/// buffers. The table does not retain any input or decoded-output slices.
pub const DynamicTable = struct {
    /// Caller-owned metadata storage, newest live entry first.
    entries: []DynamicEntry,
    /// Caller-owned packed name/value storage.
    storage: []u8,
    /// Number of initialized metadata entries.
    entry_len: usize = 0,
    /// Number of initialized bytes in `storage`.
    storage_len: usize = 0,
    /// Current RFC table size including entry overhead.
    size: usize = 0,
    /// Active peer-selected table-size limit.
    max_size: usize,
    /// Negotiated ceiling for peer table-size updates.
    allowed_max_size: usize,

    /// Initializes an empty table with a fixed negotiated size ceiling.
    ///
    /// The caller retains both buffers for the table's entire lifetime and must
    /// not mutate them or the public bookkeeping fields directly. Failure does
    /// not initialize or retain either buffer.
    pub fn init(
        entries: []DynamicEntry,
        storage: []u8,
        requested_size: usize,
    ) Error!DynamicTable {
        if (storage.len < requested_size) return error.DynamicTableStorageTooSmall;

        const required_entries = requested_size / dynamic_entry_overhead +
            @as(usize, @intFromBool(requested_size % dynamic_entry_overhead != 0));
        if (entries.len < required_entries) return error.DynamicTableEntryCapacity;

        return .{
            .entries = entries,
            .storage = storage,
            .max_size = requested_size,
            .allowed_max_size = requested_size,
        };
    }

    /// Removes every entry while preserving the negotiated size limits.
    ///
    /// Existing metadata and bytes become unspecified and reusable.
    pub fn clear(self: *DynamicTable) void {
        self.entry_len = 0;
        self.storage_len = 0;
        self.size = 0;
    }

    /// Returns the number of live entries stored newest first.
    pub fn count(self: *const DynamicTable) usize {
        return self.entry_len;
    }

    /// Returns the RFC 7541 size of all live entries.
    pub fn current_size(self: *const DynamicTable) usize {
        return self.size;
    }

    /// Returns the active table-size limit selected by the peer.
    pub fn maximum_size(self: *const DynamicTable) usize {
        return self.max_size;
    }

    fn set_maximum_size(self: *DynamicTable, requested_size: usize) Error!void {
        if (requested_size > self.allowed_max_size) return error.DynamicTableSizeTooLarge;
        self.max_size = requested_size;
        while (self.size > requested_size) self.evict_oldest();
    }

    fn get(self: *const DynamicTable, index: usize) ?Header {
        if (index >= self.entry_len) return null;
        const entry = self.entries[index];
        const name_end = entry.name_offset + entry.name_length;
        const value_end = entry.value_offset + entry.value_length;
        return .{
            .name = self.storage[entry.name_offset..name_end],
            .value = self.storage[entry.value_offset..value_end],
        };
    }

    fn add(self: *DynamicTable, name: []const u8, value: []const u8) Error!void {
        const field_bytes = std.math.add(usize, name.len, value.len) catch
            return error.IntegerOverflow;
        const field_size = std.math.add(usize, field_bytes, dynamic_entry_overhead) catch
            return error.IntegerOverflow;

        if (field_size > self.max_size) {
            self.clear();
            return;
        }

        while (self.size > self.max_size - field_size) self.evict_oldest();
        if (self.entry_len == self.entries.len) return error.DynamicTableEntryCapacity;
        if (field_bytes > self.storage.len - self.storage_len) {
            return error.DynamicTableStorageTooSmall;
        }

        std.mem.copyBackwards(
            u8,
            self.storage[field_bytes .. field_bytes + self.storage_len],
            self.storage[0..self.storage_len],
        );

        var index = self.entry_len;
        while (index > 0) : (index -= 1) {
            const previous = self.entries[index - 1];
            self.entries[index] = .{
                .name_offset = previous.name_offset + field_bytes,
                .name_length = previous.name_length,
                .value_offset = previous.value_offset + field_bytes,
                .value_length = previous.value_length,
                .field_size = previous.field_size,
            };
        }

        @memcpy(self.storage[0..name.len], name);
        @memcpy(self.storage[name.len..field_bytes], value);
        self.entries[0] = .{
            .name_offset = 0,
            .name_length = name.len,
            .value_offset = name.len,
            .value_length = value.len,
            .field_size = field_size,
        };
        self.entry_len += 1;
        self.storage_len += field_bytes;
        self.size += field_size;
    }

    fn evict_oldest(self: *DynamicTable) void {
        if (self.entry_len == 0) return;
        const entry = self.entries[self.entry_len - 1];
        self.entry_len -= 1;
        self.storage_len -= entry.name_length + entry.value_length;
        self.size -= entry.field_size;
    }
};

/// Validated request pseudo-fields and the complete decoded field list.
///
/// Every returned slice borrows `header_storage` or `headers` passed to
/// `Decoder.decode_request` and remains valid until either is reused.
pub const Request = struct {
    /// All decoded fields in wire order, including pseudo-fields.
    headers: []const Header,
    /// Regular fields after the required pseudo-field prefix.
    fields: []const Header,
    /// Required request method.
    method: []const u8,
    /// Request scheme, absent only for a regular CONNECT request.
    scheme: ?[]const u8,
    /// Optional authority, required for CONNECT.
    authority: ?[]const u8,
    /// Request path, absent only for a regular CONNECT request.
    path: ?[]const u8,
    /// Extended CONNECT protocol token, when negotiated by SETTINGS.
    protocol: ?[]const u8,
};

/// Stateful bounded HPACK request decoder.
///
/// One decoder and dynamic table belong to one HTTP/2 connection and are not
/// thread-safe. Decoded fields are copied into caller storage so later dynamic
/// table mutations cannot invalidate a returned request.
pub const Decoder = struct {
    /// Connection-owned dynamic table; must outlive the decoder.
    dynamic_table: *DynamicTable,
    /// Maximum RFC uncompressed field-list size for one request.
    max_header_list_size: usize,

    /// Binds a connection table and the local uncompressed field-list limit.
    ///
    /// The decoder borrows `dynamic_table` for its lifetime and performs no
    /// allocation. The caller must serialize access per HTTP/2 connection.
    pub fn init(
        dynamic_table: *DynamicTable,
        max_header_list_size: usize,
    ) Decoder {
        return .{
            .dynamic_table = dynamic_table,
            .max_header_list_size = max_header_list_size,
        };
    }

    /// Decodes and validates one complete request field section.
    ///
    /// `headers` bounds the field count and `header_storage` bounds decoded
    /// name/value bytes. Peer input is never retained. A syntax or capacity
    /// error can leave both caller output buffers unspecified; dynamic-table
    /// updates successfully decoded before that error remain applied.
    pub fn decode_request(
        self: *Decoder,
        block: []const u8,
        headers: []Header,
        header_storage: []u8,
    ) Error!Request {
        return validate_request(try self.decode_fields(block, headers, header_storage));
    }

    /// Decodes one field section without applying request pseudo-field rules.
    ///
    /// This entry point preserves HPACK dynamic-table synchronization for
    /// trailers and extension protocols. Returned slices borrow caller storage.
    pub fn decode_fields(
        self: *Decoder,
        block: []const u8,
        headers: []Header,
        header_storage: []u8,
    ) Error![]const Header {
        var writer = HeaderWriter{
            .headers = headers,
            .storage = header_storage,
            .max_list_size = self.max_header_list_size,
        };
        var offset: usize = 0;
        var saw_header = false;

        while (offset < block.len) {
            const first = block[offset];
            if (first & 0x80 != 0) {
                saw_header = true;
                const index = try decode_integer(block, &offset, 7);
                if (index == 0) return error.InvalidIndex;
                const header = try self.lookup(index);
                try writer.append_copy(header);
                continue;
            }

            if (first & 0x40 != 0) {
                saw_header = true;
                try self.decode_literal(block, &offset, 6, true, &writer);
                continue;
            }

            if (first & 0x20 != 0) {
                if (saw_header) return error.DynamicTableUpdateAfterHeader;
                const maximum_size = try decode_integer(block, &offset, 5);
                try self.dynamic_table.set_maximum_size(maximum_size);
                continue;
            }

            saw_header = true;
            try self.decode_literal(block, &offset, 4, false, &writer);
        }

        return writer.headers[0..writer.header_len];
    }

    fn lookup(self: *const Decoder, index: usize) Error!Header {
        if (index <= static_table.len) return static_table[index - 1];
        const dynamic_index = index - first_dynamic_index;
        return self.dynamic_table.get(dynamic_index) orelse error.InvalidIndex;
    }

    fn decode_literal(
        self: *Decoder,
        block: []const u8,
        offset: *usize,
        comptime prefix_bits: u4,
        add_to_dynamic_table: bool,
        writer: *HeaderWriter,
    ) Error!void {
        if (writer.header_len == writer.headers.len) return error.HeaderCapacityExceeded;

        const name_index = try decode_integer(block, offset, prefix_bits);
        const name = if (name_index == 0)
            try writer.decode_string(block, offset)
        else
            try writer.copy((try self.lookup(name_index)).name);
        const value = try writer.decode_string(block, offset);
        try writer.finish_header(name, value);

        if (add_to_dynamic_table) try self.dynamic_table.add(name, value);
    }
};

/// Validates an HTTP/2 trailer section after HPACK decoding.
pub fn validate_trailers(headers: []const Header) Error!void {
    for (headers) |header| {
        try validate_name(header.name);
        try validate_value(header.value);
        if (header.name[0] == ':') return error.InvalidTrailer;
        if (std.mem.eql(u8, header.name, "content-length")) return error.InvalidTrailer;
        try validate_connection_field(header);
    }
}

/// Encodes a validated minimal response field section without dynamic state.
///
/// Exact static-table fields use indexed representation. Other fields use a
/// raw literal without indexing; `set-cookie` uses never-indexed form. The
/// returned slice borrows `output`, whose contents are unspecified on error.
pub fn encode_response(
    status: u16,
    headers: []const Header,
    output: []u8,
) Error![]const u8 {
    if (status < 100 or status > 599) return error.InvalidStatus;
    for (headers) |header| {
        try validate_name(header.name);
        if (header.name[0] == ':') return error.ResponsePseudoHeader;
        try validate_value(header.value);
        if (std.mem.eql(u8, header.name, "te")) return error.ConnectionSpecificHeader;
        try validate_connection_field(header);
    }

    var writer = ByteWriter{ .storage = output };
    if (status_static_index(status)) |index| {
        try writer.encode_integer(index, 7, 0x80);
    } else {
        try writer.encode_integer(8, 4, 0x00);
        var status_bytes: [3]u8 = .{
            @intCast(status / 100 + '0'),
            @intCast(status / 10 % 10 + '0'),
            @intCast(status % 10 + '0'),
        };
        try writer.encode_string(&status_bytes);
    }

    for (headers) |header| {
        if (find_static_exact(header)) |index| {
            try writer.encode_integer(index, 7, 0x80);
            continue;
        }

        const prefix: u8 = if (std.mem.eql(u8, header.name, "set-cookie")) 0x10 else 0x00;
        const name_index = find_static_name(header.name) orelse 0;
        try writer.encode_integer(name_index, 4, prefix);
        if (name_index == 0) try writer.encode_string(header.name);
        try writer.encode_string(header.value);
    }

    return output[0..writer.len];
}

const HeaderWriter = struct {
    headers: []Header,
    storage: []u8,
    header_len: usize = 0,
    storage_len: usize = 0,
    list_size: usize = 0,
    max_list_size: usize,

    fn append_copy(self: *HeaderWriter, header: Header) Error!void {
        if (self.header_len == self.headers.len) return error.HeaderCapacityExceeded;
        const name = try self.copy(header.name);
        const value = try self.copy(header.value);
        try self.finish_header(name, value);
    }

    fn finish_header(self: *HeaderWriter, name: []const u8, value: []const u8) Error!void {
        const field_bytes = std.math.add(usize, name.len, value.len) catch
            return error.IntegerOverflow;
        const field_size = std.math.add(usize, field_bytes, dynamic_entry_overhead) catch
            return error.IntegerOverflow;
        const list_size = std.math.add(usize, self.list_size, field_size) catch
            return error.HeaderListTooLarge;
        if (list_size > self.max_list_size) return error.HeaderListTooLarge;

        self.headers[self.header_len] = .{ .name = name, .value = value };
        self.header_len += 1;
        self.list_size = list_size;
    }

    fn copy(self: *HeaderWriter, bytes: []const u8) Error![]const u8 {
        const end = std.math.add(usize, self.storage_len, bytes.len) catch
            return error.OutputTooSmall;
        if (end > self.storage.len) return error.OutputTooSmall;
        @memcpy(self.storage[self.storage_len..end], bytes);
        const result = self.storage[self.storage_len..end];
        self.storage_len = end;
        return result;
    }

    fn decode_string(
        self: *HeaderWriter,
        input: []const u8,
        offset: *usize,
    ) Error![]const u8 {
        if (offset.* >= input.len) return error.TruncatedInput;
        const is_huffman = input[offset.*] & 0x80 != 0;
        const encoded_len = try decode_integer(input, offset, 7);
        const encoded_end = std.math.add(usize, offset.*, encoded_len) catch
            return error.IntegerOverflow;
        if (encoded_end > input.len) return error.TruncatedInput;

        const start = self.storage_len;
        if (is_huffman) {
            const written = try decode_huffman(
                input[offset.*..encoded_end],
                self.storage[start..],
            );
            self.storage_len += written;
        } else {
            _ = try self.copy(input[offset.*..encoded_end]);
        }
        offset.* = encoded_end;
        return self.storage[start..self.storage_len];
    }
};

const ByteWriter = struct {
    storage: []u8,
    len: usize = 0,

    fn put(self: *ByteWriter, byte: u8) Error!void {
        if (self.len == self.storage.len) return error.OutputTooSmall;
        self.storage[self.len] = byte;
        self.len += 1;
    }

    fn write(self: *ByteWriter, bytes: []const u8) Error!void {
        const end = std.math.add(usize, self.len, bytes.len) catch
            return error.OutputTooSmall;
        if (end > self.storage.len) return error.OutputTooSmall;
        @memcpy(self.storage[self.len..end], bytes);
        self.len = end;
    }

    fn encode_integer(
        self: *ByteWriter,
        value: usize,
        comptime prefix_bits: u4,
        prefix: u8,
    ) Error!void {
        const prefix_mask: u8 = @intCast((@as(u16, 1) << prefix_bits) - 1);
        if (value < prefix_mask) {
            try self.put(prefix | @as(u8, @intCast(value)));
            return;
        }

        try self.put(prefix | prefix_mask);
        var remainder = value - prefix_mask;
        while (remainder >= 128) {
            try self.put(@as(u8, @intCast(remainder & 0x7f)) | 0x80);
            remainder >>= 7;
        }
        try self.put(@intCast(remainder));
    }

    fn encode_string(self: *ByteWriter, bytes: []const u8) Error!void {
        try self.encode_integer(bytes.len, 7, 0x00);
        try self.write(bytes);
    }
};

fn decode_integer(
    input: []const u8,
    offset: *usize,
    comptime prefix_bits: u4,
) Error!usize {
    if (offset.* >= input.len) return error.TruncatedInput;
    const prefix_mask: u8 = @intCast((@as(u16, 1) << prefix_bits) - 1);
    var value: usize = input[offset.*] & prefix_mask;
    offset.* += 1;
    if (value < prefix_mask) return value;

    var shift: usize = 0;
    var continuation_count: usize = 0;
    while (true) {
        if (offset.* >= input.len) return error.TruncatedInput;
        const byte = input[offset.*];
        offset.* += 1;
        continuation_count += 1;

        const payload: usize = byte & 0x7f;
        if (payload != 0) {
            if (shift >= @bitSizeOf(usize)) return error.IntegerOverflow;
            const shift_amount: std.math.Log2Int(usize) = @intCast(shift);
            const maximum: usize = std.math.maxInt(usize);
            if (payload > maximum >> shift_amount) {
                return error.IntegerOverflow;
            }
            value = std.math.add(usize, value, payload << shift_amount) catch
                return error.IntegerOverflow;
        }

        if (byte & 0x80 == 0) {
            if (continuation_count > 1 and payload == 0) {
                return error.NonCanonicalInteger;
            }
            return value;
        }

        if (shift > @bitSizeOf(usize) - 7) return error.IntegerOverflow;
        shift += 7;
    }
}

fn validate_request(headers: []const Header) Error!Request {
    var method: ?[]const u8 = null;
    var scheme: ?[]const u8 = null;
    var authority: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var protocol: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var regular_start = headers.len;
    var saw_regular = false;

    for (headers, 0..) |header, index| {
        try validate_name(header.name);
        try validate_value(header.value);

        if (header.name[0] != ':') {
            if (!saw_regular) regular_start = index;
            saw_regular = true;
            try validate_connection_field(header);
            if (std.mem.eql(u8, header.name, "host")) {
                if (host != null) return error.DuplicateHost;
                host = header.value;
            }
            continue;
        }

        if (saw_regular) return error.PseudoHeaderAfterRegular;
        if (std.mem.eql(u8, header.name, ":method")) {
            if (method != null) return error.DuplicatePseudoHeader;
            method = header.value;
        } else if (std.mem.eql(u8, header.name, ":scheme")) {
            if (scheme != null) return error.DuplicatePseudoHeader;
            scheme = header.value;
        } else if (std.mem.eql(u8, header.name, ":authority")) {
            if (authority != null) return error.DuplicatePseudoHeader;
            authority = header.value;
        } else if (std.mem.eql(u8, header.name, ":path")) {
            if (path != null) return error.DuplicatePseudoHeader;
            path = header.value;
        } else if (std.mem.eql(u8, header.name, ":protocol")) {
            if (protocol != null) return error.DuplicatePseudoHeader;
            protocol = header.value;
        } else {
            return error.InvalidPseudoHeader;
        }
    }

    const request_method = method orelse return error.MissingMethod;
    try validate_method(request_method);
    if (authority) |request_authority| try validate_authority(request_authority);
    if (host) |request_host| {
        try validate_authority(request_host);
        if (authority) |request_authority| {
            if (!std.ascii.eqlIgnoreCase(request_authority, request_host)) {
                return error.AuthorityHostMismatch;
            }
        }
    }

    if (std.mem.eql(u8, request_method, "CONNECT")) {
        const request_authority = authority orelse return error.MissingAuthority;
        if (request_authority.len == 0) return error.InvalidAuthority;
        if (protocol) |request_protocol| {
            if (request_protocol.len == 0) return error.InvalidExtendedConnectPseudoHeaders;
            try validate_method(request_protocol);
            const request_scheme = scheme orelse
                return error.InvalidExtendedConnectPseudoHeaders;
            const request_path = path orelse
                return error.InvalidExtendedConnectPseudoHeaders;
            try validate_scheme(request_scheme);
            try validate_path(request_method, request_path);
        } else if (scheme != null or path != null) {
            return error.InvalidConnectPseudoHeaders;
        }
    } else {
        if (protocol != null) return error.InvalidExtendedConnectPseudoHeaders;
        const request_scheme = scheme orelse return error.MissingScheme;
        const request_path = path orelse return error.MissingPath;
        try validate_scheme(request_scheme);
        try validate_path(request_method, request_path);
    }

    return .{
        .headers = headers,
        .fields = headers[regular_start..],
        .method = request_method,
        .scheme = scheme,
        .authority = authority,
        .path = path,
        .protocol = protocol,
    };
}

fn validate_name(name: []const u8) Error!void {
    if (name.len == 0) return error.EmptyHeaderName;
    for (name, 0..) |byte, index| {
        if (byte >= 'A' and byte <= 'Z') return error.UppercaseHeaderName;
        if (index == 0 and byte == ':') continue;
        if (!is_token(byte)) return error.InvalidHeaderName;
    }
}

fn validate_value(value: []const u8) Error!void {
    if (value.len != 0) {
        if (value[0] == ' ' or value[0] == '\t') return error.InvalidHeaderValue;
        if (value[value.len - 1] == ' ' or value[value.len - 1] == '\t') {
            return error.InvalidHeaderValue;
        }
    }
    for (value) |byte| {
        if (byte == 0 or byte == '\r' or byte == '\n') return error.InvalidHeaderValue;
    }
}

fn validate_connection_field(header: Header) Error!void {
    const forbidden = [_][]const u8{
        "connection",
        "keep-alive",
        "proxy-connection",
        "transfer-encoding",
        "upgrade",
    };
    for (forbidden) |name| {
        if (std.mem.eql(u8, header.name, name)) return error.ConnectionSpecificHeader;
    }
    if (std.mem.eql(u8, header.name, "te") and
        !std.ascii.eqlIgnoreCase(header.value, "trailers"))
    {
        return error.InvalidTe;
    }
}

fn validate_method(method: []const u8) Error!void {
    if (method.len == 0) return error.InvalidMethod;
    for (method) |byte| {
        if (!is_token(byte)) return error.InvalidMethod;
    }
}

fn validate_scheme(scheme: []const u8) Error!void {
    if (scheme.len == 0 or !is_alpha(scheme[0])) return error.InvalidScheme;
    for (scheme[1..]) |byte| {
        if (!is_alpha(byte) and !std.ascii.isDigit(byte) and
            byte != '+' and byte != '-' and byte != '.')
        {
            return error.InvalidScheme;
        }
    }
}

fn validate_authority(authority: []const u8) Error!void {
    if (authority.len == 0) return error.InvalidAuthority;
    for (authority) |byte| {
        if (byte <= ' ' or byte == 0x7f or byte == '@' or byte == '/' or
            byte == '?' or byte == '#')
        {
            return error.InvalidAuthority;
        }
    }
}

fn validate_path(method: []const u8, path: []const u8) Error!void {
    if (path.len == 0) return error.InvalidPath;
    if (std.mem.eql(u8, method, "OPTIONS") and std.mem.eql(u8, path, "*")) return;
    if (path[0] != '/') return error.InvalidPath;
}

fn is_alpha(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

fn is_token(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn status_static_index(status: u16) ?usize {
    return switch (status) {
        200 => 8,
        204 => 9,
        206 => 10,
        304 => 11,
        400 => 12,
        404 => 13,
        500 => 14,
        else => null,
    };
}

fn find_static_exact(header: Header) ?usize {
    for (static_table, 1..) |entry, index| {
        if (std.mem.eql(u8, header.name, entry.name) and
            std.mem.eql(u8, header.value, entry.value))
        {
            return index;
        }
    }
    return null;
}

fn find_static_name(name: []const u8) ?usize {
    for (static_table, 1..) |entry, index| {
        if (std.mem.eql(u8, name, entry.name)) return index;
    }
    return null;
}

const static_table = [_]Header{
    .{ .name = ":authority", .value = "" },
    .{ .name = ":method", .value = "GET" },
    .{ .name = ":method", .value = "POST" },
    .{ .name = ":path", .value = "/" },
    .{ .name = ":path", .value = "/index.html" },
    .{ .name = ":scheme", .value = "http" },
    .{ .name = ":scheme", .value = "https" },
    .{ .name = ":status", .value = "200" },
    .{ .name = ":status", .value = "204" },
    .{ .name = ":status", .value = "206" },
    .{ .name = ":status", .value = "304" },
    .{ .name = ":status", .value = "400" },
    .{ .name = ":status", .value = "404" },
    .{ .name = ":status", .value = "500" },
    .{ .name = "accept-charset", .value = "" },
    .{ .name = "accept-encoding", .value = "gzip, deflate" },
    .{ .name = "accept-language", .value = "" },
    .{ .name = "accept-ranges", .value = "" },
    .{ .name = "accept", .value = "" },
    .{ .name = "access-control-allow-origin", .value = "" },
    .{ .name = "age", .value = "" },
    .{ .name = "allow", .value = "" },
    .{ .name = "authorization", .value = "" },
    .{ .name = "cache-control", .value = "" },
    .{ .name = "content-disposition", .value = "" },
    .{ .name = "content-encoding", .value = "" },
    .{ .name = "content-language", .value = "" },
    .{ .name = "content-length", .value = "" },
    .{ .name = "content-location", .value = "" },
    .{ .name = "content-range", .value = "" },
    .{ .name = "content-type", .value = "" },
    .{ .name = "cookie", .value = "" },
    .{ .name = "date", .value = "" },
    .{ .name = "etag", .value = "" },
    .{ .name = "expect", .value = "" },
    .{ .name = "expires", .value = "" },
    .{ .name = "from", .value = "" },
    .{ .name = "host", .value = "" },
    .{ .name = "if-match", .value = "" },
    .{ .name = "if-modified-since", .value = "" },
    .{ .name = "if-none-match", .value = "" },
    .{ .name = "if-range", .value = "" },
    .{ .name = "if-unmodified-since", .value = "" },
    .{ .name = "last-modified", .value = "" },
    .{ .name = "link", .value = "" },
    .{ .name = "location", .value = "" },
    .{ .name = "max-forwards", .value = "" },
    .{ .name = "proxy-authenticate", .value = "" },
    .{ .name = "proxy-authorization", .value = "" },
    .{ .name = "range", .value = "" },
    .{ .name = "referer", .value = "" },
    .{ .name = "refresh", .value = "" },
    .{ .name = "retry-after", .value = "" },
    .{ .name = "server", .value = "" },
    .{ .name = "set-cookie", .value = "" },
    .{ .name = "strict-transport-security", .value = "" },
    .{ .name = "transfer-encoding", .value = "" },
    .{ .name = "user-agent", .value = "" },
    .{ .name = "vary", .value = "" },
    .{ .name = "via", .value = "" },
    .{ .name = "www-authenticate", .value = "" },
};

const huffman_codes: [257]u32 = .{
    0x1ff8,     0x7fffd8,  0xfffffe2,  0xfffffe3, 0xfffffe4, 0xfffffe5,  0xfffffe6,  0xfffffe7,
    0xfffffe8,  0xffffea,  0x3ffffffc, 0xfffffe9, 0xfffffea, 0x3ffffffd, 0xfffffeb,  0xfffffec,
    0xfffffed,  0xfffffee, 0xfffffef,  0xffffff0, 0xffffff1, 0xffffff2,  0x3ffffffe, 0xffffff3,
    0xffffff4,  0xffffff5, 0xffffff6,  0xffffff7, 0xffffff8, 0xffffff9,  0xffffffa,  0xffffffb,
    0x14,       0x3f8,     0x3f9,      0xffa,     0x1ff9,    0x15,       0xf8,       0x7fa,
    0x3fa,      0x3fb,     0xf9,       0x7fb,     0xfa,      0x16,       0x17,       0x18,
    0x0,        0x1,       0x2,        0x19,      0x1a,      0x1b,       0x1c,       0x1d,
    0x1e,       0x1f,      0x5c,       0xfb,      0x7ffc,    0x20,       0xffb,      0x3fc,
    0x1ffa,     0x21,      0x5d,       0x5e,      0x5f,      0x60,       0x61,       0x62,
    0x63,       0x64,      0x65,       0x66,      0x67,      0x68,       0x69,       0x6a,
    0x6b,       0x6c,      0x6d,       0x6e,      0x6f,      0x70,       0x71,       0x72,
    0xfc,       0x73,      0xfd,       0x1ffb,    0x7fff0,   0x1ffc,     0x3ffc,     0x22,
    0x7ffd,     0x3,       0x23,       0x4,       0x24,      0x5,        0x25,       0x26,
    0x27,       0x6,       0x74,       0x75,      0x28,      0x29,       0x2a,       0x7,
    0x2b,       0x76,      0x2c,       0x8,       0x9,       0x2d,       0x77,       0x78,
    0x79,       0x7a,      0x7b,       0x7ffe,    0x7fc,     0x3ffd,     0x1ffd,     0xffffffc,
    0xfffe6,    0x3fffd2,  0xfffe7,    0xfffe8,   0x3fffd3,  0x3fffd4,   0x3fffd5,   0x7fffd9,
    0x3fffd6,   0x7fffda,  0x7fffdb,   0x7fffdc,  0x7fffdd,  0x7fffde,   0xffffeb,   0x7fffdf,
    0xffffec,   0xffffed,  0x3fffd7,   0x7fffe0,  0xffffee,  0x7fffe1,   0x7fffe2,   0x7fffe3,
    0x7fffe4,   0x1fffdc,  0x3fffd8,   0x7fffe5,  0x3fffd9,  0x7fffe6,   0x7fffe7,   0xffffef,
    0x3fffda,   0x1fffdd,  0xfffe9,    0x3fffdb,  0x3fffdc,  0x7fffe8,   0x7fffe9,   0x1fffde,
    0x7fffea,   0x3fffdd,  0x3fffde,   0xfffff0,  0x1fffdf,  0x3fffdf,   0x7fffeb,   0x7fffec,
    0x1fffe0,   0x1fffe1,  0x3fffe0,   0x1fffe2,  0x7fffed,  0x3fffe1,   0x7fffee,   0x7fffef,
    0xfffea,    0x3fffe2,  0x3fffe3,   0x3fffe4,  0x7ffff0,  0x3fffe5,   0x3fffe6,   0x7ffff1,
    0x3ffffe0,  0x3ffffe1, 0xfffeb,    0x7fff1,   0x3fffe7,  0x7ffff2,   0x3fffe8,   0x1ffffec,
    0x3ffffe2,  0x3ffffe3, 0x3ffffe4,  0x7ffffde, 0x7ffffdf, 0x3ffffe5,  0xfffff1,   0x1ffffed,
    0x7fff2,    0x1fffe3,  0x3ffffe6,  0x7ffffe0, 0x7ffffe1, 0x3ffffe7,  0x7ffffe2,  0xfffff2,
    0x1fffe4,   0x1fffe5,  0x3ffffe8,  0x3ffffe9, 0xffffffd, 0x7ffffe3,  0x7ffffe4,  0x7ffffe5,
    0xfffec,    0xfffff3,  0xfffed,    0x1fffe6,  0x3fffe9,  0x1fffe7,   0x1fffe8,   0x7ffff3,
    0x3fffea,   0x3fffeb,  0x1ffffee,  0x1ffffef, 0xfffff4,  0xfffff5,   0x3ffffea,  0x7ffff4,
    0x3ffffeb,  0x7ffffe6, 0x3ffffec,  0x3ffffed, 0x7ffffe7, 0x7ffffe8,  0x7ffffe9,  0x7ffffea,
    0x7ffffeb,  0xffffffe, 0x7ffffec,  0x7ffffed, 0x7ffffee, 0x7ffffef,  0x7fffff0,  0x3ffffee,
    0x3fffffff,
};

const huffman_lengths: [257]u8 = .{
    13, 23, 28, 28, 28, 28, 28, 28, 28, 24, 30, 28, 28, 30, 28, 28,
    28, 28, 28, 28, 28, 28, 30, 28, 28, 28, 28, 28, 28, 28, 28, 28,
    6,  10, 10, 12, 13, 6,  8,  11, 10, 10, 8,  11, 8,  6,  6,  6,
    5,  5,  5,  6,  6,  6,  6,  6,  6,  6,  7,  8,  15, 6,  12, 10,
    13, 6,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,  7,
    7,  7,  7,  7,  7,  7,  7,  7,  8,  7,  8,  13, 19, 13, 14, 6,
    15, 5,  6,  5,  6,  5,  6,  6,  6,  5,  7,  7,  6,  6,  6,  5,
    6,  7,  6,  5,  5,  6,  7,  7,  7,  7,  7,  15, 11, 14, 13, 28,
    20, 22, 20, 20, 22, 22, 22, 23, 22, 23, 23, 23, 23, 23, 24, 23,
    24, 24, 22, 23, 24, 23, 23, 23, 23, 21, 22, 23, 22, 23, 23, 24,
    22, 21, 20, 22, 22, 23, 23, 21, 23, 22, 22, 24, 21, 22, 23, 23,
    21, 21, 22, 21, 23, 22, 23, 23, 20, 22, 22, 22, 23, 22, 22, 23,
    26, 26, 20, 19, 22, 23, 22, 25, 26, 26, 26, 27, 27, 26, 24, 25,
    19, 21, 26, 27, 27, 26, 27, 24, 21, 21, 26, 26, 28, 27, 27, 27,
    20, 24, 20, 21, 22, 21, 21, 23, 22, 22, 25, 25, 24, 24, 26, 23,
    26, 27, 26, 26, 27, 27, 27, 27, 27, 28, 27, 27, 27, 27, 27, 26,
    30,
};

const invalid_huffman_node = std.math.maxInt(u16);
const invalid_huffman_symbol = std.math.maxInt(u16);
const HuffmanNode = struct {
    child: [2]u16 = .{ invalid_huffman_node, invalid_huffman_node },
    symbol: u16 = invalid_huffman_symbol,
};
const HuffmanTree = struct {
    nodes: [513]HuffmanNode,
};

fn build_huffman_tree() HuffmanTree {
    @setEvalBranchQuota(100_000);
    var tree = HuffmanTree{ .nodes = .{HuffmanNode{}} ** 513 };
    var node_len: usize = 1;

    for (huffman_codes, huffman_lengths, 0..) |code, length, symbol| {
        var node_index: usize = 0;
        var remaining: u8 = length;
        while (remaining > 0) {
            remaining -= 1;
            const shift: u5 = @intCast(remaining);
            const branch: usize = @intCast((code >> shift) & 1);
            if (tree.nodes[node_index].child[branch] == invalid_huffman_node) {
                if (node_len == tree.nodes.len) @compileError("invalid HPACK Huffman tree");
                tree.nodes[node_index].child[branch] = @intCast(node_len);
                node_len += 1;
            }
            node_index = tree.nodes[node_index].child[branch];
        }
        tree.nodes[node_index].symbol = @intCast(symbol);
    }
    return tree;
}

const huffman_tree = build_huffman_tree();

fn decode_huffman(input: []const u8, output: []u8) Error!usize {
    var output_len: usize = 0;
    var node_index: u16 = 0;
    var partial_bits: u8 = 0;
    var partial_all_ones = true;

    for (input) |byte| {
        for (0..8) |bit_index| {
            const shift: u3 = @intCast(7 - bit_index);
            const branch: usize = @intCast((byte >> shift) & 1);
            const next = huffman_tree.nodes[node_index].child[branch];
            if (next == invalid_huffman_node) return error.InvalidHuffman;

            node_index = next;
            partial_bits += 1;
            if (branch == 0) partial_all_ones = false;

            const symbol = huffman_tree.nodes[node_index].symbol;
            if (symbol == invalid_huffman_symbol) continue;
            if (symbol == 256) return error.InvalidHuffman;
            if (output_len == output.len) return error.OutputTooSmall;
            output[output_len] = @intCast(symbol);
            output_len += 1;
            node_index = 0;
            partial_bits = 0;
            partial_all_ones = true;
        }
    }

    if (node_index != 0 and (partial_bits > 7 or !partial_all_ones)) {
        return error.InvalidHuffman;
    }
    return output_len;
}
