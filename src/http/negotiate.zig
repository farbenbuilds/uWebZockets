//! Accept-header content negotiation over caller-supplied offers.
//!
//! Parsing is best-effort and pure: malformed entries are dropped, entries past
//! capacity are ignored, and the fixed-capacity registry never allocates.

const std = @import("std");

/// Maximum number of parsed Accept entries kept by `parse`.
pub const max_entries = 16;

/// One parsed Accept entry; quality is per-mille 0..1000.
pub const Entry = struct {
    /// Media type compared case-insensitively; "*" matches every type.
    type: []const u8,
    /// Media subtype compared case-insensitively; "*" matches every subtype.
    subtype: []const u8,
    /// Quality in per-mille; zero explicitly rejects the range.
    quality: u16,
};

/// Fixed-capacity parsed Accept header.
pub const Accept = struct {
    entries: [max_entries]Entry = undefined,
    count: usize = 0,
};

/// Media range split into borrowed type and subtype slices.
const MediaRange = struct {
    type: []const u8,
    subtype: []const u8,
};

/// Best-effort parse: trims whitespace, drops malformed entries, ignores entries past capacity.
pub fn parse(header: []const u8) Accept {
    var accept = Accept{};
    var entries = std.mem.splitScalar(u8, header, ',');
    while (entries.next()) |raw_entry| {
        const entry = parse_entry(raw_entry) orelse continue;
        if (accept.count == max_entries) continue;
        accept.entries[accept.count] = entry;
        accept.count += 1;
    }
    return accept;
}

/// Returns 0..1000 for `media_type`; an empty Accept accepts everything.
pub fn score(accept: Accept, media_type: []const u8) u16 {
    if (accept.count == 0) return 1000;
    const offer = split_media_range(media_type) orelse return 0;

    var matched: ?Entry = null;
    var matched_specificity: u2 = 0;
    for (accept.entries[0..@min(accept.count, max_entries)]) |entry| {
        const specificity = match_specificity(entry, offer);
        if (specificity <= matched_specificity) continue;
        matched = entry;
        matched_specificity = specificity;
    }
    const entry = matched orelse return 0;
    return entry.quality;
}

/// Reports whether `media_type` is acceptable (score greater than zero).
pub fn accepts(accept: Accept, media_type: []const u8) bool {
    return score(accept, media_type) > 0;
}

/// Returns the highest-scoring offer; ties keep offer order; null when all score 0.
pub fn best(accept: Accept, offers: []const []const u8) ?[]const u8 {
    var winner: ?[]const u8 = null;
    var winning_quality: u16 = 0;
    for (offers) |offer| {
        const quality = score(accept, offer);
        if (quality <= winning_quality) continue;
        winner = offer;
        winning_quality = quality;
    }
    return winner;
}

/// Parses one comma-delimited entry, returning null when it is malformed.
fn parse_entry(raw_entry: []const u8) ?Entry {
    const entry = std.mem.trim(u8, raw_entry, " \t");
    if (entry.len == 0) return null;
    const range = split_media_range(entry) orelse return null;
    const parameters = std.mem.indexOfScalar(u8, entry, ';') orelse entry.len;
    const quality = parse_quality_parameter(entry[parameters..]) orelse return null;
    return .{ .type = range.type, .subtype = range.subtype, .quality = quality };
}

/// Splits "type/subtype" or a media range, dropping parameters and whitespace.
fn split_media_range(value: []const u8) ?MediaRange {
    const trimmed = std.mem.trim(u8, value, " \t");
    const parameters = std.mem.indexOfScalar(u8, trimmed, ';') orelse trimmed.len;
    const range = std.mem.trim(u8, trimmed[0..parameters], " \t");
    const slash = std.mem.indexOfScalar(u8, range, '/') orelse return null;
    const type_part = range[0..slash];
    const subtype_part = range[slash + 1 ..];
    if (!valid_media_token(type_part) or !valid_media_token(subtype_part)) return null;
    // "*" is only a valid wildcard as the complete type or subtype.
    if (std.mem.eql(u8, type_part, "*") and !std.mem.eql(u8, subtype_part, "*")) return null;
    return .{ .type = type_part, .subtype = subtype_part };
}

/// Match tier: 3 exact, 2 type wildcard, 1 any wildcard, 0 no match.
fn match_specificity(entry: Entry, offer: MediaRange) u2 {
    if (std.mem.eql(u8, entry.type, "*")) {
        return if (std.mem.eql(u8, entry.subtype, "*")) 1 else 0;
    }
    if (!std.ascii.eqlIgnoreCase(entry.type, offer.type)) return 0;
    if (std.mem.eql(u8, entry.subtype, "*")) return 2;
    if (std.ascii.eqlIgnoreCase(entry.subtype, offer.subtype)) return 3;
    return 0;
}

/// Scans `;`-delimited parameters for the quality weight; null drops the entry.
fn parse_quality_parameter(parameters: []const u8) ?u16 {
    var quality: u16 = 1000;
    var seen = false;
    var segments = std.mem.splitScalar(u8, parameters, ';');
    _ = segments.next();
    while (segments.next()) |raw_parameter| {
        const parameter = std.mem.trim(u8, raw_parameter, " \t");
        const equals = std.mem.indexOfScalar(u8, parameter, '=') orelse {
            if (std.ascii.eqlIgnoreCase(parameter, "q")) return null;
            continue;
        };
        const name = std.mem.trim(u8, parameter[0..equals], " \t");
        if (!std.ascii.eqlIgnoreCase(name, "q")) continue;
        if (seen) return null;
        quality = parse_quality(std.mem.trim(u8, parameter[equals + 1 ..], " \t")) orelse return null;
        seen = true;
    }
    return quality;
}

/// Parses an RFC 9110 qvalue into per-mille; null when it is malformed.
fn parse_quality(value: []const u8) ?u16 {
    if (value.len == 0) return null;
    if (value[0] == '0' and value.len == 1) return 0;
    if (value[0] == '1' and value.len == 1) return 1000;
    if (value.len < 3 or value[1] != '.') return null;

    if (value[0] == '1') {
        for (value[2..]) |digit| {
            if (digit != '0') return null;
        }
        return 1000;
    }
    if (value[0] != '0' or value.len > 5) return null;

    var per_mille: u16 = 0;
    for (value[2..]) |digit| {
        if (digit < '0' or digit > '9') return null;
        per_mille = per_mille * 10 + (digit - '0');
    }
    var digits: usize = value.len - 2;
    while (digits < 3) : (digits += 1) per_mille *= 10;
    return per_mille;
}

/// Validates one type or subtype token, allowing only the exact "*" wildcard.
fn valid_media_token(token: []const u8) bool {
    if (token.len == 0) return false;
    if (std.mem.eql(u8, token, "*")) return true;
    for (token) |byte| {
        if (byte == '*' or !is_tchar(byte)) return false;
    }
    return true;
}

/// Reports whether `byte` is an RFC 9110 token character.
fn is_tchar(byte: u8) bool {
    return switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}
