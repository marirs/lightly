"""Durable, hash-verified copy of Auto experiment 1 OUTSIDE Git.

  python archive_experiment.py --dest ~/.codex/artifacts/lightly/v1/auto-experiment-1 [--with-data]
  cd <dest> && shasum -a 256 -c SHA256SUMS           # verify later

Copies (never moves) what is needed to reproduce or re-examine the experiment:
  model/        photo_a_001 checkpoints (selected step 4000 = classifier.pt/basis_luts.npy, plus best_* and
                last_*), run card, training log, and the Core ML / ONNX / TFLite / LUT-bin exports with their card;
  config/       PROTOCOL.json, PROTOCOL.lock, gate configs and pre-registration, Python environment freeze;
  manifests/    every committed manifest and provenance file, the PH-1 freeze record, DEV-22 manifest and the
                pinned PH-1 face file;
  code/         `git archive` of experiments/auto and experiments/lut3d/reference at the archived commit;
  results/      committed result folders (held-out v1, gating), copied for convenience;
  sheets/       before/after contact sheets (made by make_before_after.py; they show identifiable people
                from public CC0 photos, so they stay out of Git and out of any shared artefact);
  data/         (--with-data) the exact image bytes the manifests hash: CC0REF 640 px references and the
                PH-1 2048 px proxies. Large; kept here because the upstream mirror could disappear.
SHA256SUMS lists every file. The research-only FiveK weights are deliberately NOT copied.
"""
from __future__ import annotations

import argparse
import hashlib
import os
import shutil
import subprocess
import sys

from lightly_auto.manifest import load_manifest, resolve_source
from lightly_auto.paths import AUTO_ROOT, REPO_ROOT

RUN_ID = "photo_a_001"
MODEL_FILES = ["classifier.pt", "basis_luts.npy", "best_classifier.pt", "best_basis_luts.npy",
               "last_classifier.pt", "last_basis_luts.npy", "run_card.json", "train_log.csv"]
COMMITTED_DIRS = {"manifests": "manifests", "results/heldout_v1": "results/heldout_v1",
                  "results/gating_v1": "results/gating_v1", "results/heldout_v1_gate_v1": "results/heldout_v1_gate_v1",
                  "gating": "config/gating",
                  # Derived per-image numbers behind the validation gate study (git-ignored, rebuilt by gate_study.py).
                  "runs/gate_study": "results/gate_study_cache"}
SINGLE_FILES = {"PROTOCOL.json": "config/PROTOCOL.json", "PROTOCOL.lock": "config/PROTOCOL.lock",
                "eval/dev22_manifest.csv": "manifests/dev22_manifest.csv",
                "data/ph1/faces.json": "manifests/ph1_faces_pinned.json"}


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def copy(source: str, destination: str) -> None:
    os.makedirs(os.path.dirname(destination), exist_ok=True)
    if os.path.isdir(source):
        shutil.copytree(source, destination, dirs_exist_ok=True)
    else:
        shutil.copy2(source, destination)


def git_head() -> str:
    return subprocess.check_output(["git", "-C", REPO_ROOT, "rev-parse", "HEAD"], text=True).strip()


def main(argv=None) -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dest", required=True)
    parser.add_argument("--with-data", action="store_true")
    parser.add_argument("--sheets", default=os.path.join(AUTO_ROOT, "runs", "before_after_sheets"))
    args = parser.parse_args(argv)
    dest = os.path.expanduser(args.dest)
    os.makedirs(dest, exist_ok=True)

    run_dir = os.path.join(AUTO_ROOT, "runs", RUN_ID)
    for name in MODEL_FILES:
        copy(os.path.join(run_dir, name), os.path.join(dest, "model", RUN_ID, name))
    copy(os.path.join(run_dir, "export"), os.path.join(dest, "model", RUN_ID, "export"))
    for source, target in COMMITTED_DIRS.items():
        if os.path.exists(os.path.join(AUTO_ROOT, source)):
            copy(os.path.join(AUTO_ROOT, source), os.path.join(dest, target))
    for source, target in SINGLE_FILES.items():
        copy(os.path.join(AUTO_ROOT, source), os.path.join(dest, target))
    if os.path.isdir(args.sheets):
        copy(args.sheets, os.path.join(dest, "sheets"))

    commit = git_head()
    os.makedirs(os.path.join(dest, "code"), exist_ok=True)
    archive = os.path.join(dest, "code", f"lightly-auto-code-{commit[:12]}.tar.gz")
    subprocess.check_call(["git", "-C", REPO_ROOT, "archive", "--format=tar.gz", "-o", archive, commit,
                           "experiments/auto", "experiments/lut3d/reference"])
    open(os.path.join(dest, "code", "COMMIT"), "w").write(commit + "\n")
    freeze = subprocess.check_output([sys.executable, "-m", "pip", "freeze"], text=True)
    open(os.path.join(dest, "config", "python-requirements-freeze.txt"), "w").write(freeze)

    if args.with_data:
        for manifest in ("manifests/cc0ref_manifest.csv", "manifests/ph1_manifest.csv"):
            for row in load_manifest(os.path.join(AUTO_ROOT, manifest)):
                source = resolve_source(row)
                copy(source, os.path.join(dest, "data", os.path.relpath(source, AUTO_ROOT)))

    sums = []
    for root, _, files in os.walk(dest):
        for name in sorted(files):
            path = os.path.join(root, name)
            relative = os.path.relpath(path, dest)
            if relative == "SHA256SUMS":
                continue
            sums.append(f"{sha256_of(path)}  {relative}")
    open(os.path.join(dest, "SHA256SUMS"), "w").write("\n".join(sorted(sums, key=lambda l: l.split("  ", 1)[1])) + "\n")
    print(f"archived {len(sums)} files to {dest} at commit {commit}")


if __name__ == "__main__":
    main()
