const std = @import("std");

pub fn utcTimestamp() i64 {
    return std.time.timestamp();
}
