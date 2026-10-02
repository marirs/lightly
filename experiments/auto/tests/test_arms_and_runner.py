import json
import os

import numpy as np
from PIL import Image

from lightly_auto.arms import LevelsGreyWorldControlArm, OriginalArm, lut_from_function
from lightly_auto.manifest import MANIFEST_COLUMNS, file_sha256, write_manifest
from lightly_auto.paths import ia3dlut as ia


def test_lut_from_identity_function_is_reference_identity():
    np.testing.assert_array_equal(lut_from_function(lambda rgb: rgb), ia.identity_lut())


def test_original_arm_is_unchanged_and_not_ai_auto():
    image = np.random.default_rng(1).integers(0, 256, (20, 30, 3), dtype=np.uint8)
    arm = OriginalArm()
    np.testing.assert_array_equal(arm.render(image).image, image)
    assert arm.describe()["is_ai_auto"] is False and "NOT AI Auto" in arm.label


def test_control_arm_is_labelled_non_learned_and_neutralises_a_cast_partially():
    arm = LevelsGreyWorldControlArm()
    assert arm.is_ai_auto is False and "non-learned" in arm.label and "NOT AI Auto" in arm.label
    rng = np.random.default_rng(2)
    grey = rng.uniform(0.1, 0.9, (64, 64, 1)).repeat(3, -1)
    cast = np.clip(grey * np.array([1.15, 1.0, 0.85]), 0, 1)
    out = arm.render((cast * 255).round().astype(np.uint8)).image.astype(float)
    red_blue_gap_before = (cast[..., 0] - cast[..., 2]).mean() * 255
    red_blue_gap_after = (out[..., 0] - out[..., 2]).mean()
    assert 0 < red_blue_gap_after < red_blue_gap_before


def test_runner_end_to_end_on_tiny_manifest(tmp_path):
    import run_eval
    rng = np.random.default_rng(3)
    rows = []
    for index, rubric_class in enumerate(["already_good", "night"]):
        path = tmp_path / f"img{index}.png"
        Image.fromarray(rng.integers(20, 200, (48, 64, 3), dtype=np.uint8)).save(path)
        row = {c: "" for c in MANIFEST_COLUMNS}
        row.update(image_id=f"img{index}", source_path=str(path), sha256=file_sha256(str(path)),
                   rubric_class=rubric_class, split="dev", source_tier="synthetic_test", permitted_uses="eval")
        rows.append(row)
    manifest = tmp_path / "manifest.csv"
    write_manifest(str(manifest), rows)
    summary = run_eval.main(["--manifest", str(manifest), "--arms", "original,control_levels_greyworld",
                             "--out", str(tmp_path / "out"), "--faces", str(tmp_path / "none.json"), "--threads", "1"])
    original = summary["arms"][0]
    assert original["arm"]["is_ai_auto"] is False
    by_class = {c["rubric_class"]: c for c in original["classes"]}
    assert by_class["already_good"]["n_pass"] == 1 and by_class["night"]["n_pass"] == 1
    assert os.path.exists(tmp_path / "out" / "summary.md")
    assert json.load(open(tmp_path / "out" / "summary.json"))["manifest"]["n_images"] == 2
