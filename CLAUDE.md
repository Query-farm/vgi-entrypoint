# VGI Entrypoint

Container entrypoint that drops Linux capabilities before exec. Parses Docker image config to resolve `ENTRYPOINT` + `CMD`, drops capabilities from all five sets, sets `no_new_privs`, and exec's the resolved command.

## Architecture

Part of a two-stage bootstrap chain with [VGI Injector](https://github.com/Query-farm/vgi-injector):
1. VGI Injector downloads this binary at container startup
2. This binary drops capabilities and exec's the container's normal command

## Environment Variables

All prefixed with `VGI_ENTRYPOINT_`:

- `VGI_ENTRYPOINT_DROP_CAPS` (required) — comma-separated cap names to drop (e.g. `cap_net_raw,cap_sys_admin`)
- `VGI_ENTRYPOINT_IMAGE_CONFIG_FILE` (default: `/vgi-image-config`) — Docker image config JSON
- `VGI_ENTRYPOINT_NO_NEW_PRIVS` (default: `true`)
- `VGI_ENTRYPOINT_DUMP_CAPS` (default: `false`) — dump cap state before/after drop
- `VGI_ENTRYPOINT_DRY_RUN` (default: `false`) — parse config, print resolved command as JSON, exit
- `VGI_ENTRYPOINT_DEBUG` (default: `false`) — verbose debug logging

## Build

Requires Zig 0.15.x. Cross-compiles to Linux from any platform.

```bash
# amd64 (default)
zig build
# or explicitly:
zig build -Darch=x86_64

# arm64
zig build -Darch=aarch64

# with version string
zig build -Dversion=v0.3.0

# Output: zig-out/bin/vgi-entrypoint (~90KB static ELF)
```

Target: `linux-musl` (static, uses libc for execve/file I/O).

## Testing

```bash
# Unit tests (any platform, runs natively)
zig build test

# Integration tests — image config parsing (macOS/Linux, requires Docker)
uv run --with pytest pytest test_image_config.py -v

# Integration tests — cap drop on Linux (requires a Linux VM)
./test-fly.sh
```

## CI

GitHub Actions builds on push to `main`, PRs, and tags. Matrix builds for amd64 and arm64.

- **push to main / PR** — build, test, upload artifacts
- **tag `v*`** — publish to R2, create GitHub release

To create a release:
```bash
# bump version in build.zig.zon, commit, then:
git tag v0.3.0
git push origin v0.3.0
```

## Project Structure

```
src/main.zig              — image config parsing, env var handling, cap drop orchestration, execve
src/caps.zig              — cap constants, name mapping, prctl/capget/capset syscall wrappers
src/dump.zig              — parse /proc/self/status cap lines, dump to stderr
build.zig                 — build config (linux-musl, ReleaseSmall, stripped, -Darch/-Dversion)
build.zig.zon             — package metadata
test_image_config.py      — pytest integration tests (Docker-based, dry-run mode)
test-fly.sh               — Linux integration tests for cap drop
test-images/              — Dockerfiles for each ENTRYPOINT/CMD combination
.github/workflows/build.yml — CI: build matrix → R2 publish → GitHub release
```

## Zig Notes

- Uses Zig 0.15.2 APIs
- ABI is `.musl` (not `.none` — needs libc for execve/file I/O)
- `std.fs.File.stderr().writer(&buf)` with explicit buffer, access `.interface`, must `.flush()`
- `std.json.fmt(value, .{})` with `{f}` format specifier for JSON serialization
- Test modules need explicit `.target = b.graph.host` when exe target is cross-compiled
- `build.zig.zon`: version/minimum_zig_version are strings, name is bare identifier
