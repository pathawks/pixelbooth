#!/usr/bin/env python3
"""Fetch, verify, and compile one pinned build-time depth model.

PIXELBOOTH_DEPTH_VARIANT explicitly selects a checked-in preset and bypasses the
personal depth-model.local.json. PIXELBOOTH_DEPTH_OVERRIDE selects another local
manifest; specifying both environment variables is an error. With neither set,
the personal manifest is used if present, otherwise SmallF16 is selected.
"""

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
REVISION = re.compile(r"[0-9a-f]{40}\Z")
PACKAGE_FILES = {
    "Manifest.json",
    "Data/com.apple.CoreML/model.mlmodel",
    "Data/com.apple.CoreML/weights/weight.bin",
}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def digest(path):
    checksum = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            checksum.update(chunk)
    return checksum.hexdigest()


def fail(message):
    raise ValueError(message)


def safe_relative(value):
    path = PurePosixPath(value)
    if not value or path.is_absolute() or ".." in path.parts or "\\" in value:
        fail(f"Unsafe relative model path: {value!r}")
    if str(path) != value:
        fail(f"Noncanonical model path: {value!r}")
    return path


def no_symlinks(path):
    for candidate in (path, *path.parents):
        if candidate.is_symlink():
            fail(f"Model input/cache path must not be a symlink: {candidate}")
        if candidate == ROOT:
            break


def checked_hash(value):
    if not isinstance(value, str) or not SHA256.fullmatch(value):
        fail("Every model and license file requires a lowercase SHA-256")


def pinned_url(value, revision=None):
    parsed = urlparse(value)
    if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
        fail("Model downloads require an HTTPS URL without credentials")
    if revision and revision not in parsed.path.split("/"):
        fail("The model download URL must contain the exact source revision")


def select_model():
    variant = os.environ.get("PIXELBOOTH_DEPTH_VARIANT")
    override = os.environ.get("PIXELBOOTH_DEPTH_OVERRIDE")
    if variant is not None and override is not None:
        fail("Set only PIXELBOOTH_DEPTH_VARIANT or PIXELBOOTH_DEPTH_OVERRIDE")
    if variant is not None:
        catalog = json.loads((ROOT / "scripts/depth-models.json").read_text())
        if catalog.get("schemaVersion") != 1 or variant not in catalog["models"]:
            fail("PIXELBOOTH_DEPTH_VARIANT must be SmallF16 or SmallF32")
        selected = catalog["models"][variant]
        label = variant
    else:
        local = Path(override) if override else ROOT / "depth-model.local.json"
        if not local.is_absolute():
            local = ROOT / local
        if override is not None or local.exists():
            no_symlinks(local)
            manifest = json.loads(local.read_text())
            if set(manifest) != {"schemaVersion", "model"} or manifest["schemaVersion"] != 1:
                fail("Local model manifest requires schemaVersion=1 and model")
            selected = manifest["model"]
            label = f"local override ({local.name})"
        else:
            catalog = json.loads((ROOT / "scripts/depth-models.json").read_text())
            selected = catalog["models"]["SmallF16"]
            label = "SmallF16 (default)"
    validate_model(selected)
    return label, selected


def validate_model(model):
    if set(model) != {"packageName", "source", "license", "descriptor"}:
        fail("Model entry must contain packageName, source, license, and descriptor")
    package = safe_relative(model["packageName"])
    if len(package.parts) != 1 or package.suffix != ".mlpackage":
        fail("packageName must be one .mlpackage filename")
    descriptor = model["descriptor"]
    required = {
        "schemaVersion", "modelResourceName", "modelIdentifier", "sourceRevision",
        "sourceModelSHA256", "sourceWeightsSHA256", "licenseIdentifier",
        "inputFeatureName", "inputWidth", "inputHeight", "outputFeatureName",
        "outputWidth", "outputHeight", "outputRepresentation", "outputNormalizedByMaximum",
    }
    if not required <= descriptor.keys() or descriptor.keys() - required - {"outputShape", "modelVersionString"}:
        fail("Incomplete or unknown runtime depth model descriptor fields")
    if type(descriptor["schemaVersion"]) is not int or descriptor["schemaVersion"] != 1 or descriptor["modelResourceName"] != "PixelBoothDepth":
        fail("Unsupported runtime descriptor version or resource name")
    for key in ("modelIdentifier", "licenseIdentifier", "inputFeatureName", "outputFeatureName"):
        value = descriptor[key]
        if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in value):
            fail(f"Invalid descriptor text: {key}")
    version = descriptor.get("modelVersionString")
    if version is not None and (not isinstance(version, str) or not version or len(version.encode("utf-8")) > 4096 or any(ord(c) < 32 or ord(c) == 127 for c in version)):
        fail("Invalid modelVersionString")
    revision = descriptor["sourceRevision"]
    if not isinstance(revision, str) or not REVISION.fullmatch(revision):
        fail("Model sourceRevision requires an immutable 40-character revision")
    for key in ("sourceModelSHA256", "sourceWeightsSHA256"):
        checked_hash(descriptor[key])
    for prefix in ("input", "output"):
        width, height = descriptor[prefix + "Width"], descriptor[prefix + "Height"]
        if type(width) is not int or type(height) is not int or min(width, height) < 1 or max(width, height) > 4096 or width * height > 1_048_576:
            fail("Invalid or excessive model geometry")
    if type(descriptor["outputNormalizedByMaximum"]) is not bool:
        fail("outputNormalizedByMaximum must be a Boolean")
    representation = descriptor["outputRepresentation"]
    if representation not in ("imageFloat16", "imageFloat32", "multiArrayFloat16", "multiArrayFloat32"):
        fail("Unsupported outputRepresentation")
    shape = descriptor.get("outputShape")
    if representation.startswith("multiArray"):
        if not isinstance(shape, list) or not 2 <= len(shape) <= 4 or any(type(n) is not int for n in shape) or shape[:-2] != [1] * (len(shape) - 2) or shape[-2:] != [descriptor["outputHeight"], descriptor["outputWidth"]]:
            fail("MultiArray outputShape must have singleton leading axes and exact height/width")
    elif shape is not None:
        fail("Image outputs must not specify outputShape")
    provenance = (
        f'{descriptor["modelIdentifier"]}; sourceRevision={revision}; '
        f'sourceModelSHA256={descriptor["sourceModelSHA256"]}; '
        f'sourceWeightsSHA256={descriptor["sourceWeightsSHA256"]}; '
        f'license={descriptor["licenseIdentifier"]}'
    )
    if len(provenance.encode("utf-8")) > 4096:
        fail("Composed model provenance exceeds the runtime text bound")
    if len((json.dumps(descriptor, indent=2) + "\n").encode("utf-8")) > 65_536:
        fail("Generated runtime descriptor exceeds its size bound")
    source = model["source"]
    kind = source.get("kind")
    allowed = {"kind", "baseURL", "files"} if kind == "files" else {"kind", "url", "sha256", "size", "files"}
    if kind not in ("files", "tar.gz") or set(source) != allowed:
        fail("Source must be pinned files or a pinned tar.gz with explicit package files")
    pinned_url(source["baseURL"] if kind == "files" else source["url"], revision)
    if kind == "tar.gz":
        checked_hash(source["sha256"])
        if type(source["size"]) is not int or not 0 < source["size"] <= 4_000_000_000:
            fail("Archive requires a bounded size")
    files = source["files"]
    if not isinstance(files, list) or len(files) != 3:
        fail("Exactly the manifest, model specification, and weights must be pinned")
    by_path = {}
    for entry in files:
        if set(entry) != {"path", "sha256", "size"}:
            fail("Every model file requires path, sha256, and size")
        safe_relative(entry["path"])
        checked_hash(entry["sha256"])
        if type(entry["size"]) is not int or not 0 < entry["size"] <= 4_000_000_000:
            fail("Every model file requires a bounded size")
        by_path[entry["path"]] = entry
    if set(by_path) != PACKAGE_FILES:
        fail("Unexpected or duplicate model package files")
    if by_path["Data/com.apple.CoreML/model.mlmodel"]["sha256"] != descriptor["sourceModelSHA256"] or by_path["Data/com.apple.CoreML/weights/weight.bin"]["sha256"] != descriptor["sourceWeightsSHA256"]:
        fail("Runtime source hashes must match the fetched specification and weights")
    license_info = model["license"]
    if set(license_info) != {"url", "sha256"}:
        fail("License requires URL and SHA-256")
    pinned_url(license_info["url"])
    checked_hash(license_info["sha256"])


def matches(path, expected_hash, expected_size=None):
    no_symlinks(path)
    return path.is_file() and (expected_size is None or path.stat().st_size == expected_size) and digest(path) == expected_hash


def fetch(url, destination, expected_hash, expected_size=None):
    if matches(destination, expected_hash, expected_size):
        return
    destination.parent.mkdir(parents=True, exist_ok=True)
    no_symlinks(destination.parent)
    descriptor, name = tempfile.mkstemp(prefix=".download.", dir=destination.parent)
    os.close(descriptor)
    temporary = Path(name)
    try:
        subprocess.run(["curl", "--fail", "--silent", "--show-error", "--location", "--retry", "2", "--max-time", "600", "--output", str(temporary), url], check=True)
        if not matches(temporary, expected_hash, expected_size):
            fail(f"CHECKSUM OR SIZE MISMATCH: {destination.name}")
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)


def package_files_valid(package, files):
    return all(matches(package / f["path"], f["sha256"], f["size"]) for f in files)


def fetch_package(model, cache):
    package = cache / model["packageName"]
    source = model["source"]
    if source["kind"] == "files":
        for entry in source["files"]:
            fetch(source["baseURL"] + "/" + entry["path"], package / entry["path"], entry["sha256"], entry["size"])
    else:
        archive = cache / "source.mlpackage.tar.gz"
        fetch(source["url"], archive, source["sha256"], source["size"])
        if not package_files_valid(package, source["files"]):
            with tarfile.open(archive, "r:gz") as archive_file:
                members = {}
                for member in archive_file:
                    safe_relative(member.name)
                    if not member.isdir() and not member.isfile():
                        fail("Model archives must not contain symlinks, links, or devices")
                    if member.name in members:
                        fail("Duplicate archive path")
                    members[member.name] = member
                for entry in source["files"]:
                    member = members.get(model["packageName"] + "/" + entry["path"])
                    if member is None or not member.isfile() or member.size != entry["size"]:
                        fail("Archive model file missing or has unexpected size")
                    target = package / entry["path"]
                    no_symlinks(target)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with archive_file.extractfile(member) as incoming, target.open("wb") as outgoing:
                        shutil.copyfileobj(incoming, outgoing)
            if not package_files_valid(package, source["files"]):
                fail("Extracted model package did not match the pinned files")
    fetch(model["license"]["url"], cache / "model-LICENSE", model["license"]["sha256"])
    return package


def command(*arguments):
    return subprocess.check_output(arguments, text=True).strip()


def validate_metadata(package, descriptor):
    metadata = json.loads(command("xcrun", "coremlcompiler", "metadata", str(package)))
    if len(metadata) != 1 or "error" in metadata[0]:
        fail("Core ML compiler could not inspect the selected model")
    metadata = metadata[0]
    inputs, outputs = metadata.get("inputSchema", []), metadata.get("outputSchema", [])
    if len(inputs) != 1 or len(outputs) != 1:
        fail("Depth model must have one image input and one depth output")
    image, output = inputs[0], outputs[0]
    if image.get("type") != "Image" or image.get("colorspace") not in ("RGB", "BGR") or image.get("name") != descriptor["inputFeatureName"] or int(image.get("width", 0)) != descriptor["inputWidth"] or int(image.get("height", 0)) != descriptor["inputHeight"] or image.get("hasSizeFlexibility") != "0":
        fail("Actual Core ML input schema differs from the pinned descriptor")
    representation = descriptor["outputRepresentation"]
    if output.get("name") != descriptor["outputFeatureName"]:
        fail("Actual Core ML output feature differs from the descriptor")
    if representation.startswith("image"):
        expected_color = "Grayscale16Half" if representation == "imageFloat16" else "Grayscale32Float"
        valid = output.get("type") == "Image" and output.get("colorspace") == expected_color and int(output.get("width", 0)) == descriptor["outputWidth"] and int(output.get("height", 0)) == descriptor["outputHeight"] and output.get("hasSizeFlexibility") == "0"
    else:
        expected_type = "Float16" if representation == "multiArrayFloat16" else "Float32"
        valid = output.get("type") == "MultiArray" and output.get("dataType") == expected_type and json.loads(output.get("shape", "null")) == descriptor["outputShape"] and output.get("hasShapeFlexibility") == "0"
    if not valid or (descriptor.get("modelVersionString") is not None and metadata.get("version") != descriptor["modelVersionString"]):
        fail("Actual Core ML output schema or version differs from the pinned descriptor")
    return metadata


def tree_hashes(directory):
    result = {}
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            fail("Compiled model artifacts must not contain symlinks")
        if path.is_file() and path != directory / ".files.sha256.json":
            result[str(path.relative_to(directory))] = digest(path)
    return result


def compiled_cache_valid(output, model, expected_build):
    try:
        recorded = output / ".files.sha256.json"
        no_symlinks(recorded)
        actual_hashes = tree_hashes(output)
        return (
            recorded.is_file()
            and (output / "PixelBoothDepth.mlmodelc/coremldata.bin").is_file()
            and (output / "PixelBoothDepth.mlmodelc/weights/weight.bin").is_file()
            and (output / "DepthModel.json").is_file()
            and json.loads((output / "DepthModel.json").read_text()) == model["descriptor"]
            and matches(output / "model-LICENSE", model["license"]["sha256"])
            and (output / ".build-configuration.json").is_file()
            and json.loads((output / ".build-configuration.json").read_text()) == expected_build
            and json.loads(recorded.read_text()) == actual_hashes
        )
    except (ValueError, TypeError, OSError):
        return False


@contextmanager
def preparation_lock():
    lock = ROOT / ".vendor-cache/depth/.preparation.lock"
    no_symlinks(lock)
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open("a") as stream:
        fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def write_selection_file(destination, output):
    destination = Path(destination).absolute()
    if destination.is_symlink():
        fail("Selection receipt must not be a symlink")
    destination = destination.parent.resolve(strict=True) / destination.name
    no_symlinks(destination)
    descriptor, name = tempfile.mkstemp(prefix=".depth-selection.", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(str(output) + "\n")
        os.replace(name, destination)
    finally:
        Path(name).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--print-config", action="store_true", help="Validate and print the selected manifest without fetching or compiling")
    parser.add_argument("--selection-file", help="Atomically write this invocation's immutable prepared resource directory")
    options = parser.parse_args()
    if options.print_config and options.selection_file:
        parser.error("--selection-file cannot be combined with --print-config")
    label, model = select_model()
    if options.print_config:
        print(json.dumps(model, indent=2))
        return
    print(f"Depth model selection: {label}", flush=True)
    with preparation_lock():
        configuration_hash = hashlib.sha256(canonical(model)).hexdigest()
        cache = ROOT / ".vendor-cache/depth" / configuration_hash
        no_symlinks(cache)
        cache.mkdir(parents=True, exist_ok=True)
        package = fetch_package(model, cache)
        metadata = validate_metadata(package, model["descriptor"])
        toolchain = {"compiler": command("xcrun", "--find", "coremlcompiler"), "compilerVersion": command("xcrun", "coremlcompiler", "version"), "sdkPath": command("xcrun", "--sdk", "macosx", "--show-sdk-path"), "sdkVersion": command("xcrun", "--sdk", "macosx", "--show-sdk-version")}
        identity = hashlib.sha256(canonical({"model": model, "toolchain": toolchain})).hexdigest()
        build = ROOT / "vendor/build/depth"
        configurations = build / "configurations"
        no_symlinks(configurations)
        configurations.mkdir(parents=True, exist_ok=True)
        output = configurations / identity
        no_symlinks(output)
        expected_build = {"model": model, "toolchain": toolchain, "metadata": metadata}
        valid = compiled_cache_valid(output, model, expected_build)
        if not valid:
            with tempfile.TemporaryDirectory(prefix=".compile.", dir=configurations) as temporary_name:
                temporary = Path(temporary_name)
                subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(temporary)], check=True)
                compiled = temporary / (Path(model["packageName"]).stem + ".mlmodelc")
                if not (compiled / "coremldata.bin").is_file() or not (compiled / "weights/weight.bin").is_file():
                    fail("Core ML compiler did not produce a complete model")
                compiled.rename(temporary / "PixelBoothDepth.mlmodelc")
                (temporary / "DepthModel.json").write_text(json.dumps(model["descriptor"], indent=2) + "\n")
                shutil.copyfile(cache / "model-LICENSE", temporary / "model-LICENSE")
                (temporary / ".build-configuration.json").write_text(json.dumps(expected_build, indent=2) + "\n")
                (temporary / ".files.sha256.json").write_text(json.dumps(tree_hashes(temporary), indent=2) + "\n")
                if output.exists():
                    shutil.rmtree(output)
                temporary.rename(output)
        selected = build / "selected"
        if selected.exists() and not selected.is_symlink():
            fail("Refusing to replace a non-symlink selected model directory")
        temporary_link = build / (".selected." + str(os.getpid()))
        try:
            temporary_link.symlink_to(Path("configurations") / identity, target_is_directory=True)
            os.replace(temporary_link, selected)
        finally:
            temporary_link.unlink(missing_ok=True)
        if options.selection_file:
            write_selection_file(options.selection_file, output)
        print(f"Depth model ready: {output / 'PixelBoothDepth.mlmodelc'}", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (ValueError, KeyError, TypeError, OSError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"Depth model preparation failed: {error}", file=sys.stderr)
        sys.exit(1)
