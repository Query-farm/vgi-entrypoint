// Copyright 2026 Query.Farm LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

const std = @import("std");
const caps = @import("caps.zig");
const dump = @import("dump.zig");
const build_options = @import("build_options");

fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    logMsg(fmt, args);
    std.process.exit(1);
}

fn logMsg(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    writer.interface.print("vgi-entrypoint: " ++ fmt ++ "\n", args) catch {};
    writer.interface.flush() catch {};
}

fn debugMsg(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    writer.interface.print("vgi-entrypoint: [debug] " ++ fmt ++ "\n", args) catch {};
    writer.interface.flush() catch {};
}

/// Read a file, fataling on any error.
fn readFile(allocator: std.mem.Allocator, path: []const u8) []const u8 {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err|
        fatal("cannot open file '{s}': {}", .{ path, err });
    defer file.close();
    return file.readToEndAlloc(allocator, 1024 * 1024) catch |err|
        fatal("cannot read file '{s}': {}", .{ path, err });
}

const ImageConfig = struct {
    entrypoint: ?[]const [:0]const u8,
    cmd: ?[]const [:0]const u8,
    working_dir: ?[:0]const u8,
    env: ?[]const [:0]const u8,
};

/// Convert a std.json.Value to an optional slice of sentinel-terminated strings.
/// Returns null for .null or empty arrays.
fn jsonValueToStringArray(allocator: std.mem.Allocator, value: std.json.Value) !?[]const [:0]const u8 {
    switch (value) {
        .null => return null,
        .array => |arr| {
            if (arr.items.len == 0) return null;
            var result = try allocator.alloc([:0]const u8, arr.items.len);
            var filled: usize = 0;
            errdefer {
                for (result[0..filled]) |s| allocator.free(s);
                allocator.free(result);
            }
            for (arr.items) |item| {
                switch (item) {
                    .string => |s| {
                        result[filled] = try allocator.dupeZ(u8, s);
                        filled += 1;
                    },
                    else => return error.ExpectedStringElement,
                }
            }
            return result;
        },
        else => return error.ExpectedArrayOrNull,
    }
}

/// Parse a Docker image config JSON and extract Entrypoint and Cmd.
fn parseImageConfig(allocator: std.mem.Allocator, content: []const u8) !ImageConfig {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch
        return error.InvalidJson;
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };

    const config_val = root_obj.get("config") orelse return error.MissingConfig;
    const config_obj = switch (config_val) {
        .object => |o| o,
        else => return error.ExpectedObject,
    };

    const ep_val = config_obj.get("Entrypoint") orelse std.json.Value.null;
    const cmd_val = config_obj.get("Cmd") orelse std.json.Value.null;

    const entrypoint = try jsonValueToStringArray(allocator, ep_val);
    errdefer if (entrypoint) |ep| {
        for (ep) |s| allocator.free(s);
        allocator.free(ep);
    };

    const cmd = try jsonValueToStringArray(allocator, cmd_val);
    errdefer if (cmd) |c| {
        for (c) |s| allocator.free(s);
        allocator.free(c);
    };

    const working_dir: ?[:0]const u8 = if (config_obj.get("WorkingDir")) |wd_val| switch (wd_val) {
        .string => |s| if (s.len > 0) try allocator.dupeZ(u8, s) else null,
        .null => null,
        else => return error.ExpectedString,
    } else null;
    errdefer if (working_dir) |wd| allocator.free(wd);

    const env_val = config_obj.get("Env") orelse std.json.Value.null;
    const env = try jsonValueToStringArray(allocator, env_val);

    return .{
        .entrypoint = entrypoint,
        .cmd = cmd,
        .working_dir = working_dir,
        .env = env,
    };
}

/// Combine ENTRYPOINT and CMD per Docker rules.
/// Both null → error.NoCommand
/// EP only → EP
/// CMD only → CMD
/// Both → EP ++ CMD
fn combineEntrypointCmd(
    allocator: std.mem.Allocator,
    ep: ?[]const [:0]const u8,
    cmd: ?[]const [:0]const u8,
) ![]const [:0]const u8 {
    if (ep) |e| {
        if (cmd) |c| {
            // Both set: concatenate
            var result = try allocator.alloc([:0]const u8, e.len + c.len);
            @memcpy(result[0..e.len], e);
            @memcpy(result[e.len..], c);
            return result;
        }
        return e;
    }
    if (cmd) |c| return c;
    return error.NoCommand;
}

fn getEnvBool(name: []const u8, default: bool) bool {
    const val = std.posix.getenv(name) orelse return default;
    if (std.ascii.eqlIgnoreCase(val, "true") or std.mem.eql(u8, val, "1")) return true;
    if (std.ascii.eqlIgnoreCase(val, "false") or std.mem.eql(u8, val, "0")) return false;
    return default;
}

fn requireEnv(name: []const u8) [:0]const u8 {
    return std.posix.getenv(name) orelse
        fatal("required environment variable {s} is not set", .{name});
}

/// Resolve the image config from the config file.
/// Returns the parsed ImageConfig with command, working_dir, and env.
fn resolveImageConfig(allocator: std.mem.Allocator, config_path: []const u8) ImageConfig {
    const config_content = readFile(allocator, config_path);

    return parseImageConfig(allocator, config_content) catch |err| switch (err) {
        error.InvalidJson => fatal("image config file '{s}' contains invalid JSON", .{config_path}),
        error.ExpectedObject => fatal("image config file '{s}' has unexpected structure", .{config_path}),
        error.MissingConfig => fatal("image config file '{s}' missing 'config' key", .{config_path}),
        error.ExpectedStringElement => fatal("image config file '{s}' has non-string array elements in Entrypoint/Cmd/Env", .{config_path}),
        error.ExpectedArrayOrNull => fatal("image config file '{s}' has invalid Entrypoint/Cmd/Env value (expected array or null)", .{config_path}),
        error.ExpectedString => fatal("image config file '{s}' has invalid WorkingDir value (expected string)", .{config_path}),
        else => fatal("failed to parse image config file '{s}': {}", .{ config_path, err }),
    };
}

/// Extract the key portion (before '=') from an env entry.
fn envKey(entry: [*:0]const u8) []const u8 {
    const slice = std.mem.sliceTo(entry, 0);
    return if (std.mem.indexOfScalar(u8, slice, '=')) |eq| slice[0..eq] else slice;
}

/// Build envp by merging image config env vars with the current process environment.
/// Current environment takes precedence over image config values.
/// Returns a pointer suitable for execvpeZ.
fn buildEnvp(allocator: std.mem.Allocator, config_env: ?[]const [:0]const u8) [*:null]const ?[*:0]const u8 {
    const current_environ: [*:null]const ?[*:0]const u8 = @ptrCast(std.os.environ.ptr);

    const image_env = config_env orelse return current_environ;
    if (image_env.len == 0) return current_environ;

    // Count current env entries
    var current_count: usize = 0;
    while (current_environ[current_count] != null) : (current_count += 1) {}

    // Collect image env entries not already in current environment
    var extra = allocator.alloc(?[*:0]const u8, image_env.len) catch
        fatal("out of memory building environment", .{});
    var extra_count: usize = 0;

    for (image_env) |entry| {
        const key = if (std.mem.indexOfScalar(u8, entry, '=')) |eq| entry[0..eq] else entry;
        var found = false;
        for (0..current_count) |i| {
            if (current_environ[i]) |cur| {
                const cur_key = envKey(cur);
                if (std.mem.eql(u8, key, cur_key)) {
                    found = true;
                    break;
                }
            }
        }
        if (!found) {
            extra[extra_count] = entry.ptr;
            extra_count += 1;
        }
    }

    if (extra_count == 0) {
        allocator.free(extra);
        return current_environ;
    }

    // Build merged envp: current + extra + null terminator
    var merged = allocator.allocSentinel(?[*:0]const u8, current_count + extra_count, null) catch
        fatal("out of memory building environment", .{});
    for (0..current_count) |i| {
        merged[i] = current_environ[i];
    }
    for (0..extra_count) |i| {
        merged[current_count + i] = extra[i];
    }
    allocator.free(extra);
    return merged.ptr;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const config_path = std.posix.getenv("VGI_ENTRYPOINT_IMAGE_CONFIG_FILE") orelse "/vgi-image-config";
    const dry_run = getEnvBool("VGI_ENTRYPOINT_DRY_RUN", false);
    const debug = getEnvBool("VGI_ENTRYPOINT_DEBUG", false);

    logMsg("version {s}", .{build_options.version});

    if (debug) {
        debugMsg("config_path={s}", .{config_path});
        debugMsg("dry_run={}", .{dry_run});
    }

    if (dry_run) {
        const image_config = resolveImageConfig(allocator, config_path);
        const argv_strs = combineEntrypointCmd(allocator, image_config.entrypoint, image_config.cmd) catch
            fatal("neither entrypoint nor cmd is set; nothing to execute", .{});
        // Print resolved command as JSON array to stdout
        var buf: [4096]u8 = undefined;
        var writer = std.fs.File.stdout().writer(&buf);
        writer.interface.print("{f}\n", .{std.json.fmt(argv_strs, .{})}) catch fatal("write failed", .{});
        writer.interface.flush() catch fatal("write failed", .{});
        return;
    }

    const dump_caps = getEnvBool("VGI_ENTRYPOINT_DUMP_CAPS", false);
    const no_new_privs = getEnvBool("VGI_ENTRYPOINT_NO_NEW_PRIVS", true);
    const drop_caps_env = requireEnv("VGI_ENTRYPOINT_DROP_CAPS");

    if (debug) {
        debugMsg("VGI_DROP_CAPS={s}", .{drop_caps_env});
        debugMsg("VGI_NO_NEW_PRIVS={}", .{no_new_privs});
        debugMsg("VGI_DUMP_CAPS={}", .{dump_caps});
    }

    // Parse caps to drop
    var cap_list: [64]u8 = undefined;
    const cap_count = caps.parseCapList(drop_caps_env, &cap_list) catch |err| switch (err) {
        error.UnknownCapability => fatal("unknown capability in VGI_DROP_CAPS: {s}", .{drop_caps_env}),
        error.TooManyCapabilities => fatal("too many capabilities in VGI_DROP_CAPS", .{}),
    };

    if (cap_count == 0) fatal("VGI_DROP_CAPS is empty; at least one capability must be specified", .{});

    if (debug) {
        debugMsg("dropping {} capabilities", .{cap_count});
    }

    const image_config = resolveImageConfig(allocator, config_path);
    const argv_strs = combineEntrypointCmd(allocator, image_config.entrypoint, image_config.cmd) catch
        fatal("neither entrypoint nor cmd is set; nothing to execute", .{});

    if (debug) {
        debugMsg("resolved command: {s} ({} args total)", .{ argv_strs[0], argv_strs.len });
        if (image_config.working_dir) |wd| debugMsg("working_dir={s}", .{wd});
        if (image_config.env) |env_vars| debugMsg("env vars from config: {} entries", .{env_vars.len});
    }

    // Change to working directory
    if (image_config.working_dir) |wd| {
        std.posix.chdir(wd) catch |chdir_err|
            fatal("failed to chdir to '{s}': {}", .{ wd, chdir_err });
    }

    if (dump_caps) dump.dumpCapState("before drop");

    // Drop caps from all sets: ambient -> {inheritable,effective,permitted} -> bounding
    caps.dropCaps(cap_list[0..cap_count]) catch |err|
        fatal("failed to drop capabilities: {}", .{err});

    // Set no_new_privs
    if (no_new_privs) {
        caps.setNoNewPrivs() catch |err|
            fatal("failed to set no_new_privs: {}", .{err});
    }

    if (dump_caps) dump.dumpCapState("after drop");

    // Build argv for execve
    var argv_buf: [256:null]?[*:0]const u8 = .{null} ** 256;
    if (argv_strs.len > 255) fatal("too many arguments (max 255)", .{});
    for (argv_strs, 0..) |s, i| {
        argv_buf[i] = s.ptr;
    }

    // Build envp: merge image config env with current environment (current takes precedence)
    const envp = buildEnvp(allocator, image_config.env);

    logMsg("exec {s}", .{argv_strs[0]});

    const err = std.posix.execvpeZ(argv_strs[0], &argv_buf, envp);
    fatal("exec failed: command='{s}' error={}", .{ argv_strs[0], err });
}

// ── Tests ───────────────────────────────────────────────────────────────

fn freeStringSlice(allocator: std.mem.Allocator, slice: []const [:0]const u8) void {
    for (slice) |s| allocator.free(s);
    allocator.free(slice);
}

fn freeImageConfig(allocator: std.mem.Allocator, config: ImageConfig) void {
    if (config.entrypoint) |ep| freeStringSlice(allocator, ep);
    if (config.cmd) |cmd| freeStringSlice(allocator, cmd);
    if (config.env) |env| freeStringSlice(allocator, env);
    if (config.working_dir) |wd| allocator.free(wd);
}

fn expectStrings(actual: []const [:0]const u8, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, 0..) |e, i| {
        try std.testing.expectEqualStrings(e, actual[i]);
    }
}

// -- jsonValueToStringArray tests --

test "jsonValueToStringArray: null value returns null" {
    const result = try jsonValueToStringArray(std.testing.allocator, std.json.Value.null);
    try std.testing.expect(result == null);
}

test "jsonValueToStringArray: empty array returns null" {
    var arr = std.json.Array.init(std.testing.allocator);
    defer arr.deinit();
    const result = try jsonValueToStringArray(std.testing.allocator, .{ .array = arr });
    try std.testing.expect(result == null);
}

test "jsonValueToStringArray: valid string array" {
    const allocator = std.testing.allocator;
    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .string = "echo" });
    try arr.append(.{ .string = "hello" });
    const result = (try jsonValueToStringArray(allocator, .{ .array = arr })).?;
    defer freeStringSlice(allocator, result);
    try expectStrings(result, &.{ "echo", "hello" });
}

test "jsonValueToStringArray: non-string elements" {
    const allocator = std.testing.allocator;
    var arr = std.json.Array.init(allocator);
    defer arr.deinit();
    try arr.append(.{ .integer = 42 });
    try std.testing.expectError(
        error.ExpectedStringElement,
        jsonValueToStringArray(allocator, .{ .array = arr }),
    );
}

test "jsonValueToStringArray: non-array non-null" {
    try std.testing.expectError(
        error.ExpectedArrayOrNull,
        jsonValueToStringArray(std.testing.allocator, .{ .integer = 42 }),
    );
}

// -- parseImageConfig tests --

test "parseImageConfig: both entrypoint and cmd" {
    const allocator = std.testing.allocator;
    const json =
        \\{"config":{"Entrypoint":["python"],"Cmd":["app.py","--port","8080"]}}
    ;
    const config = try parseImageConfig(allocator, json);
    defer freeImageConfig(allocator, config);
    try expectStrings(config.entrypoint.?, &.{"python"});
    try expectStrings(config.cmd.?, &.{ "app.py", "--port", "8080" });
}

test "parseImageConfig: entrypoint only" {
    const allocator = std.testing.allocator;
    const json =
        \\{"config":{"Entrypoint":["/entrypoint.sh"]}}
    ;
    const config = try parseImageConfig(allocator, json);
    defer freeImageConfig(allocator, config);
    try expectStrings(config.entrypoint.?, &.{"/entrypoint.sh"});
    try std.testing.expect(config.cmd == null);
}

test "parseImageConfig: cmd only" {
    const allocator = std.testing.allocator;
    const json =
        \\{"config":{"Cmd":["echo","hi"]}}
    ;
    const config = try parseImageConfig(allocator, json);
    defer freeImageConfig(allocator, config);
    try std.testing.expect(config.entrypoint == null);
    try expectStrings(config.cmd.?, &.{ "echo", "hi" });
}

test "parseImageConfig: null values" {
    const allocator = std.testing.allocator;
    const json =
        \\{"config":{"Entrypoint":null,"Cmd":null}}
    ;
    const config = try parseImageConfig(allocator, json);
    defer freeImageConfig(allocator, config);
    try std.testing.expect(config.entrypoint == null);
    try std.testing.expect(config.cmd == null);
}

test "parseImageConfig: missing keys" {
    const allocator = std.testing.allocator;
    const json =
        \\{"config":{}}
    ;
    const config = try parseImageConfig(allocator, json);
    defer freeImageConfig(allocator, config);
    try std.testing.expect(config.entrypoint == null);
    try std.testing.expect(config.cmd == null);
}

test "parseImageConfig: empty arrays" {
    const allocator = std.testing.allocator;
    const json =
        \\{"config":{"Entrypoint":[],"Cmd":[]}}
    ;
    const config = try parseImageConfig(allocator, json);
    defer freeImageConfig(allocator, config);
    try std.testing.expect(config.entrypoint == null);
    try std.testing.expect(config.cmd == null);
}

test "parseImageConfig: extra fields ignored" {
    const allocator = std.testing.allocator;
    const json =
        \\{"config":{"Entrypoint":["echo"],"Cmd":["hi"],"Shell":["/bin/bash","-c"],"ArgsEscaped":true,"Env":["PATH=/usr/bin"]}}
    ;
    const config = try parseImageConfig(allocator, json);
    defer freeImageConfig(allocator, config);
    try expectStrings(config.entrypoint.?, &.{"echo"});
    try expectStrings(config.cmd.?, &.{"hi"});
    try expectStrings(config.env.?, &.{"PATH=/usr/bin"});
}

test "parseImageConfig: invalid JSON" {
    try std.testing.expectError(
        error.InvalidJson,
        parseImageConfig(std.testing.allocator, "not json"),
    );
}

test "parseImageConfig: missing config key" {
    try std.testing.expectError(
        error.MissingConfig,
        parseImageConfig(std.testing.allocator, "{}"),
    );
}

test "parseImageConfig: config is not object" {
    try std.testing.expectError(
        error.ExpectedObject,
        parseImageConfig(std.testing.allocator, "{\"config\":42}"),
    );
}

test "parseImageConfig: non-string entrypoint elements" {
    try std.testing.expectError(
        error.ExpectedStringElement,
        parseImageConfig(std.testing.allocator, "{\"config\":{\"Entrypoint\":[1,2]}}"),
    );
}

test "parseImageConfig: WorkingDir and Env" {
    const allocator = std.testing.allocator;
    const json =
        \\{"config":{"Entrypoint":["./app"],"WorkingDir":"/app","Env":["PATH=/usr/bin","FOO=bar"]}}
    ;
    const config = try parseImageConfig(allocator, json);
    defer freeImageConfig(allocator, config);
    try std.testing.expectEqualStrings("/app", config.working_dir.?);
    try expectStrings(config.env.?, &.{ "PATH=/usr/bin", "FOO=bar" });
}

test "parseImageConfig: empty WorkingDir ignored" {
    const allocator = std.testing.allocator;
    const json =
        \\{"config":{"Cmd":["echo"],"WorkingDir":""}}
    ;
    const config = try parseImageConfig(allocator, json);
    defer freeImageConfig(allocator, config);
    try std.testing.expect(config.working_dir == null);
}

test "parseImageConfig: null WorkingDir" {
    const allocator = std.testing.allocator;
    const json =
        \\{"config":{"Cmd":["echo"],"WorkingDir":null}}
    ;
    const config = try parseImageConfig(allocator, json);
    defer freeImageConfig(allocator, config);
    try std.testing.expect(config.working_dir == null);
}

// -- combineEntrypointCmd tests --

test "combineEntrypointCmd: EP only" {
    const allocator = std.testing.allocator;
    const ep: []const [:0]const u8 = &.{ "echo", "hi" };
    const result = try combineEntrypointCmd(allocator, ep, null);
    try expectStrings(result, &.{ "echo", "hi" });
}

test "combineEntrypointCmd: CMD only" {
    const allocator = std.testing.allocator;
    const cmd: []const [:0]const u8 = &.{ "echo", "hi" };
    const result = try combineEntrypointCmd(allocator, null, cmd);
    try expectStrings(result, &.{ "echo", "hi" });
}

test "combineEntrypointCmd: both" {
    const allocator = std.testing.allocator;
    const ep: []const [:0]const u8 = &.{"python"};
    const cmd: []const [:0]const u8 = &.{"app.py"};
    const result = try combineEntrypointCmd(allocator, ep, cmd);
    defer allocator.free(result);
    try expectStrings(result, &.{ "python", "app.py" });
}

test "combineEntrypointCmd: neither" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.NoCommand,
        combineEntrypointCmd(allocator, null, null),
    );
}

test "getEnvBool" {
    try std.testing.expect(getEnvBool("VGI_TEST_NONEXISTENT_VAR_12345", true) == true);
    try std.testing.expect(getEnvBool("VGI_TEST_NONEXISTENT_VAR_12345", false) == false);
}

test {
    _ = @import("caps.zig");
    _ = @import("dump.zig");
}
