"""
Integration tests for vgi-entrypoint image config parsing.

Tests that the binary correctly resolves Entrypoint/Cmd from real Docker
image configs, running locally in dry-run mode (no Linux required).

Usage:
    uv run pytest test_image_config.py -v
"""

import json
import os
import subprocess
import tempfile
from pathlib import Path

import pytest

BINARY = Path(__file__).parent / "zig-out" / "bin" / "vgi-entrypoint"
IMAGES_DIR = Path(__file__).parent / "test-images"


def build_binary():
    """Build the native binary if it doesn't exist or is outdated."""
    src_mtime = max(f.stat().st_mtime for f in (Path(__file__).parent / "src").glob("*.zig"))
    if BINARY.exists() and BINARY.stat().st_mtime >= src_mtime:
        return
    subprocess.run(["zig", "build"], cwd=Path(__file__).parent, check=True)


def extract_image_config(dockerfile: Path) -> dict:
    """Build a Docker image from a Dockerfile and extract its config."""
    tag = f"vgi-test-{dockerfile.stem}"
    subprocess.run(
        ["docker", "build", "-q", "-t", tag, "-f", str(dockerfile), "."],
        cwd=Path(__file__).parent,
        check=True,
        capture_output=True,
    )
    result = subprocess.run(
        ["docker", "inspect", tag, "--format", "{{json .Config}}"],
        check=True,
        capture_output=True,
        text=True,
    )
    config = json.loads(result.stdout)
    return {"config": config}


def run_dry_run(config: dict) -> subprocess.CompletedProcess:
    """Run vgi-entrypoint in dry-run mode with the given image config."""
    with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
        json.dump(config, f)
        f.flush()
        config_path = f.name
    try:
        return subprocess.run(
            [str(BINARY)],
            env={
                "VGI_DRY_RUN": "true",
                "VGI_IMAGE_CONFIG_FILE": config_path,
                "PATH": os.environ.get("PATH", ""),
            },
            capture_output=True,
            text=True,
            timeout=10,
        )
    finally:
        os.unlink(config_path)


def resolve_command(config: dict) -> list[str]:
    """Run dry-run and return the resolved command as a list of strings."""
    result = run_dry_run(config)
    assert result.returncode == 0, f"vgi-entrypoint failed: {result.stderr}"
    return json.loads(result.stdout)


@pytest.fixture(scope="session", autouse=True)
def _build():
    build_binary()


# All test images are built once per session and cached.
_image_configs: dict[str, dict] = {}


def get_image_config(name: str) -> dict:
    if name not in _image_configs:
        dockerfile = IMAGES_DIR / f"{name}.Dockerfile"
        assert dockerfile.exists(), f"Dockerfile not found: {dockerfile}"
        _image_configs[name] = extract_image_config(dockerfile)
    return _image_configs[name]


@pytest.fixture(scope="session", autouse=True)
def _cleanup_images():
    """Remove test Docker images after all tests complete."""
    yield
    for dockerfile in IMAGES_DIR.glob("*.Dockerfile"):
        tag = f"vgi-test-{dockerfile.stem}"
        subprocess.run(["docker", "rmi", tag], capture_output=True)


# ── Entrypoint/Cmd combination tests ────────────────────────────────────


class TestEntrypointOnly:
    def test_exec_form(self):
        cmd = resolve_command(get_image_config("ep-only"))
        assert cmd == ["echo", "EP_ONLY"]

    def test_shell_form(self):
        """Shell-form ENTRYPOINT: Docker builder wraps with /bin/sh -c."""
        cmd = resolve_command(get_image_config("ep-shell"))
        assert cmd == ["/bin/sh", "-c", "echo EP_SHELL"]


class TestCmdOnly:
    def test_exec_form(self):
        cmd = resolve_command(get_image_config("cmd-only"))
        assert cmd == ["echo", "CMD_ONLY"]

    def test_shell_form(self):
        """Shell-form CMD: Docker builder wraps with /bin/sh -c."""
        cmd = resolve_command(get_image_config("cmd-shell"))
        assert cmd == ["/bin/sh", "-c", "echo CMD_SHELL"]


class TestEntrypointPlusCmd:
    def test_both_exec_form(self):
        """ENTRYPOINT + CMD: concatenated."""
        cmd = resolve_command(get_image_config("ep-cmd"))
        assert cmd == ["echo", "EP", "CMD_ARG"]

    def test_compound_command(self):
        """ENTRYPOINT ["sh","-c"] + CMD ["echo MULTI && echo SECOND"]."""
        cmd = resolve_command(get_image_config("ep-cmd-multi"))
        assert cmd == ["sh", "-c", "echo MULTI && echo SECOND"]


class TestClearedEntrypoint:
    def test_cleared_ep_with_cmd(self):
        """ENTRYPOINT [] clears it; CMD runs standalone."""
        cmd = resolve_command(get_image_config("ep-cleared-cmd"))
        assert cmd == ["echo", "CLEARED_EP"]


class TestCustomShell:
    def test_shell_directive(self):
        """SHELL ["/bin/bash","-c"] affects shell-form ENTRYPOINT wrapping."""
        cmd = resolve_command(get_image_config("custom-shell"))
        assert cmd == ["/bin/bash", "-c", "echo BASH_SHELL"]


class TestNeither:
    def test_neither_ep_nor_cmd(self):
        """Both empty: should fail with error."""
        config = get_image_config("neither")
        result = run_dry_run(config)
        assert result.returncode != 0
        assert "neither entrypoint nor cmd" in result.stderr


# ── Synthetic config tests (no Docker build needed) ─────────────────────


class TestSyntheticConfigs:
    def test_null_entrypoint_and_cmd(self):
        config = {"config": {"Entrypoint": None, "Cmd": None}}
        result = run_dry_run(config)
        assert result.returncode != 0
        assert "neither entrypoint nor cmd" in result.stderr

    def test_missing_entrypoint_and_cmd_keys(self):
        config = {"config": {}}
        result = run_dry_run(config)
        assert result.returncode != 0
        assert "neither entrypoint nor cmd" in result.stderr

    def test_empty_arrays(self):
        config = {"config": {"Entrypoint": [], "Cmd": []}}
        result = run_dry_run(config)
        assert result.returncode != 0
        assert "neither entrypoint nor cmd" in result.stderr

    def test_entrypoint_only_synthetic(self):
        config = {"config": {"Entrypoint": ["/app/start", "--verbose"]}}
        assert resolve_command(config) == ["/app/start", "--verbose"]

    def test_cmd_only_synthetic(self):
        config = {"config": {"Cmd": ["python", "app.py"]}}
        assert resolve_command(config) == ["python", "app.py"]

    def test_both_synthetic(self):
        config = {"config": {"Entrypoint": ["python"], "Cmd": ["-m", "http.server"]}}
        assert resolve_command(config) == ["python", "-m", "http.server"]

    def test_extra_fields_ignored(self):
        config = {
            "config": {
                "Entrypoint": ["echo", "hi"],
                "Env": ["PATH=/usr/bin"],
                "Labels": {"foo": "bar"},
                "WorkingDir": "/app",
            }
        }
        assert resolve_command(config) == ["echo", "hi"]

    def test_missing_config_key(self):
        result = run_dry_run({})
        assert result.returncode != 0
        assert "missing 'config' key" in result.stderr

    def test_invalid_json(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".json", delete=False) as f:
            f.write("not json at all")
            config_path = f.name
        try:
            result = subprocess.run(
                [str(BINARY)],
                env={
                    "VGI_DRY_RUN": "true",
                    "VGI_IMAGE_CONFIG_FILE": config_path,
                    "PATH": os.environ.get("PATH", ""),
                },
                capture_output=True,
                text=True,
                timeout=10,
            )
            assert result.returncode != 0
            assert "invalid JSON" in result.stderr
        finally:
            os.unlink(config_path)

    def test_missing_config_file(self):
        result = subprocess.run(
            [str(BINARY)],
            env={
                "VGI_DRY_RUN": "true",
                "VGI_IMAGE_CONFIG_FILE": "/nonexistent/path",
                "PATH": os.environ.get("PATH", ""),
            },
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode != 0
        assert "cannot open file" in result.stderr
