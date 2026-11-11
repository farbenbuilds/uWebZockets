const std = @import("std");
const protocol = @import("test_support").sql_protocol;
const wire = protocol.wire;
const auth = protocol.auth;
const rows = protocol.rows;
const types = protocol.types;

test "sql wire: framing distinguishes incomplete, malformed, oversized and EOF" {
    try std.testing.expect(try wire.decode("Z\x00\x00", 100) == null);
    try std.testing.expectError(error.TruncatedMessage, wire.finish_eof("Z\x00\x00"));
    try std.testing.expectError(error.InvalidMessage, wire.decode("Z\x00\x00\x00\x03", 100));
    try std.testing.expectError(error.MessageTooLarge, wire.decode("D\x00\x00\x01\x00", 100));
    const frame = (try wire.decode("Z\x00\x00\x00\x05Iextra", 100)).?;
    try std.testing.expectEqual(@as(u8, 'Z'), frame.tag);
    try std.testing.expectEqualStrings("I", frame.payload);
    try std.testing.expectEqual(@as(usize, 6), frame.consumed);
}

test "sql wire: startup and extended binding preserve parameters as data" {
    var buffer: [1024]u8 = undefined;
    const startup_len = try wire.startup(&buffer, "alice", "app");
    try std.testing.expectEqual(@as(u32, @intCast(startup_len)), std.mem.readInt(u32, buffer[0..4], .big));
    try std.testing.expectEqualSlices(u8, &.{ 0, 3, 0, 0 }, buffer[4..8]);
    try std.testing.expect(std.mem.indexOf(u8, buffer[8..startup_len], "user\x00alice\x00database\x00app\x00") != null);
    const parse_len = try wire.parse(&buffer, .{ .name = "lookup", .sql = "select $1::text", .param_oids = &.{25} });
    try std.testing.expectEqual(@as(u8, 'P'), buffer[0]);
    try std.testing.expectEqual(@as(usize, parse_len), (try wire.decode(buffer[0..parse_len], 1024)).?.consumed);
    const injection = "'; DROP TABLE users;--";
    const bind_len = try wire.bind(&buffer, "", "lookup", &.{.{ .value = .{ .text = injection } }});
    const frame = (try wire.decode(buffer[0..bind_len], 1024)).?;
    try std.testing.expectEqual(@as(u8, 'B'), frame.tag);
    try std.testing.expect(std.mem.indexOf(u8, frame.payload, injection) != null);
    try std.testing.expectError(error.InvalidString, wire.startup(&buffer, "alice\x00other", "app"));
    try std.testing.expectError(error.BufferTooSmall, wire.bind(buffer[0..5], "", "", &.{}));
}

test "sql rows: binary fields are bounded and preserve NULL" {
    const columns = [_]types.Column{
        .{ .name = "id", .oid = 23, .format = .binary },
        .{ .name = "name", .oid = 25, .format = .binary },
        .{ .name = "missing", .oid = 25, .format = .binary },
    };
    var fields: [3]types.Field = undefined;
    const payload = "\x00\x03\x00\x00\x00\x04\x00\x00\x00\x2a\x00\x00\x00\x03zig\xff\xff\xff\xff";
    const row = try rows.decode_row(payload, &columns, &fields, .{});
    try std.testing.expectEqual(@as(i32, 42), try row.get(i32, 0));
    try std.testing.expectEqualStrings("zig", try row.get([]const u8, 1));
    try std.testing.expectEqual(types.Value.null, try row.value(2));
    try std.testing.expectError(error.NullValue, row.get([]const u8, 2));
    try std.testing.expectError(error.TypeMismatch, row.get(bool, 0));
    var kept_fields: [3]types.Field = undefined;
    var kept_bytes: [7]u8 = undefined;
    const kept = try row.keep(&kept_fields, &kept_bytes);
    try std.testing.expectEqual(@as(i32, 42), try kept.get(i32, 0));
    try std.testing.expectEqualStrings("zig", try kept.get([]const u8, 1));
    try std.testing.expectError(error.TruncatedMessage, rows.decode_row(payload[0 .. payload.len - 1], &columns, &fields, .{}));
    try std.testing.expectError(error.FieldTooLarge, rows.decode_row(payload, &columns, &fields, .{ .max_field_bytes = 2 }));
}

test "sql authentication: SCRAM SHA256 RFC7677 vector verifies server identity" {
    var state = try auth.Scram.init("user", "rOprNGfwEbeRWgbNEkqO");
    defer state.deinit();
    var buffer: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("n,,n=user,r=rOprNGfwEbeRWgbNEkqO", try state.client_first(&buffer));
    const response = try state.respond("pencil", "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", &buffer);
    try std.testing.expectEqualStrings("c=biws,r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,p=dHzbZapWIk4jUhN+Ute9ytag9zjfMHgsqmmiz7AndVQ=", response);
    try state.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=");
}

test "sql authentication: hostile SCRAM challenge fails closed" {
    var state = try auth.Scram.init("user", "nonce");
    defer state.deinit();
    var buffer: [2048]u8 = undefined;
    try std.testing.expectError(error.AuthenticationFailed, state.respond("pass", "r=other,s=YQ==,i=4096", &buffer));
    try std.testing.expectError(error.AuthenticationFailed, state.respond("pass", "r=noncex,s=YQ==,i=999999999", &buffer));
    try std.testing.expectError(error.AuthenticationFailed, state.respond("pass", "r=noncex,r=noncex,s=YQ==,i=4096", &buffer));
}

test "sql wire: SSL cancellation SASL and control messages match protocol3 layouts" {
    var buffer: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), try wire.ssl_request(&buffer));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 8, 4, 210, 22, 47 }, buffer[0..8]);
    try std.testing.expectEqual(@as(usize, 16), try wire.cancel(&buffer, 42, 99));
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 16, 4, 210, 22, 46, 0, 0, 0, 42, 0, 0, 0, 99 }, buffer[0..16]);
    const password_len = try wire.password(&buffer, "md5password\x00");
    const password_frame = (try wire.decode(buffer[0..password_len], 256)).?;
    try std.testing.expectEqualStrings("md5password\x00", password_frame.payload);
    const sasl_len = try wire.sasl_initial(&buffer, "SCRAM-SHA-256", "n,,n=user,r=nonce");
    const sasl_frame = (try wire.decode(buffer[0..sasl_len], 256)).?;
    try std.testing.expectEqual(@as(u8, 'p'), sasl_frame.tag);
    try std.testing.expectEqualStrings("SCRAM-SHA-256\x00\x00\x00\x00\x11n,,n=user,r=nonce", sasl_frame.payload);
    const describe_len = try wire.describe(&buffer, .portal, "");
    try std.testing.expectEqualSlices(u8, "D\x00\x00\x00\x06P\x00", buffer[0..describe_len]);
    const execute_len = try wire.execute(&buffer, "", 2);
    try std.testing.expectEqualSlices(u8, "E\x00\x00\x00\x09\x00\x00\x00\x00\x02", buffer[0..execute_len]);
    const close_len = try wire.close(&buffer, .statement, "s0");
    try std.testing.expectEqualSlices(u8, "C\x00\x00\x00\x08Ss0\x00", buffer[0..close_len]);
    const sync_len = try wire.sync(&buffer);
    try std.testing.expectEqualSlices(u8, "S\x00\x00\x00\x04", buffer[0..sync_len]);
    try wire.finish_eof(buffer[0..sync_len]);
}

test "sql authentication: MD5 protocol challenge matches independent digest vector" {
    var output: [36]u8 = undefined;
    auth.md5_password(&output, "secret", "bob", .{ 1, 2, 3, 4 });
    try std.testing.expectEqualStrings("md5f21dfe33ff3a9e03dbc3e008251fe5cc\x00", &output);
}

test "sql rows: all binary value types round trip through parameter framing" {
    const values = [_]types.Value{
        .null,
        .{ .bool = true },
        .{ .int2 = -1234 },
        .{ .int4 = -2147483648 },
        .{ .int8 = -9223372036854775807 },
        .{ .float4 = 1.25 },
        .{ .float8 = -5.5 },
        .{ .text = "hello" },
        .{ .varchar = "world" },
        .{ .bytea = "\x00\xff\x01" },
        .{ .timestamp = .{ .microseconds = -1234567890 } },
        .{ .date = .{ .days = -365 } },
        .{ .uuid = .{ .bytes = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 } } },
        .{ .numeric = .{ .digits = "\x00\x0c\x0d\x80", .weight = 1, .scale = 2, .sign = .negative } },
    };
    var parameters: [values.len]types.Param = undefined;
    var columns: [values.len]types.Column = undefined;
    for (values, 0..) |value, index| {
        parameters[index] = .{ .value = value };
        columns[index] = .{ .name = "field", .oid = types.value_oid(value) };
    }
    var buffer: [2048]u8 = undefined;
    const length = try wire.bind(&buffer, "", "", &parameters);
    const frame = (try wire.decode(buffer[0..length], buffer.len)).?;
    // Empty portal/name and one binary format precede the DataRow-compatible count/values.
    const payload = frame.payload[6 .. frame.payload.len - 4];
    var fields: [values.len]types.Field = undefined;
    const row = try rows.decode_row(payload, &columns, &fields, .{});
    try std.testing.expectEqual(types.Value.null, try row.value(0));
    try std.testing.expectEqual(true, try row.get(bool, 1));
    try std.testing.expectEqual(@as(i16, -1234), try row.get(i16, 2));
    try std.testing.expectEqual(@as(i32, -2147483648), try row.get(i32, 3));
    try std.testing.expectEqual(@as(i64, -9223372036854775807), try row.get(i64, 4));
    try std.testing.expectEqual(@as(f32, 1.25), try row.get(f32, 5));
    try std.testing.expectEqual(@as(f64, -5.5), try row.get(f64, 6));
    try std.testing.expectEqualStrings("hello", try row.get([]const u8, 7));
    try std.testing.expectEqualStrings("world", try row.get([]const u8, 8));
    try std.testing.expectEqualStrings("\x00\xff\x01", try row.get([]const u8, 9));
    try std.testing.expectEqual(@as(i64, -1234567890), (try row.get(types.Timestamp, 10)).microseconds);
    try std.testing.expectEqual(@as(i32, -365), (try row.get(types.Date, 11)).days);
    try std.testing.expectEqual(values[12].uuid, try row.get(types.Uuid, 12));
    const numeric = try row.get(types.Numeric, 13);
    try std.testing.expectEqualStrings(values[13].numeric.digits, numeric.digits);
    try std.testing.expectEqual(@as(i16, 1), numeric.weight);
    try std.testing.expectEqual(@as(u16, 2), numeric.scale);
    try std.testing.expectEqual(types.NumericSign.negative, numeric.sign);
}

test "sql rows: malformed scalar widths and numeric digits fail closed" {
    try std.testing.expectError(error.InvalidValue, rows.decode_value(.{ .oid = 16, .bytes = "\x02" }));
    try std.testing.expectError(error.InvalidValue, rows.decode_value(.{ .oid = 23, .bytes = "\x00" }));
    try std.testing.expectError(error.InvalidValue, rows.decode_value(.{ .oid = 2950, .bytes = "short" }));
    try std.testing.expectError(error.InvalidValue, rows.decode_value(.{ .oid = 1700, .bytes = "\x00\x01\x00\x00\x00\x00\x00\x00\x27\x10" }));
    try std.testing.expectError(error.InvalidValue, rows.decode_value(.{ .oid = 1700, .bytes = "\xff\xff\x00\x00\x00\x00\x00\x00" }));
    try std.testing.expectError(error.InvalidValue, rows.decode_value(.{ .oid = 1700, .bytes = "\x00\x00\x00\x00\xc1\x00\x00\x00" }));
    try std.testing.expectError(error.InvalidValue, rows.decode_value(.{ .oid = 25, .bytes = "\xff" }));
    try std.testing.expectError(error.UnsupportedType, rows.decode_value(.{ .oid = 9999, .bytes = "x" }));
}

test "sql rows: row descriptions reject missing names invalid formats and extra bytes" {
    const description = "\x00\x01id\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x17\x00\x04\xff\xff\xff\xff\x00\x01";
    var columns: [2]types.Column = undefined;
    const decoded = try rows.decode_columns(description, &columns, .{});
    try std.testing.expectEqual(@as(usize, 1), decoded.len);
    try std.testing.expectEqualStrings("id", decoded[0].name);
    try std.testing.expectEqual(@as(u32, 23), decoded[0].oid);
    try std.testing.expectEqual(types.Format.binary, decoded[0].format);
    try std.testing.expectError(error.TooManyColumns, rows.decode_columns(description, columns[0..0], .{}));
    try std.testing.expectError(error.TruncatedMessage, rows.decode_columns(description[0 .. description.len - 1], &columns, .{}));
    var invalid: [description.len]u8 = description.*;
    invalid[invalid.len - 1] = 2;
    try std.testing.expectError(error.InvalidMessage, rows.decode_columns(&invalid, &columns, .{}));
    try std.testing.expectError(error.TypeMismatch, rows.validate_mapping(&.{.{ .name = "other", .oid = 23 }}, decoded));
}

test "sql rows: iterator enforces row and total-response bounds without allocation" {
    const frame = "D\x00\x00\x00\x0e\x00\x01\x00\x00\x00\x04\x00\x00\x00\x2a";
    const columns = [_]types.Column{.{ .name = "id", .oid = 23 }};
    var fields: [1]types.Field = undefined;
    var iterator = rows.Rows{ .data = frame ++ frame, .columns = &columns, .fields = &fields, .limits = .{ .max_rows = 1 } };
    try std.testing.expectEqual(@as(i32, 42), try (try iterator.next()).?.get(i32, 0));
    try std.testing.expectError(error.TooManyRows, iterator.next());
    iterator.reset();
    iterator.limits.max_response_bytes = 1;
    try std.testing.expectError(error.ResponseTooLarge, iterator.next());
}

test "sql authentication: credentials and server proof obey state and bounds" {
    var state = try auth.Scram.init("a,b=c", "nonce");
    defer state.deinit();
    var buffer: [2048]u8 = undefined;
    try std.testing.expectEqualStrings("n,,n=a=2Cb=3Dc,r=nonce", try state.client_first(&buffer));
    try std.testing.expectError(error.AuthenticationFailed, state.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4="));
    try std.testing.expectError(error.AuthenticationFailed, state.respond("pass", "r=noncex,s=YQ==,i=0", &buffer));
    try std.testing.expectError(error.AuthenticationFailed, state.respond("pass", "r=noncex,s=@@@@,i=4096", &buffer));
    try std.testing.expectError(error.UnsupportedAuthentication, state.respond("pass", "m=required,r=noncex,s=YQ==,i=4096", &buffer));
    _ = try state.respond("pass", "r=noncex,s=YQ==,i=4096", &buffer);
    try std.testing.expectError(error.AuthenticationFailed, state.verify("v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    try std.testing.expectError(error.AuthenticationFailed, state.respond("pass", "r=noncex,s=YQ==,i=4096", &buffer));
}

test "sql authentication: SASLprep RFC4013 examples mapping normalization and bidi" {
    var output: [256]u8 = undefined;
    var scratch: [256]u21 = undefined;
    try std.testing.expectEqualStrings("IX", try protocol.saslprep.prepare("I\u{00ad}X", &output, &scratch));
    try std.testing.expectEqualStrings("user", try protocol.saslprep.prepare("user", &output, &scratch));
    try std.testing.expectEqualStrings("USER", try protocol.saslprep.prepare("USER", &output, &scratch));
    try std.testing.expectEqualStrings("a", try protocol.saslprep.prepare("\u{00aa}", &output, &scratch));
    try std.testing.expectEqualStrings("IX", try protocol.saslprep.prepare("\u{2168}", &output, &scratch));
    try std.testing.expectEqualStrings("a b", try protocol.saslprep.prepare("a\u{00a0}b", &output, &scratch));
    try std.testing.expectEqualStrings("\u{00e9}", try protocol.saslprep.prepare("e\u{0301}", &output, &scratch));
    try std.testing.expectEqualStrings("\u{ac01}", try protocol.saslprep.prepare("\u{1100}\u{1161}\u{11a8}", &output, &scratch));
    try std.testing.expectError(error.InvalidValue, protocol.saslprep.prepare("\u{0007}", &output, &scratch));
    try std.testing.expectError(error.InvalidValue, protocol.saslprep.prepare("\u{0627}\u{0031}", &output, &scratch));
    try std.testing.expectError(error.InvalidValue, protocol.saslprep.prepare("\u{0221}", &output, &scratch));
    try std.testing.expectError(error.InvalidValue, protocol.saslprep.prepare("\xff", &output, &scratch));
    try std.testing.expectError(error.BufferTooSmall, protocol.saslprep.prepare("\u{2168}", output[0..1], &scratch));
}

test "sql authentication: PostgreSQL Unicode normalized and raw-fallback passwords agree" {
    const challenge = "r=noncex,s=YQ==,i=4096";
    var normalized = try auth.Scram.init("user", "nonce");
    defer normalized.deinit();
    var plain = try auth.Scram.init("user", "nonce");
    defer plain.deinit();
    var output_a: [1024]u8 = undefined;
    var output_b: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(try plain.respond("IX", challenge, &output_a), try normalized.respond("I\u{00ad}X", challenge, &output_b));
    var fallback = try auth.Scram.init("user", "nonce");
    defer fallback.deinit();
    var raw = try auth.Scram.init("user", "nonce");
    defer raw.deinit();
    try std.testing.expectEqualStrings(try raw.respond_prepared("\xff", challenge, &output_a), try fallback.respond("\xff", challenge, &output_b));
}

test "sql authentication: password and normalization exhaustion return bounded errors" {
    var state = try auth.Scram.init("user", "nonce");
    defer state.deinit();
    var output: [2048]u8 = undefined;
    const long_password = [_]u8{'x'} ** 1025;
    try std.testing.expectError(error.AuthenticationFailed, state.respond(&long_password, "r=noncex,s=YQ==,i=4096", &output));
    const expanding = "\u{fdfa}" ** 300;
    try std.testing.expectError(error.BufferTooSmall, state.respond(expanding, "r=noncex,s=YQ==,i=4096", &output));
    var normalized: [256]u8 = undefined;
    var scratch: [256]u21 = undefined;
    try std.testing.expectEqualStrings("\u{00e0}\u{0315}", try protocol.saslprep.prepare("a\u{0315}\u{0300}", &normalized, &scratch));
    try std.testing.expectEqualStrings("\u{0308}\u{0301}", try protocol.saslprep.prepare("\u{0344}", &normalized, &scratch));
    try std.testing.expectEqualStrings("\u{01fa}", try protocol.saslprep.prepare("\u{00c5}\u{0301}", &normalized, &scratch));
}

test "sql authentication: long-key SCRAM matches independent Python PBKDF2 HMAC oracle" {
    var state = try auth.Scram.init("user", "nonce");
    defer state.deinit();
    var output: [1024]u8 = undefined;
    const password = [_]u8{'A'} ** 128;
    const response = try state.respond(&password, "r=noncex,s=YQ==,i=4096", &output);
    try std.testing.expectEqualStrings("c=biws,r=noncex,p=T1Kx7esXZVegouuEM6qV3WxUXH+YwnfMb59D9a++XV4=", response);
    try state.verify("v=6oCgqrfqM8OprKuEVeqqVXnmQvv3U0GV66MsmEwL9VQ=");
}

test "sql authentication: optional server-first extensions remain in the authenticated transcript" {
    var state = try auth.Scram.init("user", "nonce");
    defer state.deinit();
    var output: [1024]u8 = undefined;
    const response = try state.respond("pencil", "r=noncex,s=YQ==,i=4096,x=value", &output);
    try std.testing.expectEqualStrings("c=biws,r=noncex,p=sJSakSIsxWPa+0gxVUSW3djoZBgwQUMcfpKPeXWbomY=", response);
    try state.verify("v=yfdz8mfKnMgvdDby7mqxhbsJPsyRTG/lUoPvqUScHtw=,x=value");
}

test "sql authentication: optional final extensions preserve verifier validation" {
    var state = try auth.Scram.init("user", "rOprNGfwEbeRWgbNEkqO");
    defer state.deinit();
    var output: [1024]u8 = undefined;
    _ = try state.respond("pencil", "r=rOprNGfwEbeRWgbNEkqO%hvYDpWUa2RaTCAfuxFIlj)hNlF$k0,s=W22ZaJ0SNY7soEsUEjb6gQ==,i=4096", &output);
    try std.testing.expectError(error.AuthenticationFailed, state.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=,v=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="));
    try std.testing.expectError(error.UnsupportedAuthentication, state.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=,m=required"));
    try std.testing.expectError(error.AuthenticationFailed, state.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=,1=invalid"));
    try state.verify("v=6rriTRBi23WpRR/wtup+mMhUZUn/dB5nLTJRsjl95G4=,x=value,y=\u{00e9}");
}

test "sql authentication: PostgreSQL rejects mapped prohibited characters before normalization" {
    const challenge = "r=noncex,s=YQ==,i=4096";
    var actual = try auth.Scram.init("user", "nonce");
    defer actual.deinit();
    var expected = try auth.Scram.init("user", "nonce");
    defer expected.deinit();
    var output_a: [1024]u8 = undefined;
    var output_b: [1024]u8 = undefined;
    const raw_password = "x\u{0340}";
    try std.testing.expectEqualStrings(try expected.respond_prepared(raw_password, challenge, &output_a), try actual.respond(raw_password, challenge, &output_b));
}

test "sql authentication: PostgreSQL SASLprep preserves mapped-input validation policy" {
    var output: [256]u8 = undefined;
    var scratch: [256]u21 = undefined;
    try std.testing.expectEqualStrings("x\u{0300}", try protocol.saslprep.prepare("x\u{0340}", &output, &scratch));
    try std.testing.expectError(error.InvalidValue, protocol.saslprep.prepare_postgres("x\u{0340}", &output, &scratch));
    try std.testing.expectEqualStrings("\u{0627} \u{064b}", try protocol.saslprep.prepare_postgres("\u{0627}\u{fe70}", &output, &scratch));
    try std.testing.expectError(error.InvalidValue, protocol.saslprep.prepare("\u{0627}\u{fe70}", &output, &scratch));
}

test "sql authentication: PostgreSQL applies Unicode4 corrections while RFC4013 stays pinned" {
    const inputs = [_]u21{ 0x2f868, 0x2f874, 0x2f91f, 0x2f95f, 0x2f9bf };
    const corrected = [_]u21{ 0x36fc, 0x5f53, 0x243ab, 0x7aee, 0x45d7 };
    const legacy = [_]u21{ 0x2136a, 0x5f33, 0x43ab, 0x7aae, 0x4d57 };
    var output: [256]u8 = undefined;
    var scratch: [256]u21 = undefined;
    var input_utf8: [4]u8 = undefined;
    var expected_utf8: [4]u8 = undefined;
    for (inputs, corrected, legacy) |input, current, old| {
        const input_len = try std.unicode.utf8Encode(input, &input_utf8);
        const expected_len = try std.unicode.utf8Encode(current, &expected_utf8);
        try std.testing.expectEqualStrings(expected_utf8[0..expected_len], try protocol.saslprep.prepare_postgres(input_utf8[0..input_len], &output, &scratch));
        const legacy_len = try std.unicode.utf8Encode(old, &expected_utf8);
        try std.testing.expectEqualStrings(expected_utf8[0..legacy_len], try protocol.saslprep.prepare(input_utf8[0..input_len], &output, &scratch));
    }
}
