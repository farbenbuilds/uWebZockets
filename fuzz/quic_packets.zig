const support = @import("fuzz_support");
const packet = support.quic_packet;
const webtransport = support.quic_webtransport;

const max_input_size = 64 * 1024;
const max_varints_per_input = 256;

pub fn fuzz_one(input: []const u8) void {
    if (input.len > max_input_size) return;

    // Malformed inputs end a probe normally; successful decodes must stay bounded.
    var packet_offset: usize = 0;
    var packet_count: usize = 0;
    while (packet_offset < input.len and packet_count < max_varints_per_input) : (packet_count += 1) {
        const header = packet.inspect_packet(input[packet_offset..]) catch break;
        if (header.packet_length == 0 or header.packet_length > input.len - packet_offset) {
            @panic("QUIC packet length escaped datagram boundary");
        }
        packet_offset += header.packet_length;
        if (header.kind == .short or
            header.kind == .retry or
            header.kind == .version_negotiation or
            header.kind == .unknown_long)
        {
            break;
        }
    }

    var offset: usize = 0;
    var decoded_count: usize = 0;
    while (offset < input.len and decoded_count < max_varints_per_input) : (decoded_count += 1) {
        const decoded = webtransport.decode_varint(input[offset..]) catch break;
        if (decoded.length == 0 or decoded.length > input.len - offset) {
            @panic("QUIC varint length escaped packet boundary");
        }

        var canonical: [8]u8 = undefined;
        const encoded_len = webtransport.encode_varint(decoded.value, &canonical) catch {
            @panic("decoded QUIC varint could not be encoded");
        };
        const round_trip = webtransport.decode_varint(canonical[0..encoded_len]) catch {
            @panic("encoded QUIC varint could not be decoded");
        };
        if (round_trip.value != decoded.value) @panic("QUIC varint round trip changed value");
        offset += decoded.length;
    }

    _ = webtransport.decode_unidirectional_header(input) catch {};
    _ = webtransport.decode_bidirectional_header(input) catch {};
    if (webtransport.decode_datagram(input)) |datagram| {
        if (datagram.header_length > input.len) @panic("QUIC datagram header overflow");
        if (datagram.payload.len != input.len - datagram.header_length) {
            @panic("QUIC datagram payload escaped packet boundary");
        }
    } else |_| {}
    _ = webtransport.decode_capsule(input) catch {};
}

export fn LLVMFuzzerTestOneInput(
    data: [*]const u8,
    size: usize,
) callconv(.c) c_int {
    if (size <= max_input_size) fuzz_one(data[0..size]);
    return 0;
}
