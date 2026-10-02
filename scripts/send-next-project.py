#!/usr/bin/env python3
"""Copy a Next 15 or 16 project to ComputeBridge's iPhone Node runtime and sync edits."""

import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path, PurePosixPath
import sys
import tarfile
import tempfile
import time
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen

EXCLUDED_DIRS = {".git", ".next", "node_modules/.cache"}
EXCLUDED_FILES = {".npmrc", ".DS_Store"}


def excluded(relative: Path) -> bool:
    parts = relative.parts
    if any(part in {".git", ".next"} for part in parts):
        return True
    if len(parts) >= 2 and parts[:2] == ("node_modules", ".cache"):
        return True
    return any(part.startswith(".env") or part in EXCLUDED_FILES for part in parts)


def is_wasm_package(relative: Path) -> bool:
    return relative.parts[:3] == ("node_modules", "@next", "swc-wasm-nodejs")


def project_files(folder: Path, include_dependencies: bool, omit_wasm: bool = False):
    for root, directories, filenames in os.walk(folder):
        root_path = Path(root)
        relative_root = root_path.relative_to(folder)
        directories[:] = sorted(
            directory for directory in directories
            if not excluded(relative_root / directory)
            and not (omit_wasm and is_wasm_package(relative_root / directory))
            and (include_dependencies or directory != "node_modules")
        )
        for filename in sorted(filenames):
            relative = relative_root / filename
            if not excluded(relative) and not (omit_wasm and is_wasm_package(relative)):
                yield relative


def download_wasm_package(version: str, destination: Path):
    metadata_url = "https://registry.npmjs.org/" + quote("@next/swc-wasm-nodejs", safe="") + "/" + quote(version, safe="")
    with urlopen(Request(metadata_url, headers={"User-Agent": "ComputeBridge"}), timeout=30) as response:
        metadata = json.load(response)
    if metadata.get("version") != version:
        raise RuntimeError(f"The npm registry returned a different SWC WASM version for {version}")
    distribution = metadata.get("dist", {})
    tarball_url = distribution.get("tarball", "")
    integrity = distribution.get("integrity", "")
    parsed = urlsplit(tarball_url)
    if parsed.scheme != "https" or parsed.hostname != "registry.npmjs.org" or not integrity.startswith("sha512-"):
        raise RuntimeError("The npm registry did not provide a trusted SWC WASM package")
    digest = hashlib.sha512()
    size = 0
    with urlopen(Request(tarball_url, headers={"User-Agent": "ComputeBridge"}), timeout=120) as response, destination.open("wb") as output:
        while chunk := response.read(1024 * 1024):
            size += len(chunk)
            if size > 512 * 1024 * 1024:
                raise RuntimeError("The SWC WASM package is too large")
            digest.update(chunk)
            output.write(chunk)
    if base64.b64encode(digest.digest()).decode() != integrity.removeprefix("sha512-"):
        raise RuntimeError("The SWC WASM package checksum did not match npm")
    with tarfile.open(destination, "r:gz") as package:
        manifest = package.extractfile("package/package.json")
        if manifest is None or json.load(manifest).get("version") != version:
            raise RuntimeError("The downloaded SWC WASM package has the wrong version")
    print(f"Fetched matching SWC WASM {version} ({size / 1024 / 1024:.1f} MB)", flush=True)


def add_wasm_package(archive: tarfile.TarFile, package_path: Path):
    with tarfile.open(package_path, "r:gz") as package:
        for member in package:
            parts = PurePosixPath(member.name).parts
            if not parts or parts[0] != "package" or any(part in {"", ".", ".."} for part in parts):
                raise RuntimeError("The SWC WASM package contains an invalid path")
            if len(parts) == 1:
                continue
            if not (member.isfile() or member.isdir()):
                raise RuntimeError("The SWC WASM package contains an unsupported entry")
            source = package.extractfile(member) if member.isfile() else None
            member.name = str(PurePosixPath("project", "node_modules", "@next", "swc-wasm-nodejs", *parts[1:]))
            member.pax_headers = {}
            archive.addfile(member, source)


def request(host: str, token: str, method: str, route: str, body=b"", timeout=120):
    connection = http.client.HTTPConnection(host, 3100, timeout=timeout)
    connection.request(method, route, body=body, headers={
        "x-bridge-token": token,
        "content-type": "application/octet-stream",
        "content-length": str(len(body)),
    })
    response = connection.getresponse()
    content = response.read()
    connection.close()
    parsed = json.loads(content)
    if response.status >= 400:
        raise RuntimeError(f"iPhone returned {response.status}: {parsed.get('error', parsed)}")
    return parsed


def create_archive(folder: Path, archive_path: Path, wasm_package: Path = None):
    with tarfile.open(archive_path, "w:gz", compresslevel=4) as archive:
        archive.add(folder, arcname="project", recursive=False)
        for relative in project_files(folder, include_dependencies=True, omit_wasm=wasm_package is not None):
            absolute = folder / relative
            archive.add(absolute, arcname=str(Path("project") / relative), recursive=False)
        if wasm_package is not None:
            add_wasm_package(archive, wasm_package)
    return archive_path.stat().st_size


def upload_archive(host: str, token: str, archive_path: Path, size: int):
    connection = http.client.HTTPConnection(host, 3100, timeout=1200)
    connection.putrequest("PUT", "/project")
    connection.putheader("x-bridge-token", token)
    connection.putheader("content-type", "application/gzip")
    connection.putheader("content-length", str(size))
    connection.endheaders()
    with archive_path.open("rb") as archive:
        while chunk := archive.read(1024 * 1024):
            connection.send(chunk)
    response = connection.getresponse()
    content = response.read()
    connection.close()
    parsed = json.loads(content)
    if response.status >= 400:
        raise RuntimeError(f"iPhone returned {response.status}: {parsed.get('error', parsed)}")
    return parsed


def snapshot(folder: Path):
    result = {}
    for relative in project_files(folder, include_dependencies=False):
        try:
            stat = (folder / relative).stat()
        except FileNotFoundError:
            continue
        result[str(relative)] = (stat.st_mtime_ns, stat.st_size)
    return result


def sync_changes(folder: Path, host: str, token: str, before: dict, after: dict):
    for relative in sorted(after.keys() - before.keys() | {name for name in after.keys() & before.keys() if after[name] != before[name]}):
        source = folder / relative
        if not source.is_file():
            continue
        route = "/file/" + quote(relative, safe="/")
        request(host, token, "PUT", route, source.read_bytes())
        print(f"Synced {relative}", flush=True)
    for relative in sorted(before.keys() - after.keys()):
        route = "/file/" + quote(relative, safe="/")
        request(host, token, "DELETE", route)
        print(f"Removed {relative}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("folder", type=Path, help="Mac folder containing package.json")
    parser.add_argument("--host", required=True, help="iPhone IP or .local hostname")
    parser.add_argument("--token", default=os.environ.get("COMPUTEBRIDGE_PAIRING_TOKEN"),
                        help="Pairing token shown by the iPhone app")
    parser.add_argument("--once", action="store_true", help="Exit after the initial transfer and start")
    args = parser.parse_args()
    if not args.token:
        parser.error("Enter --token or set COMPUTEBRIDGE_PAIRING_TOKEN")
    parsed_host = urlsplit(args.host if "://" in args.host else "http://" + args.host)
    if not parsed_host.hostname:
        parser.error("Enter the iPhone address shown in the app")
    args.host = parsed_host.hostname
    folder = args.folder.expanduser().resolve()
    package = json.loads((folder / "package.json").read_text())
    if "next dev" not in package.get("scripts", {}).get("dev", ""):
        parser.error("The selected folder's dev script must use next dev")
    if not (folder / "node_modules/next/package.json").is_file():
        parser.error("Run npm install on the Mac before transferring this project")
    version = json.loads((folder / "node_modules/next/package.json").read_text())["version"]
    if not version.startswith(("15.", "16.")):
        parser.error(f"This prototype supports Next.js 15 or 16, found {version}")
    needs_wasm_download = False
    if version.startswith("16."):
        wasm_manifest = folder / "node_modules/@next/swc-wasm-nodejs/package.json"
        needs_wasm_download = not wasm_manifest.is_file() or json.loads(wasm_manifest.read_text()).get("version") != version
    status = request(args.host, args.token, "GET", "/status")
    if status.get("platform") != "ios":
        parser.error("The target is not running iOS Node")
    print(f"Packaging {folder.name}; excluding .env files, .npmrc, .git and .next", flush=True)
    with tempfile.TemporaryDirectory(prefix="computebridge-next-") as temporary:
        wasm_package = None
        if needs_wasm_download:
            print(f"Fetching @next/swc-wasm-nodejs@{version} for iPhone", flush=True)
            wasm_package = Path(temporary) / "swc-wasm-nodejs.tgz"
            download_wasm_package(version, wasm_package)
        archive_path = Path(temporary) / "project.tar.gz"
        size = create_archive(folder, archive_path, wasm_package)
        print(f"Sending {size / 1024 / 1024:.1f} MB to {args.host}", flush=True)
        upload_archive(args.host, args.token, archive_path, size)
    print("Starting Next.js on iPhone", flush=True)
    request(args.host, args.token, "POST", "/start")
    for _ in range(90):
        time.sleep(1)
        status = request(args.host, args.token, "GET", "/status")
        if status["phase"] == "ready":
            break
        if status["phase"] == "error":
            raise RuntimeError(status["message"])
    else:
        raise RuntimeError("Next.js did not become ready within 90 seconds")
    print(f"Next.js is ready at http://{args.host}:3001", flush=True)
    if args.once:
        return
    print("Watching the Mac folder for edits. Press Ctrl-C to stop syncing.", flush=True)
    previous = snapshot(folder)
    try:
        while True:
            time.sleep(1)
            status = request(args.host, args.token, "GET", "/status")
            if status["phase"] in {"stopping", "stopped"}:
                print("Next.js stopped on iPhone; source sync ended.", flush=True)
                return
            if status["phase"] == "error":
                raise RuntimeError(status["message"])
            current = snapshot(folder)
            sync_changes(folder, args.host, args.token, previous, current)
            previous = current
    except KeyboardInterrupt:
        print("Stopped syncing; the iPhone server remains open.", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError, json.JSONDecodeError) as error:
        print(f"ComputeBridge: {error}", file=sys.stderr)
        sys.exit(1)
