const std = @import("std");
const linux = std.os.linux;

// ── Capability constants ────────────────────────────────────────────────
pub const CAP_CHOWN = 0;
pub const CAP_DAC_OVERRIDE = 1;
pub const CAP_DAC_READ_SEARCH = 2;
pub const CAP_FOWNER = 3;
pub const CAP_FSETID = 4;
pub const CAP_KILL = 5;
pub const CAP_SETGID = 6;
pub const CAP_SETUID = 7;
pub const CAP_SETPCAP = 8;
pub const CAP_LINUX_IMMUTABLE = 9;
pub const CAP_NET_BIND_SERVICE = 10;
pub const CAP_NET_BROADCAST = 11;
pub const CAP_NET_ADMIN = 12;
pub const CAP_NET_RAW = 13;
pub const CAP_IPC_LOCK = 14;
pub const CAP_IPC_OWNER = 15;
pub const CAP_SYS_MODULE = 16;
pub const CAP_SYS_RAWIO = 17;
pub const CAP_SYS_CHROOT = 18;
pub const CAP_SYS_PTRACE = 19;
pub const CAP_SYS_PACCT = 20;
pub const CAP_SYS_ADMIN = 21;
pub const CAP_SYS_BOOT = 22;
pub const CAP_SYS_NICE = 23;
pub const CAP_SYS_RESOURCE = 24;
pub const CAP_SYS_TIME = 25;
pub const CAP_SYS_TTY_CONFIG = 26;
pub const CAP_MKNOD = 27;
pub const CAP_LEASE = 28;
pub const CAP_AUDIT_WRITE = 29;
pub const CAP_AUDIT_CONTROL = 30;
pub const CAP_SETFCAP = 31;
pub const CAP_MAC_OVERRIDE = 32;
pub const CAP_MAC_ADMIN = 33;
pub const CAP_SYSLOG = 34;
pub const CAP_WAKE_ALARM = 35;
pub const CAP_BLOCK_SUSPEND = 36;
pub const CAP_AUDIT_READ = 37;
pub const CAP_PERFMON = 38;
pub const CAP_BPF = 39;
pub const CAP_CHECKPOINT_RESTORE = 40;

pub const MAX_KNOWN_CAP = 40;

const cap_names = [_]struct { name: []const u8, num: u8 }{
    .{ .name = "cap_chown", .num = CAP_CHOWN },
    .{ .name = "cap_dac_override", .num = CAP_DAC_OVERRIDE },
    .{ .name = "cap_dac_read_search", .num = CAP_DAC_READ_SEARCH },
    .{ .name = "cap_fowner", .num = CAP_FOWNER },
    .{ .name = "cap_fsetid", .num = CAP_FSETID },
    .{ .name = "cap_kill", .num = CAP_KILL },
    .{ .name = "cap_setgid", .num = CAP_SETGID },
    .{ .name = "cap_setuid", .num = CAP_SETUID },
    .{ .name = "cap_setpcap", .num = CAP_SETPCAP },
    .{ .name = "cap_linux_immutable", .num = CAP_LINUX_IMMUTABLE },
    .{ .name = "cap_net_bind_service", .num = CAP_NET_BIND_SERVICE },
    .{ .name = "cap_net_broadcast", .num = CAP_NET_BROADCAST },
    .{ .name = "cap_net_admin", .num = CAP_NET_ADMIN },
    .{ .name = "cap_net_raw", .num = CAP_NET_RAW },
    .{ .name = "cap_ipc_lock", .num = CAP_IPC_LOCK },
    .{ .name = "cap_ipc_owner", .num = CAP_IPC_OWNER },
    .{ .name = "cap_sys_module", .num = CAP_SYS_MODULE },
    .{ .name = "cap_sys_rawio", .num = CAP_SYS_RAWIO },
    .{ .name = "cap_sys_chroot", .num = CAP_SYS_CHROOT },
    .{ .name = "cap_sys_ptrace", .num = CAP_SYS_PTRACE },
    .{ .name = "cap_sys_pacct", .num = CAP_SYS_PACCT },
    .{ .name = "cap_sys_admin", .num = CAP_SYS_ADMIN },
    .{ .name = "cap_sys_boot", .num = CAP_SYS_BOOT },
    .{ .name = "cap_sys_nice", .num = CAP_SYS_NICE },
    .{ .name = "cap_sys_resource", .num = CAP_SYS_RESOURCE },
    .{ .name = "cap_sys_time", .num = CAP_SYS_TIME },
    .{ .name = "cap_sys_tty_config", .num = CAP_SYS_TTY_CONFIG },
    .{ .name = "cap_mknod", .num = CAP_MKNOD },
    .{ .name = "cap_lease", .num = CAP_LEASE },
    .{ .name = "cap_audit_write", .num = CAP_AUDIT_WRITE },
    .{ .name = "cap_audit_control", .num = CAP_AUDIT_CONTROL },
    .{ .name = "cap_setfcap", .num = CAP_SETFCAP },
    .{ .name = "cap_mac_override", .num = CAP_MAC_OVERRIDE },
    .{ .name = "cap_mac_admin", .num = CAP_MAC_ADMIN },
    .{ .name = "cap_syslog", .num = CAP_SYSLOG },
    .{ .name = "cap_wake_alarm", .num = CAP_WAKE_ALARM },
    .{ .name = "cap_block_suspend", .num = CAP_BLOCK_SUSPEND },
    .{ .name = "cap_audit_read", .num = CAP_AUDIT_READ },
    .{ .name = "cap_perfmon", .num = CAP_PERFMON },
    .{ .name = "cap_bpf", .num = CAP_BPF },
    .{ .name = "cap_checkpoint_restore", .num = CAP_CHECKPOINT_RESTORE },
};

/// Resolve a capability name (case-insensitive) to its number.
pub fn nameToNumber(name: []const u8) ?u8 {
    var lower_buf: [64]u8 = undefined;
    if (name.len > lower_buf.len) return null;
    for (name, 0..) |c, i| {
        lower_buf[i] = std.ascii.toLower(c);
    }
    const lower = lower_buf[0..name.len];

    for (cap_names) |entry| {
        if (std.mem.eql(u8, lower, entry.name)) return entry.num;
    }
    return null;
}

/// Resolve a capability number to its name.
pub fn numberToName(num: u8) ?[]const u8 {
    for (cap_names) |entry| {
        if (entry.num == num) return entry.name;
    }
    return null;
}

/// Parse a comma-separated list of capability names into a list of cap numbers.
/// Returns the count of parsed caps. Max 64 caps.
pub fn parseCapList(input: []const u8, out: *[64]u8) !u8 {
    if (input.len == 0) return 0;
    var count: u8 = 0;
    var iter = std.mem.splitScalar(u8, input, ',');
    while (iter.next()) |raw| {
        const trimmed = std.mem.trim(u8, raw, " \t");
        if (trimmed.len == 0) continue;
        const cap_num = nameToNumber(trimmed) orelse return error.UnknownCapability;
        if (count >= 64) return error.TooManyCapabilities;
        out[count] = cap_num;
        count += 1;
    }
    return count;
}

// ── Syscall error type ──────────────────────────────────────────────────

pub const SyscallError = error{
    /// prctl failed — errno preserved in return
    PrctlFailed,
    /// capget syscall failed
    CapgetFailed,
    /// capset syscall failed
    CapsetFailed,
    /// Capability number >= 64, outside v3 capset range
    CapOutOfRange,
};

// ── prctl constants ─────────────────────────────────────────────────────
const PR_CAPBSET_DROP = 24;
const PR_CAP_AMBIENT = 47;
const PR_CAP_AMBIENT_LOWER = 3;
const PR_SET_NO_NEW_PRIVS = 38;

// ── capget/capset types ─────────────────────────────────────────────────
// Linux capability v3 header + 2-element data array (covers caps 0-63)
const CapUserHeader = extern struct {
    version: u32,
    pid: i32,
};

const CapUserData = extern struct {
    effective: u32,
    permitted: u32,
    inheritable: u32,
};

const LINUX_CAPABILITY_VERSION_3: u32 = 0x20080522;

fn capget(hdr: *CapUserHeader, data: *[2]CapUserData) SyscallError!void {
    const rc = linux.syscall2(.capget, @intFromPtr(hdr), @intFromPtr(data));
    if (linux.E.init(rc) != .SUCCESS) return error.CapgetFailed;
}

fn capset(hdr: *CapUserHeader, data: *[2]CapUserData) SyscallError!void {
    const rc = linux.syscall2(.capset, @intFromPtr(hdr), @intFromPtr(data));
    if (linux.E.init(rc) != .SUCCESS) return error.CapsetFailed;
}

/// Raw prctl wrapper that returns the errno for callers to inspect.
fn prctlRaw(option: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) linux.E {
    const rc = linux.syscall5(.prctl, option, arg2, arg3, arg4, arg5);
    return linux.E.init(rc);
}

fn prctl(option: usize, arg2: usize, arg3: usize, arg4: usize, arg5: usize) SyscallError!void {
    if (prctlRaw(option, arg2, arg3, arg4, arg5) != .SUCCESS) return error.PrctlFailed;
}

// ── Public API ──────────────────────────────────────────────────────────

/// Validate that a cap number fits in the v3 capset structure (0-63).
fn validateCap(cap: u8) SyscallError!void {
    if (cap >= 64) return error.CapOutOfRange;
}

/// Set the no_new_privs bit.
pub fn setNoNewPrivs() SyscallError!void {
    try prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0);
}

/// Read CAP_LAST_CAP from /proc/sys/kernel/cap_last_cap.
pub fn readLastCap() u8 {
    const file = std.fs.openFileAbsolute("/proc/sys/kernel/cap_last_cap", .{}) catch return MAX_KNOWN_CAP;
    defer file.close();
    var buf: [8]u8 = undefined;
    const n = file.read(&buf) catch return MAX_KNOWN_CAP;
    const trimmed = std.mem.trim(u8, buf[0..n], " \t\n");
    return std.fmt.parseInt(u8, trimmed, 10) catch MAX_KNOWN_CAP;
}

/// Drop capabilities from ALL five sets (ambient, inheritable, effective, permitted, bounding).
///
/// Order: ambient -> {inheritable, effective, permitted} via batch capset -> bounding
///
/// The capset call is batched: a single capget, clear all target bits across
/// inheritable+effective+permitted, then a single capset. This is both atomic
/// with respect to the capability state and avoids N round-trips.
pub fn dropCaps(cap_list: []const u8) SyscallError!void {
    // Validate all caps are in range before making any changes.
    for (cap_list) |cap| {
        try validateCap(cap);
    }

    // 1. Drop from ambient set (per-cap prctl, no batch API).
    //    PR_CAP_AMBIENT_LOWER returns EINVAL if cap is not raised in ambient — that's OK.
    //    Any other error (e.g., EPERM) is fatal.
    for (cap_list) |cap| {
        const errno = prctlRaw(PR_CAP_AMBIENT, PR_CAP_AMBIENT_LOWER, cap, 0, 0);
        switch (errno) {
            .SUCCESS, .INVAL => {},
            else => return error.PrctlFailed,
        }
    }

    // 2. Batch drop from inheritable + effective + permitted via single capget/capset.
    var hdr = CapUserHeader{ .version = LINUX_CAPABILITY_VERSION_3, .pid = 0 };
    var data: [2]CapUserData = .{
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
        .{ .effective = 0, .permitted = 0, .inheritable = 0 },
    };
    try capget(&hdr, &data);

    for (cap_list) |cap| {
        const idx: usize = if (cap >= 32) 1 else 0;
        const bit: u32 = @as(u32, 1) << @intCast(cap % 32);
        data[idx].inheritable &= ~bit;
        data[idx].effective &= ~bit;
        data[idx].permitted &= ~bit;
    }

    try capset(&hdr, &data);

    // 3. Drop from bounding set (per-cap prctl, no batch API).
    for (cap_list) |cap| {
        try prctl(PR_CAPBSET_DROP, cap, 0, 0, 0);
    }
}

// ── Tests ───────────────────────────────────────────────────────────────

test "nameToNumber" {
    try std.testing.expectEqual(@as(?u8, 12), nameToNumber("cap_net_admin"));
    try std.testing.expectEqual(@as(?u8, 12), nameToNumber("CAP_NET_ADMIN"));
    try std.testing.expectEqual(@as(?u8, 13), nameToNumber("cap_net_raw"));
    try std.testing.expectEqual(@as(?u8, null), nameToNumber("cap_bogus"));
}

test "numberToName" {
    try std.testing.expectEqualStrings("cap_net_admin", numberToName(12).?);
    try std.testing.expectEqual(@as(?[]const u8, null), numberToName(99));
}

test "parseCapList" {
    var out: [64]u8 = undefined;
    const count = try parseCapList("cap_net_admin,cap_net_raw", &out);
    try std.testing.expectEqual(@as(u8, 2), count);
    try std.testing.expectEqual(@as(u8, 12), out[0]);
    try std.testing.expectEqual(@as(u8, 13), out[1]);
}

test "parseCapList empty" {
    var out: [64]u8 = undefined;
    const count = try parseCapList("", &out);
    try std.testing.expectEqual(@as(u8, 0), count);
}

test "parseCapList unknown" {
    var out: [64]u8 = undefined;
    try std.testing.expectError(error.UnknownCapability, parseCapList("cap_bogus", &out));
}
