#!/usr/bin/env python3
"""Package already-built optional modules. Publish only after signing catalog-payload.json."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import shutil
import stat
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def archive_tree(source, destination):
    expanded = 0
    with zipfile.ZipFile(destination, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for directory, dirs, files in os.walk(source, followlinks=False):
            dirs.sort()
            for name in sorted(dirs + files):
                path = Path(directory) / name
                if name == ".DS_Store":
                    continue
                relative = path.relative_to(source).as_posix()
                if path.is_symlink():
                    link = os.readlink(path)
                    if not path.resolve().is_relative_to(source.resolve()):
                        raise ValueError(f"External symlink: {relative}")
                    info = zipfile.ZipInfo(relative)
                    info.create_system = 3
                    info.external_attr = (stat.S_IFLNK | 0o777) << 16
                    data = link.encode()
                    archive.writestr(info, data)
                    expanded += len(data)
                elif path.is_file():
                    archive.write(path, relative)
                    expanded += path.stat().st_size
                else:
                    archive.write(path, relative + "/")
    return expanded


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", default="0.1.0")
    parser.add_argument("--tag", default="modules-v1")
    args = parser.parse_args()
    output = ROOT / "build/releases"
    stage = ROOT / "build/module-staging"
    output.mkdir(parents=True, exist_ok=True)
    definitions = {
        "textTranslation": (15, "arm64", [
            (ROOT / "build/components/LiveLearnTranslation.app", "Helpers/LiveLearnTranslation.app"),
            (ROOT / "build/components/LiveLearnTranslationSettings.bundle", "PlugIns/LiveLearnTranslationSettings.bundle")]),
        "dictation": (26, "arm64", [
            (ROOT / "build/components/dictation/LiveLearnDictation", "Helpers/LiveLearnDictation"),
            (ROOT / "build/components/chatterfly/LiveLearnChatterfly", "Helpers/LiveLearnChatterfly"),
            (ROOT / "build/components/dictation/libopus.0.dylib", "Frameworks/libopus.0.dylib"),
            (ROOT / "build/components/dictation/Opus-LICENSE.txt", "LICENSES/Opus.txt")]),
        "browserExtension": (15, "universal", [(ROOT / "build/BrowserExtension", "BrowserExtension")]),
    }
    artifacts = []
    for identity, (minimum, architecture, inputs) in definitions.items():
        folder = stage / identity
        if folder.exists():
            shutil.rmtree(folder)
        folder.mkdir(parents=True)
        if identity == "dictation":
            inputs += [(p, "Helpers/" + p.name) for p in (ROOT / "build/components/chatterfly").glob("*.bundle")]
        for original, relative in inputs:
            target = folder / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            if original.is_dir():
                shutil.copytree(original, target, symlinks=True)
            else:
                shutil.copy2(original, target)
        shutil.copy2(ROOT / "LICENSE", folder / "LICENSE")
        (folder / "SOURCE.txt").write_text(
            "Corresponding source, build scripts and dependency notices:\n"
            "https://github.com/fantay0312/LiveLearn\n"
            f"Module version: {args.version}; release tag: {args.tag}\n"
            "See the release's source-commit.txt for the exact source revision.\n"
        )
        filename = f"LiveLearn-{identity}-{args.version}-{architecture}.zip"
        path = output / filename
        expanded = archive_tree(folder, path)
        artifacts.append(dict(id=identity, version=args.version,
            url=f"https://github.com/fantay0312/LiveLearn/releases/download/{args.tag}/{filename}",
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(), bytes=path.stat().st_size,
            expandedBytes=expanded, minimumMacOS=minimum, architecture=architecture, apiVersion=1))
        print(identity, path.stat().st_size, "download bytes;", expanded, "expanded bytes")
    (output / "catalog-payload.json").write_text(json.dumps(dict(schema=1, modules=artifacts), indent=2) + "\n")


if __name__ == "__main__":
    main()
