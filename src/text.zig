const std = @import("std");
const Allocator = std.mem.Allocator;

const replacement = "\u{FFFD}";

/// Returns `bytes` unchanged when it is valid UTF-8; otherwise a copy with
/// each invalid byte replaced by U+FFFD.
pub fn sanitizeUtf8(arena: Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const len: usize = std.unicode.utf8ByteSequenceLength(bytes[i]) catch 0;
        if (len > 0 and i + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i..][0..len])) {
            try out.appendSlice(arena, bytes[i..][0..len]);
            i += len;
        } else {
            try out.appendSlice(arena, replacement);
            i += 1;
        }
    }
    return out.items;
}

pub const Truncated = struct { text: []const u8, truncated: bool };

/// Cuts `s` at or below `cap` bytes on a UTF-8 codepoint boundary.
pub fn truncate(s: []const u8, cap: usize) Truncated {
    if (s.len <= cap) return .{ .text = s, .truncated = false };
    var end = cap;
    while (end > 0 and (s[end] & 0xC0) == 0x80) end -= 1;
    return .{ .text = s[0..end], .truncated = true };
}

const expect = std.testing.expect;
const expectEqualStrings = std.testing.expectEqualStrings;

test "sanitizeUtf8 passes valid through and replaces invalid" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try expectEqualStrings("héllo", try sanitizeUtf8(a, "héllo"));
    try expectEqualStrings("a\u{FFFD}b", try sanitizeUtf8(a, "a\xffb"));
    try expect(std.unicode.utf8ValidateSlice(try sanitizeUtf8(a, "\xe9t\xe9")));
    try expectEqualStrings("\u{FFFD}t\u{FFFD}", try sanitizeUtf8(a, "\xe9t\xe9"));
}

test "truncate stops on a codepoint boundary" {
    const r = truncate("aé", 2); // 'é' is 2 bytes
    try expectEqualStrings("a", r.text);
    try expect(r.truncated);
    try expect(!truncate("abc", 10).truncated);
    try expectEqualStrings("aé", truncate("aé", 3).text);
    try expect(!truncate("aé", 3).truncated);
}
