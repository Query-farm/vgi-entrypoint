<h1 align="center">VGI Entrypoint</h1>

<p align="center">
  Container entrypoint that drops Linux capabilities before exec.<br>
  Built by <a href="https://query.farm">Query.Farm</a>
</p>

<p align="center">
  <a href="https://github.com/Query-farm/vgi-entrypoint/actions/workflows/build.yml"><img src="https://github.com/Query-farm/vgi-entrypoint/actions/workflows/build.yml/badge.svg" alt="Build"></a>
  <a href="https://github.com/Query-farm/vgi-entrypoint/blob/main/LICENSE.md"><img src="https://img.shields.io/badge/license-Apache%202.0-blue" alt="License"></a>
</p>

A tiny static binary (~90 KB) that acts as a container entrypoint. It parses the Docker image config to resolve `ENTRYPOINT` + `CMD`, drops Linux capabilities from all five sets (ambient, inheritable, effective, permitted, bounding), sets `no_new_privs`, and exec's the resolved command.

Designed to harden containers by removing capabilities at runtime without modifying the container image.

## How It Works

1. Reads the Docker image config JSON (injected at `/vgi-image-config`)
2. Resolves the command to run using Docker's `ENTRYPOINT`/`CMD` combination rules
3. Drops specified Linux capabilities from all five capability sets
4. Sets `PR_SET_NO_NEW_PRIVS` (prevents privilege escalation via setuid/setgid)
5. Exec's the resolved command

## Environment Variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `VGI_DROP_CAPS` | Yes | — | Comma-separated capability names to drop (e.g. `cap_net_raw,cap_sys_admin`) |
| `VGI_IMAGE_CONFIG_FILE` | No | `/vgi-image-config` | Path to Docker image config JSON |
| `VGI_NO_NEW_PRIVS` | No | `true` | Set the `no_new_privs` bit |
| `VGI_DUMP_CAPS` | No | `false` | Dump capability state before and after drop (debug) |
| `VGI_DRY_RUN` | No | `false` | Parse config and print resolved command as JSON, then exit |

## Build

Requires [Zig](https://ziglang.org/) 0.15.x. Cross-compiles to Linux from any platform.

```bash
# Build for amd64 (default)
zig build

# Build for arm64
zig build -Darch=aarch64

# Run unit tests
zig build test

# Output: zig-out/bin/vgi-entrypoint
```

## Testing

```bash
# Unit tests (any platform)
zig build test

# Integration tests — image config parsing (requires Docker)
uv run --with pytest pytest test_image_config.py -v

# Integration tests — cap drop on Linux (requires fly.io)
./test-fly.sh
```

## CI/CD

GitHub Actions builds on push to `main`, PRs, and version tags. Matrix builds for amd64 and arm64.

- **Push to main / PR** — build, test, and upload artifacts
- **Push to main** — also publish to Cloudflare R2
- **Tag `v*`** — publish to R2 and create GitHub Release

To create a release:

```bash
git tag v0.1.0
git push origin v0.1.0
```

## License

Copyright 2026 [Query.Farm LLC](https://query.farm)

Licensed under the Apache License, Version 2.0. See [LICENSE.md](LICENSE.md) for details.
