#!/usr/bin/env python3
"""Rebuild on source changes; atomically stage the extension plus corresponding sources."""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "Vendor/ReadFrog"
OUTPUT = ROOT / "build/BrowserExtension"
EXCLUDED = {"node_modules", ".git", ".output", ".wxt", ".turbo", ".DS_Store",
            ".agents", ".claude", ".codex", ".cursor", ".grok", ".gemini", ".vscode", ".idea",
            "AGENTS.md", "CLAUDE.md"}


def source_files():
    for directory, dirs, files in os.walk(SOURCE):
        dirs[:] = sorted(d for d in dirs if d not in EXCLUDED)
        for name in sorted(files):
            path = Path(directory) / name
            if name in EXCLUDED or name.startswith(".env") or path.is_symlink():
                continue
            yield path


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def fingerprint():
    value = hashlib.sha256()
    for path in [*source_files(), Path(__file__), ROOT / "script/build_browser_extension.sh"]:
        value.update(str(path.relative_to(ROOT)).encode())
        value.update(path.read_bytes())
    return value.hexdigest()


def dependency_notices():
    packages = SOURCE / "node_modules/.pnpm"
    paths = list(packages.glob("*/node_modules/*/package.json"))
    paths += list(packages.glob("*/node_modules/@*/*/package.json"))
    seen = set()
    notices = ["Read Frog / LiveLearn dependency notices\n"]
    inventory = []
    for path in sorted(paths):
        package = json.loads(path.read_text())
        identity = f"{package.get('name')}@{package.get('version')}"
        if identity in seen:
            continue
        seen.add(identity)
        license_name = package.get("license", "See package source")
        inventory.append({"name": package.get("name"), "version": package.get("version"), "license": license_name})
        notices.append(f"\n{'=' * 60}\n{identity}\nLicense: {license_name}\n")
        for candidate in sorted(path.parent.iterdir()):
            if candidate.is_file() and candidate.name.lower().startswith(("license", "licence", "copying", "notice")):
                notices.append(candidate.read_text(errors="replace"))
    (SOURCE / "public/THIRD-PARTY-NOTICES.txt").write_text("\n".join(notices))
    (SOURCE / "public/DEPENDENCIES.json").write_text(json.dumps(inventory, indent=2))


def main():
    before = fingerprint()
    receipt = OUTPUT / "build-receipt.json"
    if receipt.exists():
        cached = json.loads(receipt.read_text())
        if cached.get("input") == before and all(
            (OUTPUT / name).is_file() and digest(OUTPUT / name) == sha
            for name, sha in cached.get("outputs", {}).items()
        ) and len(cached.get("outputs", {})) == 4:
            print("▸ bundled browser extension is current")
            return

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    # Do not inherit production auth/telemetry keys or an environment-specific API endpoint.
    env = {key: value for key, value in env.items() if not key.startswith("WXT_")}
    env["WXT_SKIP_ENV_VALIDATION"] = "true"
    env["HUSKY"] = "0"
    # A changed lockfile must never be paired with a previously installed dependency tree.
    # The complete-artifact cache above keeps unchanged app builds offline and fast.
    subprocess.run(["pnpm", "install", "--frozen-lockfile"], cwd=SOURCE, env=env, check=True)
    dependency_notices()
    log = OUTPUT.parent / "browser-extension-build.log"
    print("▸ building bundled Read Frog extension", flush=True)
    with log.open("w") as handle:
        result = subprocess.run(["pnpm", "exec", "wxt", "build"], cwd=SOURCE, env=env, stdout=handle, stderr=subprocess.STDOUT)
    if result.returncode:
        print(log.read_text()[-8000:])
        raise SystemExit(result.returncode)
    built = SOURCE / ".output/chrome-mv3"
    manifest = json.loads((built / "manifest.json").read_text())
    assert manifest["manifest_version"] == 3 and manifest["name"] == "LiveLearn"
    assert "cookies" not in manifest["permissions"] and "identity" not in manifest["permissions"]
    assert (built / "livelearn.html").is_file() and (built / "LICENSE.txt").is_file()
    assert not any("guide" in str(entry) or "partner-bridge" in str(entry) for entry in manifest.get("content_scripts", []))
    source_metadata = json.loads((SOURCE / "livelearn-package.json").read_text())
    extension_id = "".join(chr(97 + int(char, 16)) for char in hashlib.sha256(base64.b64decode(manifest["key"])).hexdigest()[:32])
    stage = Path(tempfile.mkdtemp(prefix="BrowserExtension-stage-", dir=OUTPUT.parent))
    try:
        files = {}
        with zipfile.ZipFile(stage / "chromium.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            for path in sorted(built.rglob("*")):
                if path.is_file():
                    relative = path.relative_to(built).as_posix()
                    files[relative] = digest(path)
                    archive.write(path, relative)
        metadata = dict(version=manifest["version"], upstreamCommit=source_metadata["upstreamCommit"],
                        extensionID=extension_id, archiveSHA256=digest(stage / "chromium.zip"), files=files)
        (stage / "package.json").write_text(json.dumps(metadata, indent=2))
        with tarfile.open(stage / "ReadFrog-source.tar.gz", "w:gz") as archive:
            for path in source_files():
                archive.add(path, arcname="ReadFrog/" + path.relative_to(SOURCE).as_posix(), recursive=False)
            for path in [Path(__file__), ROOT / "script/build_browser_extension.sh"]:
                archive.add(path, arcname="LiveLearn-integration/" + path.name, recursive=False)
        shutil.copyfile(SOURCE / "README.livelearn.md", stage / "README.txt")
        receipt_data = {"input": fingerprint(), "outputs": {p.name: digest(p) for p in stage.iterdir() if p.is_file()}}
        (stage / "build-receipt.json").write_text(json.dumps(receipt_data, indent=2))
        backup = OUTPUT.with_name("BrowserExtension.previous")
        if backup.exists():
            shutil.rmtree(backup)
        if OUTPUT.exists():
            OUTPUT.rename(backup)
        try:
            stage.rename(OUTPUT)
        except BaseException:
            if backup.exists():
                backup.rename(OUTPUT)
            raise
        if backup.exists():
            shutil.rmtree(backup)
        print(f"▸ browser extension {manifest['version']} packaged ({extension_id})")
    finally:
        if stage.exists():
            shutil.rmtree(stage)


if __name__ == "__main__":
    main()
