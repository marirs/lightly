import json

import numpy as np

from lightly_auto.manifest import MANIFEST_COLUMNS, check_frozen_eval_set, dct_phash, hamming_distance, manifest_hash
from lightly_auto.paths import PROTOCOL_JSON
from lightly_auto.protocol import current_fingerprint, load_protocol

PROTOCOL = load_protocol(verify_lock=False)


def make_row(image_id, rubric_class="already_good", bucket="", split="frozen_eval", tier="T1", uses="train;eval", sha=None):
    row = {c: "" for c in MANIFEST_COLUMNS}
    row.update(image_id=image_id, sha256=sha or f"sha-{image_id}", rubric_class=rubric_class, skin_bucket=bucket,
               split=split, source_tier=tier, rights_doc_id="doc-1", permitted_uses=uses)
    row["labels_dict"], row["permitted_uses_set"] = {}, set(uses.split(";"))
    return row


def test_protocol_lock_matches_committed_files():
    load_protocol(verify_lock=True)  # raises ProtocolLockMismatch if anything drifted


def test_protocol_thresholds_match_spec_section_1_1():
    criteria = json.load(open(PROTOCOL_JSON))["criteria"]
    assert criteria["skin"]["gated"] == {"skin_abs_dh_deg": {"max": 4.0}, "skin_chroma_ratio": {"max": 1.12}}
    assert criteria["sunset"]["gated"] == {"warm_chroma_ratio": {"min": 0.95, "max": 1.10}, "warm_abs_dh_deg": {"max": 4.0}}
    assert criteria["night"]["gated"]["night_p50_dL"] == {"max": 3.0}
    assert criteria["backlit"]["gated"]["subject_dL"] == {"min_exclusive": 0.0}
    assert criteria["already_good"]["gated"] == {"dE00_mean": {"max": 3.0}}
    assert PROTOCOL["class_rule_S1"]["min_pass_rate"] == 0.80


def test_fingerprint_is_stable():
    assert current_fingerprint() == current_fingerprint()


def test_manifest_hash_is_order_independent_and_label_sensitive():
    a, b = make_row("a"), make_row("b")
    assert manifest_hash([a, b]) == manifest_hash([b, a])
    relabelled = dict(a, labels="face_underexposed")
    assert manifest_hash([relabelled, b]) != manifest_hash([a, b])


def test_frozen_set_check_flags_small_classes_buckets_tier_rights_and_leakage():
    eval_rows = [make_row("e1", "portrait", "MST 1-3"), make_row("e2", tier="unsplash_dev", uses="eval_dev_only"),
                 make_row("e3", split="dev")]
    train_rows = [make_row("t1", split="train", sha="sha-e1")]
    report = check_frozen_eval_set(PROTOCOL, eval_rows, train_rows)
    text = "\n".join(report.problems)
    assert not report.passes_g0
    assert "class portrait: 1 images < 40" in text
    assert "skin bucket MST 8-10: share 0.00" in text
    assert "e2: source tier 'unsplash_dev' is not T1" in text and "e2: no documented eval permission" in text
    assert "e3: split 'dev' is not frozen_eval" in text
    assert "e1: exact duplicate of t1" in text


def test_frozen_set_check_flags_near_duplicates_via_phash():
    eval_rows, train_rows = [make_row("e1")], [make_row("t1", split="train")]
    report = check_frozen_eval_set(PROTOCOL, eval_rows, train_rows, phashes={"e1": 0b1011, "t1": 0b1001})
    assert any("near duplicate of t1" in p for p in report.problems)


def test_phash_is_robust_to_resize_and_separates_different_images():
    rng = np.random.default_rng(0)
    base = (np.kron(rng.random((8, 8, 3)), np.ones((32, 32, 1))) * 255).astype(np.uint8)
    from PIL import Image
    resized = np.asarray(Image.fromarray(base).resize((200, 200), Image.BILINEAR))
    other = (np.kron(rng.random((8, 8, 3)), np.ones((32, 32, 1))) * 255).astype(np.uint8)
    assert hamming_distance(dct_phash(base), dct_phash(resized)) <= 6
    assert hamming_distance(dct_phash(base), dct_phash(other)) > 12
