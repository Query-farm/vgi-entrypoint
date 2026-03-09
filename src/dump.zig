const std = @import("std");
const caps = @import("caps.zig");

/// Decoded capability sets from /proc/self/status.
pub const CapState = struct {
    effective: u64,
    permitted: u64,
    inheritable: u64,
    bounding: u64,
    ambient: u64,
};

/// Read and parse capability hex values from /proc/self/status.
pub fn readCapState() !CapState {
    const file = std.fs.openFileAbsolute("/proc/self/status", .{}) catch return error.CannotReadProcStatus;
    defer file.close();

    var state = CapState{
        .effective = 0,
        .permitted = 0,
        .inheritable = 0,
        .bounding = 0,
        .ambient = 0,
    };

    var buf: [8192]u8 = undefined;
    const n = file.readAll(&buf) catch return error.CannotReadProcStatus;
    const content = buf[0..n];

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (parseLine(line, "CapInh:")) |v| {
            state.inheritable = v;
        } else if (parseLine(line, "CapPrm:")) |v| {
            state.permitted = v;
        } else if (parseLine(line, "CapEff:")) |v| {
            state.effective = v;
        } else if (parseLine(line, "CapBnd:")) |v| {
            state.bounding = v;
        } else if (parseLine(line, "CapAmb:")) |v| {
            state.ambient = v;
        }
    }

    return state;
}

fn parseLine(line: []const u8, prefix: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = std.mem.trim(u8, line[prefix.len..], " \t");
    return std.fmt.parseInt(u64, rest, 16) catch null;
}

/// Print a capability bitmask as a list of names.
/// Iterates up to last_cap (from /proc/sys/kernel/cap_last_cap) to cover
/// capabilities beyond MAX_KNOWN_CAP on newer kernels.
fn printCapSet(writer: anytype, label: []const u8, mask: u64, last_cap: u8) !void {
    try writer.print("  {s}: ", .{label});
    var first = true;
    var i: u8 = 0;
    while (i <= last_cap) : (i += 1) {
        if (mask & (@as(u64, 1) << @intCast(i)) != 0) {
            if (!first) try writer.writeAll(",");
            if (caps.numberToName(i)) |name| {
                try writer.writeAll(name);
            } else {
                try writer.print("cap_{d}", .{i});
            }
            first = false;
        }
    }
    if (first) try writer.writeAll("(none)");
    try writer.writeAll("\n");
}

/// Dump full capability state to stderr.
pub fn dumpCapState(label: []const u8) void {
    var buf: [4096]u8 = undefined;
    var stderr = std.fs.File.stderr().writer(&buf);
    const w = &stderr.interface;

    const state = readCapState() catch {
        w.print("vgi-entrypoint: cannot read cap state for {s}\n", .{label}) catch {};
        stderr.interface.flush() catch {};
        return;
    };
    const last_cap = caps.readLastCap();
    w.print("vgi-entrypoint: capability state ({s}):\n", .{label}) catch {};
    printCapSet(w, "Effective  ", state.effective, last_cap) catch {};
    printCapSet(w, "Permitted  ", state.permitted, last_cap) catch {};
    printCapSet(w, "Inheritable", state.inheritable, last_cap) catch {};
    printCapSet(w, "Bounding   ", state.bounding, last_cap) catch {};
    printCapSet(w, "Ambient    ", state.ambient, last_cap) catch {};
    stderr.interface.flush() catch {};
}

test "parseLine" {
    try std.testing.expectEqual(@as(?u64, 0x00000000a80435fb), parseLine("CapBnd:\t00000000a80435fb", "CapBnd:"));
    try std.testing.expectEqual(@as(?u64, null), parseLine("Name:\tinit", "CapBnd:"));
    try std.testing.expectEqual(@as(?u64, 0), parseLine("CapAmb:\t0000000000000000", "CapAmb:"));
}
