#!/usr/bin/env python3
"""Offline regression checks for depth-model selection and build integrity."""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
