"""The committed parity vectors (shared/fixtures/look-pack) are self-consistent and reproducible from their recipes.

This is the Python side of the native parity test; Swift and Kotlin run the same checks against the same files.
"""
import hashlib
import json

import numpy as np
import pytest

import build_pack
import convert
import reference_model as rm

FIXTURES = build_pack.REPO / "shared/fixtures/look-pack"
GOLDEN = json.loads((FIXTURES / "golden.json").read_text())
PARITY = json.loads((FIXTURES / "manifest-parity.json").read_text())
ENTRIES = {p["id"]: p for c in PARITY["categories"] for p in c["presets"]}
MODEL = rm.load_develop_constants()


def test_fixture_size_and_shape():
    size = sum(p.stat().st_size for p in FIXTURES.rglob("*") if p.is_file())
    assert size < 5e6
    assert 35 <= len(GOLDEN["cases"]) <= 45
    assert GOLDEN["renderingContract"]["constantsSha256"] == MODEL["constantsSha256"], "regenerate after a model change"
    assert {c["presetId"] for c in GOLDEN["cases"]} == set(ENTRIES)


def test_cases_cover_every_operator_category_and_completeness_class():
    covered = {f for c in GOLDEN["cases"] for f in c["covers"]}
    assert {f"op:{op}" for op in convert.ALL_OPERATORS} <= covered
    assert {c["category"] for c in GOLDEN["cases"]} == {c["id"] for c in PARITY["categories"]}
    assert {"completeness:complete", "completeness:approximate", "completeness:incomplete", "pv:6.7"} <= covered


@pytest.mark.parametrize("case", GOLDEN["cases"], ids=lambda c: c["presetId"])
def test_case_reproduces_from_its_recipe(case):
    entry = ENTRIES[case["presetId"]]
    data = (FIXTURES / case["lutFile"]).read_bytes()
    assert hashlib.sha256(data).hexdigest() == case["lutSha256"]
    n = GOLDEN["lut"]["dimension"]
    golden = np.frombuffer(data, dtype="<f2").astype(np.float64).reshape(n, n, n, 3)
    baked = rm.bake_global_lut(entry["recipe"], MODEL, n)
    assert np.abs(baked - golden).max() <= 2.5e-4  # float16 quantisation only
    probes = np.array(GOLDEN["probes"])
    assert np.abs(rm.develop_global(probes, entry["recipe"], MODEL) - np.array(case["probesDirect"])).max() < 1e-6
    via33 = rm.apply_lut_trilinear(rm.bake_global_lut(entry["recipe"], MODEL, 33), probes)
    assert np.abs(via33 - np.array(case["probesViaLut33"])).max() < 1e-6
    assert build_pack.look_version(entry["recipe"], MODEL, None) == entry["lookVersion"] == case["lookVersion"]


def test_portable_random_vectors():
    vectors = GOLDEN["portableRandom"]
    for x, expected in vectors["lowbias32"]:
        assert int(rm._lowbias32(x)) == expected
    g = vectors["gaussianField"]
    field = rm.gaussian_field(g["seed"], g["layer"], g["rows"], g["cols"])
    assert np.abs(field - np.array(g["values"])).max() < g["tolerance"]
