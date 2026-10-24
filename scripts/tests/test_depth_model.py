#!/usr/bin/env python3
"""Offline regression checks for depth-model selection and build integrity."""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("depth_model", Path(__file__).parents[1] / "depth_model.py")
depth = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(depth)
CATALOG = json.loads((Path(__file__).parents[1] / "depth-models.json").read_text())


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        (self.root / "scripts/depth-models.json").write_text(json.dumps(CATALOG))
        self.patcher = patch.object(depth, "ROOT", self.root)
        self.patcher.start()
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.patcher.stop()
        self.temporary.cleanup()

    def local(self):
        model = copy.deepcopy(CATALOG["models"]["SmallF32"])
        (self.root / "depth-model.local.json").write_text(json.dumps({"schemaVersion": 1, "model": model}))
        return model

    def test_default_and_explicit_presets(self):
        self.assertIn("SmallF16", depth.select_model()[0])
        os.environ["PIXELBOOTH_DEPTH_VARIANT"] = "SmallF32"
        self.assertEqual(depth.select_model()[1], CATALOG["models"]["SmallF32"])

    def test_explicit_preset_bypasses_local_override(self):
        local = self.local()
        self.assertEqual(depth.select_model()[1], local)
        os.environ["PIXELBOOTH_DEPTH_VARIANT"] = "SmallF16"
        self.assertEqual(depth.select_model()[1], CATALOG["models"]["SmallF16"])

    def test_explicit_override_takes_precedence_over_default_local(self):
        self.local()
        explicit = self.root / "explicit.json"
        model = copy.deepcopy(CATALOG["models"]["SmallF16"])
        explicit.write_text(json.dumps({"schemaVersion": 1, "model": model}))
        os.environ["PIXELBOOTH_DEPTH_OVERRIDE"] = str(explicit)
        self.assertEqual(depth.select_model()[1], model)

    def test_conflicting_explicit_selectors_fail(self):
        os.environ.update(PIXELBOOTH_DEPTH_VARIANT="SmallF16", PIXELBOOTH_DEPTH_OVERRIDE="private.json")
        with self.assertRaises(ValueError):
            depth.select_model()

    def test_missing_explicit_override_fails_without_fallback(self):
        os.environ["PIXELBOOTH_DEPTH_OVERRIDE"] = "missing.json"
        with self.assertRaises(FileNotFoundError):
            depth.select_model()

    def test_unknown_variant_fails(self):
        os.environ["PIXELBOOTH_DEPTH_VARIANT"] = "Large"
        with self.assertRaises(ValueError):
            depth.select_model()


class ManifestTests(unittest.TestCase):
    def test_runtime_schema_mismatch_rejected_before_fetch(self):
        mutations = [
            lambda m: m["descriptor"].update(schemaVersion=True),
            lambda m: m["descriptor"].update(inputWidth=True),
            lambda m: m["descriptor"].update(outputNormalizedByMaximum="false"),
            lambda m: m["descriptor"].update(modelIdentifier="bad\nidentifier"),
            lambda m: m["descriptor"].update(modelVersionString=""),
            lambda m: m["descriptor"].update(sourceWeightsSHA256="0" * 64),
            lambda m: m["source"].update(baseURL=m["source"]["baseURL"].replace(m["descriptor"]["sourceRevision"], "main")),
            lambda m: m["source"]["files"][0].update(path="../Manifest.json"),
            lambda m: m["descriptor"].update(outputRepresentation="multiArrayFloat16", outputShape=[1, 1, 1, 392, 518]),
        ]
        for mutate in mutations:
            with self.subTest(mutation=mutate):
                model = copy.deepcopy(CATALOG["models"]["SmallF16"])
                mutate(model)
                with self.assertRaises(ValueError):
                    depth.validate_model(model)

    def test_utf8_and_composed_provenance_limits(self):
        for identifier in ("\U0001f642" * 1025, "a" * 4000):
            with self.subTest(identifier_bytes=len(identifier.encode("utf-8"))):
                model = copy.deepcopy(CATALOG["models"]["SmallF16"])
                model["descriptor"]["modelIdentifier"] = identifier
                with self.assertRaises(ValueError):
                    depth.validate_model(model)

    def test_license_or_weights_change_changes_cache_identity(self):
        model = copy.deepcopy(CATALOG["models"]["SmallF16"])
        original = hashlib.sha256(depth.canonical(model)).hexdigest()
        model["license"]["sha256"] = "0" * 64
        self.assertNotEqual(original, hashlib.sha256(depth.canonical(model)).hexdigest())

    def test_float32_preset_has_actual_half_float_image_output(self):
        self.assertEqual(CATALOG["models"]["SmallF32"]["descriptor"]["outputRepresentation"], "imageFloat16")


class IntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.temporary.name)
        self.patcher = patch.object(depth, "ROOT", self.root)
        self.patcher.start()

    def tearDown(self):
        self.patcher.stop()
        self.temporary.cleanup()

    def test_checksum_failure_preserves_existing_cache(self):
        destination = self.root / "cached.bin"
        destination.write_bytes(b"old recoverable contents")
        def download(arguments, **unused):
            Path(arguments[arguments.index("--output") + 1]).write_bytes(b"wrong download")
        with patch.object(depth.subprocess, "run", side_effect=download):
            with self.assertRaises(ValueError):
                depth.fetch("https://example.test/fixed", destination, "0" * 64)
        self.assertEqual(destination.read_bytes(), b"old recoverable contents")
        self.assertFalse(list(self.root.glob(".download.*")))

    def test_cached_source_is_rehashed(self):
        source = self.root / "weights.bin"
        source.write_bytes(b"original")
        expected = depth.digest(source)
        self.assertTrue(depth.matches(source, expected, 8))
        source.write_bytes(b"modified")
        self.assertFalse(depth.matches(source, expected, 8))

    def test_cache_symlink_rejected(self):
        source = self.root / "source.bin"
        source.write_bytes(b"source")
        link = self.root / "weights.bin"
        link.symlink_to(source)
        with self.assertRaises(ValueError):
            depth.matches(link, depth.digest(source))

    def test_archive_traversal_rejected_without_extraction(self):
        archive = self.root / "source.mlpackage.tar.gz"
        with tarfile.open(archive, "w:gz") as output:
            member = tarfile.TarInfo("../outside.bin")
            member.size = 4
            output.addfile(member, io.BytesIO(b"evil"))
        model = copy.deepcopy(CATALOG["models"]["SmallF16"])
        model["source"] = {"kind": "tar.gz", "url": "https://example.test/fixed", "sha256": depth.digest(archive), "size": archive.stat().st_size, "files": model["source"]["files"]}
        with patch.object(depth, "fetch"):
            with self.assertRaises(ValueError):
                depth.fetch_package(model, self.root)
        self.assertFalse((self.root.parent / "outside.bin").exists())

    def test_selection_file_records_immutable_directory(self):
        destination = self.root / "selection.txt"
        destination.write_text("stale directory")
        immutable = self.root / "configurations/identity"
        depth.write_selection_file(destination, immutable)
        self.assertEqual(destination.read_text(), str(immutable) + "\n")
        self.assertFalse(list(self.root.glob(".depth-selection.*")))

    def test_corrupt_cached_manifest_invalidates_without_crashing(self):
        model = copy.deepcopy(CATALOG["models"]["SmallF16"])
        compiled = self.root / "PixelBoothDepth.mlmodelc"
        (compiled / "weights").mkdir(parents=True)
        (compiled / "coremldata.bin").write_bytes(b"model")
        (compiled / "weights/weight.bin").write_bytes(b"weights")
        (self.root / "DepthModel.json").write_text(json.dumps(model["descriptor"]))
        license_file = self.root / "model-LICENSE"
        license_file.write_bytes(b"license")
        model["license"]["sha256"] = depth.digest(license_file)
        expected_build = {"model": model, "toolchain": {}, "metadata": {}}
        (self.root / ".build-configuration.json").write_text(json.dumps(expected_build))
        hashes = self.root / ".files.sha256.json"
        hashes.write_text(json.dumps(depth.tree_hashes(self.root)))
        self.assertTrue(depth.compiled_cache_valid(self.root, model, expected_build))
        hashes.write_text("broken JSON")
        self.assertFalse(depth.compiled_cache_valid(self.root, model, expected_build))
        hashes.write_text(json.dumps(depth.tree_hashes(self.root)))
        (self.root / "DepthModel.json").write_text("broken JSON")
        self.assertFalse(depth.compiled_cache_valid(self.root, model, expected_build))

    def test_compiled_tree_hash_detects_mutation(self):
        model = self.root / "PixelBoothDepth.mlmodelc"
        model.mkdir()
        (model / "coremldata.bin").write_bytes(b"original")
        original = depth.tree_hashes(self.root)
        (model / "coremldata.bin").write_bytes(b"modified")
        self.assertNotEqual(original, depth.tree_hashes(self.root))


class CompilerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(dir="/private/tmp")
        self.root = Path(self.temporary.name)
        self.patcher = patch.object(depth, "ROOT", self.root)
        self.patcher.start()
        self.source = self.root / "Tools/CompileDepthModel/CompileDepthModel.swift"
        self.source.parent.mkdir(parents=True)
        self.source.write_text("public helper source")

    def tearDown(self):
        self.patcher.stop()
        self.temporary.cleanup()

    def output(self, *arguments):
        return {
            ("xcrun", "--sdk", "macosx", "--show-sdk-path"): "/sdk",
            ("xcrun", "--sdk", "macosx", "--show-sdk-version"): "27.0",
            ("sw_vers", "-buildVersion"): "26A434",
            ("xcrun", "--find", "swiftc"): "/clt/swiftc",
            ("xcrun", "swiftc", "--version"): "Swift 6.4",
            ("xcrun", "coremlcompiler", "version"): "compiler version",
        }[arguments]

    def test_command_line_tools_use_public_helper_with_runtime_identity(self):
        helper = self.root / "helper"
        with patch.object(depth, "coremlcompiler_path", return_value=None), patch.object(depth, "command", side_effect=self.output), patch.object(depth, "prepare_public_helper", return_value=(helper, "a" * 64)):
            toolchain, selected = depth.prepare_compiler()
        self.assertEqual(selected, helper)
        self.assertEqual(toolchain["backend"], "publicCoreMLAPI")
        self.assertEqual(toolchain["osBuild"], "26A434")
        self.assertEqual(toolchain["helperSourceSHA256"], depth.digest(self.source))
        self.assertEqual(toolchain["helperExecutableSHA256"], "a" * 64)

    def test_full_xcode_retains_coremlcompiler_route(self):
        with patch.object(depth, "coremlcompiler_path", return_value="/xcode/coremlcompiler"), patch.object(depth, "command", side_effect=self.output), patch.object(depth, "prepare_public_helper") as helper:
            toolchain, selected = depth.prepare_compiler()
        self.assertIsNone(selected)
        self.assertEqual(toolchain["backend"], "coremlcompiler")
        self.assertEqual(toolchain["compilerVersion"], "compiler version")
        helper.assert_not_called()

    def test_api_model_cache_identity_tracks_helper_source(self):
        with patch.object(depth, "coremlcompiler_path", return_value=None), patch.object(depth, "command", side_effect=self.output), patch.object(depth, "prepare_public_helper", return_value=(self.root / "helper", "a" * 64)):
            original = depth.prepare_compiler()[0]
            self.source.write_text("revised helper source")
            revised = depth.prepare_compiler()[0]
        self.assertNotEqual(depth.canonical(original), depth.canonical(revised))

    def test_wrong_sdk_fails_before_preparation(self):
        def wrong_sdk(*arguments):
            return "26.0" if arguments[-1] == "--show-sdk-version" else self.output(*arguments)
        with patch.object(depth, "command", side_effect=wrong_sdk), patch.object(depth, "prepare_public_helper") as helper:
            with self.assertRaises(ValueError):
                depth.prepare_compiler()
        helper.assert_not_called()

    def test_helper_executable_is_rehashed_before_reuse(self):
        def compile_helper(arguments, **unused):
            executable = Path(arguments[arguments.index("-o") + 1])
            executable.write_bytes(b"compiled helper")
            executable.chmod(0o700)
        with patch.object(depth.subprocess, "run", side_effect=compile_helper) as run:
            helper, checksum = depth.prepare_public_helper({"sdkPath": "/sdk"}, self.source)
            self.assertEqual(depth.prepare_public_helper({"sdkPath": "/sdk"}, self.source), (helper, checksum))
            self.assertEqual(run.call_count, 1)
            helper.write_bytes(b"mutated")
            rebuilt, new_checksum = depth.prepare_public_helper({"sdkPath": "/sdk"}, self.source)
            self.assertEqual(run.call_count, 2)
            self.assertEqual(rebuilt.read_bytes(), b"compiled helper")
            self.assertEqual(new_checksum, checksum)

    def test_helper_build_failure_preserves_prior_cache(self):
        identity = hashlib.sha256(depth.canonical({"sdkPath": "/sdk"})).hexdigest()
        prior = self.root / ".vendor-cache/depth/compiler-helpers" / identity / "compile-depth-model"
        prior.parent.mkdir(parents=True)
        prior.write_bytes(b"prior artifact")
        with patch.object(depth.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "swiftc")):
            with self.assertRaises(subprocess.CalledProcessError):
                depth.prepare_public_helper({"sdkPath": "/sdk"}, self.source)
        self.assertEqual(prior.read_bytes(), b"prior artifact")

    def test_public_metadata_validation_still_rejects_schema_mismatch(self):
        descriptor = CATALOG["models"]["SmallF16"]["descriptor"]
        metadata = [{
            "inputSchema": [{"type": "Image", "colorspace": "RGB", "name": "image", "width": 518, "height": 392, "hasSizeFlexibility": "0"}],
            "outputSchema": [{"type": "Image", "colorspace": "Grayscale16Half", "name": "depth", "width": 518, "height": 392, "hasSizeFlexibility": "0"}],
            "version": "2.0",
        }]
        with patch.object(depth.subprocess, "check_output", side_effect=lambda *args, **kwargs: json.dumps(metadata)) as inspect:
            self.assertEqual(depth.validate_metadata(self.root, descriptor, self.root / "helper"), metadata[0])
            metadata[0]["outputSchema"][0]["hasSizeFlexibility"] = "1"
            with self.assertRaises(ValueError):
                depth.validate_metadata(self.root, descriptor, self.root / "helper")
        self.assertEqual(inspect.call_args.args[0][1], "metadata")


if __name__ == "__main__":
    unittest.main()
