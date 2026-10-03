"""Rights and separation rules for the CC0/PD public data (PH-1 evaluation, cc0ref training references)."""
import hashlib

import numpy as np
import pytest

from data_tools.build_train_manifest import split_for
from data_tools.commons import eligible, licence_accepted, phone_brand
from eval_synthetic import frozen_degradation
from lightly_auto.manifest import TrainingRightsError, assert_training_rights


def _row(**overrides):
    row = {"image_id": "x", "source_tier": "T2_public_cc0_pd", "permitted_uses_set": {"train", "eval"},
           "rights_doc_id": "https://commons.wikimedia.org/wiki/File:X.jpg", "split": "train"}
    row.update(overrides)
    return row


def test_cc0_training_row_passes_the_rights_gate():
    assert_training_rights([_row()])


def test_public_holdout_rows_can_never_train():
    # eval-only permission: refused even if someone points train.py at them
    with pytest.raises(TrainingRightsError):
        assert_training_rights([_row(permitted_uses_set={"eval"}, split="public_holdout")])


def test_licence_filter_accepts_only_cc0_and_public_domain():
    assert licence_accepted("CC0") and licence_accepted("Public domain")
    for rejected in ("CC BY-SA 4.0", "CC BY 4.0", "CC BY-NC 2.0", "GFDL", "Copyrighted free use"):
        assert not licence_accepted(rejected)


def test_stock_site_imports_and_edited_files_are_excluded():
    base = {"mime": "image/jpeg", "licence_short": "CC0", "width": 4000, "height": 3000, "make": "Apple",
            "model": "iPhone 12", "software": "16.1", "title": "File:A.jpg", "credit": "", "artist": "A",
            "categories": "", "description": ""}
    assert eligible(base, require_phone=True)[0]
    assert not eligible({**base, "title": "File:Mountain (Unsplash).jpg"}, require_phone=True)[0]
    assert not eligible({**base, "credit": "Pexels"}, require_phone=True)[0]
    assert not eligible({**base, "software": "Adobe Lightroom 6"}, require_phone=True)[0]
    assert not eligible({**base, "make": "NIKON CORPORATION", "model": "D300"}, require_phone=True)[0]


def test_phone_brand_excludes_camera_lines_of_phone_makers():
    assert phone_brand("Apple", "iPhone 13") == "Apple"
    assert phone_brand("samsung", "SM-G991B") == "Samsung"
    assert phone_brand("SONY", "ILCE-7M3") is None
    assert phone_brand("Sony", "XQ-AT51") == "Sony"
    assert phone_brand("SAMSUNG", "NX300") is None


def test_photographer_split_is_deterministic_and_case_insensitive():
    assert split_for("Jane Doe") == split_for("  jane doe ")
    shares = [split_for(f"artist {i}") for i in range(3000)]
    assert 0.75 < shares.count("train") / 3000 < 0.85


def test_heldout_degradation_is_frozen_by_file_hash():
    a = frozen_degradation("ab" * 32)
    b = frozen_degradation("ab" * 32)
    assert a == b
    hashes = [hashlib.sha256(str(i).encode()).hexdigest() for i in range(40)]
    identity_share = np.mean([frozen_degradation(h).identity for h in hashes])
    assert 0.05 < identity_share < 0.5  # about the sampler's 25% identity share
