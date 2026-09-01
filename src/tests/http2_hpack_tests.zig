const std = @import("std");
const hpack = @import("test_support").http2_hpack;

fn decoder_storage() struct {
    entries: [8]hpack.DynamicEntry,
    dynamic_bytes: [256]u8,
    headers: [16]hpack.Header,
    header_bytes: [1024]u8,
} {
    return undefined;
}

test "http2 hpack: RFC request vector decodes with bounded Huffman storage" {
    var storage = decoder_storage();
    var table = try hpack.DynamicTable.init(&storage.entries, &storage.dynamic_bytes, 256);
    var decoder = hpack.Decoder.init(&table, 1024);
    const block = [_]u8{
        0x82, 0x86, 0x84, 0x41, 0x8c, 0xf1, 0xe3, 0xc2, 0xe5,
        0xf2, 0x3a, 0x6b, 0xa0, 0xab, 0x90, 0xf4, 0xff,
    };

    const request = try decoder.decode_request(
        &block,
        &storage.headers,
        &storage.header_bytes,
    );
    try std.testing.expectEqualStrings("GET", request.method);
    try std.testing.expectEqualStrings("http", request.scheme.?);
    try std.testing.expectEqualStrings("/", request.path.?);
    try std.testing.expectEqualStrings("www.example.com", request.authority.?);
    try std.testing.expectEqual(@as(usize, 1), table.count());

    const indexed_dynamic = [_]u8{ 0x82, 0x86, 0x84, 0xbe };
    const repeated = try decoder.decode_request(
        &indexed_dynamic,
        &storage.headers,
        &storage.header_bytes,
    );
    try std.testing.expectEqualStrings("www.example.com", repeated.authority.?);
}

test "http2 hpack: malformed Huffman padding fails closed" {
    var entries: [0]hpack.DynamicEntry = .{};
    var dynamic_bytes: [0]u8 = .{};
    var table = try hpack.DynamicTable.init(&entries, &dynamic_bytes, 0);
    var decoder = hpack.Decoder.init(&table, 1024);
    var headers: [8]hpack.Header = undefined;
    var header_bytes: [256]u8 = undefined;
    const invalid = [_]u8{ 0x82, 0x86, 0x84, 0x01, 0x81, 0xff };

    try std.testing.expectError(
        error.InvalidHuffman,
        decoder.decode_request(&invalid, &headers, &header_bytes),
    );
}

test "http2 hpack: connection-specific fields and list overflow are rejected" {
    var entries: [0]hpack.DynamicEntry = .{};
    var dynamic_bytes: [0]u8 = .{};
    var table = try hpack.DynamicTable.init(&entries, &dynamic_bytes, 0);
    var decoder = hpack.Decoder.init(&table, 1024);
    var headers: [8]hpack.Header = undefined;
    var header_bytes: [256]u8 = undefined;
    const forbidden = [_]u8{ 0x82, 0x86, 0x84, 0xb9 };
    try std.testing.expectError(
        error.ConnectionSpecificHeader,
        decoder.decode_request(&forbidden, &headers, &header_bytes),
    );

    decoder.max_header_list_size = 32;
    const valid_minimal = [_]u8{ 0x82, 0x86, 0x84 };
    try std.testing.expectError(
        error.HeaderListTooLarge,
        decoder.decode_request(&valid_minimal, &headers, &header_bytes),
    );
}

test "http2 hpack: Host and authority must be unambiguous" {
    var entries: [0]hpack.DynamicEntry = .{};
    var dynamic_bytes: [0]u8 = .{};
    var table = try hpack.DynamicTable.init(&entries, &dynamic_bytes, 0);
    var decoder = hpack.Decoder.init(&table, 1024);
    var headers: [16]hpack.Header = undefined;
    var header_bytes: [512]u8 = undefined;
    const duplicate_host = [_]u8{
        0x82, 0x86, 0x84,
        0x00, 0x04, 'h',
        'o',  's',  't',
        0x0b, 'e',  'x',
        'a',  'm',  'p',
        'l',  'e',  '.',
        'c',  'o',  'm',
        0x00, 0x04, 'h',
        'o',  's',  't',
        0x0b, 'e',  'x',
        'a',  'm',  'p',
        'l',  'e',  '.',
        'c',  'o',  'm',
    };
    try std.testing.expectError(
        error.DuplicateHost,
        decoder.decode_request(&duplicate_host, &headers, &header_bytes),
    );

    const mismatched = [_]u8{
        0x82, 0x86, 0x01, 0x0b,
        'e',  'x',  'a',  'm',
        'p',  'l',  'e',  '.',
        'c',  'o',  'm',  0x84,
        0x00, 0x04, 'h',  'o',
        's',  't',  0x0b, 'e',
        'x',  'a',  'm',  'p',
        'l',  'e',  '.',  'n',
        'e',  't',
    };
    try std.testing.expectError(
        error.AuthorityHostMismatch,
        decoder.decode_request(&mismatched, &headers, &header_bytes),
    );

    const matching = [_]u8{
        0x82, 0x86, 0x01, 0x0b,
        'E',  'x',  'a',  'm',
        'p',  'l',  'e',  '.',
        'c',  'o',  'm',  0x84,
        0x00, 0x04, 'h',  'o',
        's',  't',  0x0b, 'e',
        'x',  'a',  'm',  'p',
        'l',  'e',  '.',  'c',
        'o',  'm',
    };
    const request = try decoder.decode_request(&matching, &headers, &header_bytes);
    try std.testing.expectEqualStrings("Example.com", request.authority.?);
}

test "http2 hpack: response encoder uses bounded static-name literals" {
    const headers = [_]hpack.Header{
        .{ .name = "content-type", .value = "text/plain" },
        .{ .name = "set-cookie", .value = "session=bounded" },
    };
    var output: [128]u8 = undefined;
    const encoded = try hpack.encode_response(200, &headers, &output);
    try std.testing.expectEqual(@as(u8, 0x88), encoded[0]);
    try std.testing.expect(encoded.len > headers[0].value.len + headers[1].value.len);

    var short: [1]u8 = undefined;
    try std.testing.expectError(
        error.OutputTooSmall,
        hpack.encode_response(200, &headers, &short),
    );

    const forbidden = [_]hpack.Header{
        .{ .name = "te", .value = "trailers" },
    };
    try std.testing.expectError(
        error.ConnectionSpecificHeader,
        hpack.encode_response(200, &forbidden, &output),
    );
}

test "http2 hpack: dynamic table sizing is explicit and bounded" {
    var entries: [1]hpack.DynamicEntry = undefined;
    var storage: [32]u8 = undefined;
    try std.testing.expectError(
        error.DynamicTableStorageTooSmall,
        hpack.DynamicTable.init(&entries, &storage, 64),
    );

    var empty_entries: [0]hpack.DynamicEntry = .{};
    var empty_storage: [0]u8 = .{};
    const disabled = try hpack.DynamicTable.init(&empty_entries, &empty_storage, 0);
    try std.testing.expectEqual(@as(usize, 0), disabled.maximum_size());
}

test "http2 hpack: extended CONNECT validates protocol scheme and path" {
    var entries: [0]hpack.DynamicEntry = .{};
    var dynamic_bytes: [0]u8 = .{};
    var table = try hpack.DynamicTable.init(&entries, &dynamic_bytes, 0);
    var decoder = hpack.Decoder.init(&table, 2048);
    var headers: [16]hpack.Header = undefined;
    var header_bytes: [512]u8 = undefined;
    const extended_connect = [_]u8{
        0x02, 0x07, 'C',  'O',  'N',  'N',  'E', 'C', 'T',
        0x00, 0x09, ':',  'p',  'r',  'o',  't', 'o', 'c',
        'o',  'l',  0x09, 'w',  'e',  'b',  's', 'o', 'c',
        'k',  'e',  't',  0x87, 0x01, 0x0b, 'e', 'x', 'a',
        'm',  'p',  'l',  'e',  '.',  'c',  'o', 'm', 0x84,
    };
    const request = try decoder.decode_request(
        &extended_connect,
        &headers,
        &header_bytes,
    );
    try std.testing.expectEqualStrings("CONNECT", request.method);
    try std.testing.expectEqualStrings("websocket", request.protocol.?);
    try std.testing.expectEqualStrings("https", request.scheme.?);
    try std.testing.expectEqualStrings("/", request.path.?);

    const invalid = [_]u8{
        0x82,
        0x00,
        0x09,
        ':',
        'p',
        'r',
        'o',
        't',
        'o',
        'c',
        'o',
        'l',
        0x03,
        'w',
        'e',
        'b',
        0x86,
        0x84,
    };
    try std.testing.expectError(
        error.InvalidExtendedConnectPseudoHeaders,
        decoder.decode_request(&invalid, &headers, &header_bytes),
    );
}
