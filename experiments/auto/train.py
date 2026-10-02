"""Train the ia3dlut-contract model (classifier + 3 basis LUTs of 33^3, fp32) - plan section 4 stage (a).

  python train.py --run-id smoke_001 --steps 1500

Contract obeyed during training (spec.md section 4.6, plan section 2):
  * the classifier only ever sees deployment_preprocess(8-bit-quantised input): the pinned antialiased
    256x256 whole-frame resize, identical to ia3dlut.prepare_256_antialiased (tested);
  * fused LUT = raw-weight sum of exactly 3 basis LUTs at 33^3, exact-grid trilinear, fp32 throughout;
  * the architecture is ia3dlut.ReferenceClassifier, so export and on-device code are unchanged.

Data sources:
  * procedural (default): lightly_auto.synthetic scenes + plan section 4(a) degradations. Plumbing only.
  * manifest:<csv>: DEFERRED - not implemented until licensed T1/T2 data exists. The rights gate
    (manifest.assert_training_rights) is already enforced for it.

Outputs runs/<run-id>/ (git-ignored): classifier.pt, basis_luts.npy, run_card.json, train_log.csv.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import inspect
import json
import os
import platform
import random
import subprocess
import time

import numpy as np
import torch
import torch.nn as nn
from skimage import color as skcolor

from lightly_auto import synthetic
from lightly_auto.lut_torch import (WarmHuePenalty, apply_lut_batch, deployment_preprocess, endpoint_penalty,
                                    fuse_basis, identity_basis_init, tv_and_monotonicity)
from lightly_auto.manifest import assert_training_rights, load_manifest
from lightly_auto.paths import REPO_ROOT, RUNS_DIR, ia3dlut as ia

SMOKE_ARM_LABEL = "Pipeline smoke model (procedural synthetic scenes) - plumbing only, NOT an AI Auto candidate"


class ContractModel(nn.Module):
    """Classifier (270,083 params, ReferenceClassifier layout) + 3 basis LUTs. forward() is the training graph;
    export uses .classifier and .basis exactly as the app does."""

    def __init__(self):
        super().__init__()
        self.classifier = ia.ReferenceClassifier(include_internal_resize=False)
        self.basis = nn.Parameter(identity_basis_init())
        self._init_like_upstream()

    def _init_like_upstream(self):
        # Upstream weights_init_normal_classifier: conv N(0, 0.02), instance-norm affine N(1, 0.02) / 0.
        for module in self.classifier.modules():
            if isinstance(module, nn.Conv2d):
                nn.init.normal_(module.weight, 0.0, 0.02)
                nn.init.zeros_(module.bias)
            elif isinstance(module, nn.InstanceNorm2d) and module.affine:
                nn.init.normal_(module.weight, 1.0, 0.02)
                nn.init.zeros_(module.bias)
        # Start near the identity develop: w ~= (1, 0, 0) selects basis 0 (identity). Within the contract, since
        # the fusion stays a raw-weight sum; only the starting point differs from upstream. With upstream's
        # N(0, 0.02) on the 8x8x128 final conv the initial weights are O(1) and the first output is far from
        # identity (measured: MSE 0.72 at step 1). The final conv and bases 1-2 get small non-zero values
        # rather than zeros, because w_i = 0 and B_i = 0 together would give both zero gradient forever.
        final_conv = self.classifier.model[-1]
        with torch.no_grad():
            nn.init.normal_(final_conv.weight, 0.0, 1e-3)
            final_conv.bias.copy_(torch.tensor([1.0, 0.0, 0.0]))
            self.basis[1:].normal_(0.0, 1e-3)

    def forward(self, images01: torch.Tensor, loss_pixels: torch.Tensor | None = None):
        """loss_pixels: optional [B,3,1,K] pixel sample to apply the LUT to instead of the full frame. The
        classifier always sees the full frame through the pinned resize; only the reconstruction loss is
        computed on a sample, because the LUT is per-pixel and the 3-D trilinear backward dominates cost."""
        weights = self.classifier(deployment_preprocess(images01))
        fused = fuse_basis(weights, self.basis)
        return apply_lut_batch(fused, images01 if loss_pixels is None else loss_pixels), weights, fused


def seed_everything(seed: int) -> None:
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)


def to_tensor(batch_uint8: list[np.ndarray]) -> torch.Tensor:
    return torch.from_numpy(np.stack(batch_uint8)).permute(0, 3, 1, 2).float().div(255.0)


def build_procedural_data(count: int, seed: int) -> np.ndarray:
    rng = np.random.default_rng(seed)
    return np.stack([synthetic.procedural_scene(rng) for _ in range(count)])


def make_validation_pairs(scenes: np.ndarray, seed: int, components: tuple = synthetic.ALL_COMPONENTS):
    rng = np.random.default_rng(seed)
    pairs = []
    for scene in scenes:
        degradation = synthetic.sample_degradation(rng, components)
        pairs.append((synthetic.apply_degradation(scene, degradation), scene, degradation.identity))
    return pairs


@torch.no_grad()
def validate(model: ContractModel, pairs) -> dict:
    """Plan G1 metrics on synthetic validation: median dE00(output, clean) on degraded samples, and
    median dE00(output, input) on identity samples. 'before' = the degraded input itself."""
    model.eval()
    before, after, identity = [], [], []
    for start in range(0, len(pairs), 16):
        chunk = pairs[start:start + 16]
        inputs = to_tensor([p[0] for p in chunk])
        outputs, _, _ = model(inputs)
        outputs8 = ia.to_uint8(outputs.permute(0, 2, 3, 1).numpy())
        for (degraded, clean, is_identity), out8 in zip(chunk, outputs8):
            lab_clean, lab_out = skcolor.rgb2lab(clean), skcolor.rgb2lab(out8)
            if is_identity:
                identity.append(float(skcolor.deltaE_ciede2000(lab_clean, lab_out).mean()))
            else:
                before.append(float(skcolor.deltaE_ciede2000(lab_clean, skcolor.rgb2lab(degraded)).mean()))
                after.append(float(skcolor.deltaE_ciede2000(lab_clean, lab_out).mean()))
    model.train()

    def stat(values, reducer):  # tiny validation sets may lack identity or degraded samples
        return float(reducer(values)) if values else None

    return {"n_degraded": len(before), "n_identity": len(identity),
            "degraded_input_dE00_median": stat(before, np.median),
            "output_vs_clean_dE00_median": stat(after, np.median),
            "output_vs_clean_dE00_p90": stat(after, lambda v: np.percentile(v, 90)),
            "identity_samples_dE00_median": stat(identity, np.median),
            "identity_samples_dE00_max": stat(identity, np.max),
            "fraction_improved": stat(list(np.array(after) < np.array(before)), np.mean)}


def code_fingerprint() -> str:
    from lightly_auto import lut_torch
    digest = hashlib.sha256()
    for module in (synthetic, lut_torch):
        digest.update(inspect.getsource(module).encode())
    digest.update(open(__file__, "rb").read())
    return digest.hexdigest()


def main(argv=None) -> dict:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--data", default="procedural")
    parser.add_argument("--steps", type=int, default=1500)
    parser.add_argument("--batch", type=int, default=8)
    parser.add_argument("--scenes", type=int, default=512)
    parser.add_argument("--val-scenes", type=int, default=128)
    # Separate rates: Adam moves every one of the final conv's 8,192 fan-in weights by ~lr per step, so a
    # shared 5e-4 moved the fusion weights by O(1) per step and diverged (measured: val dE00 7.3 -> 18.4).
    # With gradient clipping, 1e-4 / 1e-3 learned the exposure-only task (val MSE -65% in 400 steps).
    parser.add_argument("--lr-classifier", type=float, default=1e-4)
    parser.add_argument("--lr-basis", type=float, default=1e-3)
    parser.add_argument("--degradations", default="all",
                        help="'all' (plan section 4(a)) or a comma list of " + ",".join(synthetic.ALL_COMPONENTS))
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--loss-pixels", type=int, default=16384, help="pixels per image in the reconstruction loss")
    parser.add_argument("--clip-grad-norm", type=float, default=1.0)
    parser.add_argument("--lambda-smooth", type=float, default=1e-4)
    parser.add_argument("--lambda-monotonic", type=float, default=10.0)
    parser.add_argument("--lambda-endpoint", type=float, default=1.0)
    # Small on purpose: inverting a synthetic WB shift legitimately rotates warm hues, so a strong hinge
    # would fight the stage (a) objective. Stage (b) on real photos is where it is meant to bite.
    parser.add_argument("--lambda-warm-hue", type=float, default=0.01)
    parser.add_argument("--runs-dir", default=RUNS_DIR)
    args = parser.parse_args(argv)

    os.environ.setdefault("OMP_NUM_THREADS", str(args.threads))
    torch.set_num_threads(args.threads)  # shared machine: keep the run modest
    seed_everything(args.seed)

    if args.data.startswith("manifest:"):
        rows = load_manifest(args.data[len("manifest:"):])
        assert_training_rights(rows)  # refuses DEV-22, FiveK, frozen-eval rows, and rows without 'train'
        raise NotImplementedError("DEFERRED: photo-manifest training waits for licensed T1/T2 data (plan section 3)")
    if args.data != "procedural":
        raise ValueError(args.data)
    components = synthetic.ALL_COMPONENTS if args.degradations == "all" else tuple(args.degradations.split(","))

    started = time.time()
    train_scenes = build_procedural_data(args.scenes, seed=10_000 + args.seed)
    val_pairs = make_validation_pairs(build_procedural_data(args.val_scenes, seed=20_000 + args.seed), seed=30_000 + args.seed, components=components)
    data_seconds = time.time() - started

    model = ContractModel()
    optimiser = torch.optim.Adam([{"params": model.classifier.parameters(), "lr": args.lr_classifier},
                                  {"params": [model.basis], "lr": args.lr_basis}], betas=(0.9, 0.999))
    warm_hue = WarmHuePenalty()
    degradation_rng = np.random.default_rng(40_000 + args.seed)
    order_rng = np.random.default_rng(50_000 + args.seed)

    run_dir = os.path.join(args.runs_dir, args.run_id)
    os.makedirs(run_dir, exist_ok=True)
    validation_history = [{"step": 0, **validate(model, val_pairs)}]
    log_rows = []
    train_started = time.time()
    for step in range(1, args.steps + 1):
        indices = order_rng.integers(0, len(train_scenes), args.batch)
        degraded, clean = [], []
        for index in indices:
            scene = train_scenes[index]
            degraded.append(synthetic.apply_degradation(scene, synthetic.sample_degradation(degradation_rng, components)))
            clean.append(scene)
        inputs, targets = to_tensor(degraded), to_tensor(clean)
        flat_inputs, flat_targets = inputs.flatten(2), targets.flatten(2)
        sample = torch.from_numpy(order_rng.integers(0, flat_inputs.shape[-1], args.loss_pixels))
        outputs, _, fused = model(inputs, flat_inputs[..., sample].unsqueeze(2))
        reconstruction = torch.mean((outputs - flat_targets[..., sample].unsqueeze(2)) ** 2)
        tv_total, monotonic_total = 0.0, 0.0
        for basis_index in range(3):
            tv, monotonic = tv_and_monotonicity(model.basis[basis_index])
            tv_total, monotonic_total = tv_total + tv, monotonic_total + monotonic
        endpoint = endpoint_penalty(fused)
        warm = warm_hue(fused)
        loss = (reconstruction + args.lambda_smooth * tv_total + args.lambda_monotonic * monotonic_total
                + args.lambda_endpoint * endpoint + args.lambda_warm_hue * warm)
        optimiser.zero_grad()
        loss.backward()
        torch.nn.utils.clip_grad_norm_(model.parameters(), args.clip_grad_norm)
        optimiser.step()
        if step % 50 == 0 or step == 1:
            row = {"step": step, "loss": float(loss), "mse": float(reconstruction), "tv": float(tv_total),
                   "monotonic": float(monotonic_total), "endpoint": float(endpoint), "warm_hue": float(warm),
                   "psnr_db": float(-10 * torch.log10(reconstruction)), "elapsed_s": round(time.time() - train_started, 1)}
            log_rows.append(row)
            print(" ".join(f"{k}={v:.4g}" if isinstance(v, float) else f"{k}={v}" for k, v in row.items()), flush=True)
        if step % 500 == 0 and step != args.steps:
            validation_history.append({"step": step, **validate(model, val_pairs)})
    validation_history.append({"step": args.steps, **validate(model, val_pairs)})

    model.eval()
    torch.save(model.classifier.state_dict(), os.path.join(run_dir, "classifier.pt"))
    np.save(os.path.join(run_dir, "basis_luts.npy"), model.basis.detach().numpy().astype(np.float32))
    with open(os.path.join(run_dir, "train_log.csv"), "w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(log_rows[0]))
        writer.writeheader()
        writer.writerows(log_rows)
    final = validation_history[-1]
    card = {
        "run_id": args.run_id,
        "kind": "smoke",
        "arm_label": SMOKE_ARM_LABEL,
        "is_ai_auto_candidate": False,
        "research_only": False,
        "shippable": False,
        "why_not_shippable": "Trained on procedural synthetic scenes to validate the pipeline. Says nothing about quality on photos.",
        "data": {"source": "procedural", "generator": "lightly_auto/synthetic.py", "train_scenes": args.scenes,
                 "val_scenes": args.val_scenes, "scene_seed": 10_000 + args.seed, "val_seed": 20_000 + args.seed,
                 "train_scenes_sha256": hashlib.sha256(train_scenes.tobytes()).hexdigest(),
                 "identity_sample_probability": synthetic.IDENTITY_SAMPLE_PROBABILITY,
                 "degradation_components": list(components),
                 "rights": "Generated by our own code; no third-party images, no FiveK, no Unsplash."},
        "contract": {"input": "[1,3,256,256] sRGB [0,1], pinned antialiased resize", "basis_luts": 3, "lut_dim": ia.LUT_DIM,
                     "precision": "fp32", "classifier_params": sum(p.numel() for p in model.classifier.parameters())},
        "config": vars(args),
        "seeds": {"python_numpy_torch": args.seed, "degradation_rng": 40_000 + args.seed, "order_rng": 50_000 + args.seed},
        "code_commit": subprocess.run(["git", "-C", REPO_ROOT, "rev-parse", "HEAD"], capture_output=True, text=True).stdout.strip(),
        "code_fingerprint": code_fingerprint(),
        "environment": {"python": platform.python_version(), "torch": torch.__version__, "numpy": np.__version__,
                        "machine": platform.machine(), "threads": args.threads, "device": "cpu"},
        "timing_s": {"data_generation": round(data_seconds, 1), "training": round(time.time() - train_started, 1)},
        "validation_history": validation_history,
        "g1_synthetic_check": {
            "criterion_degraded_median_dE00_max": 2.0, "criterion_identity_median_dE00_max": 1.5,
            "degraded_median_dE00": final["output_vs_clean_dE00_median"],
            "identity_median_dE00": final["identity_samples_dE00_median"],
            "passes": (final["output_vs_clean_dE00_median"] is not None and final["identity_samples_dE00_median"] is not None
                       and final["output_vs_clean_dE00_median"] <= 2.0 and final["identity_samples_dE00_median"] <= 1.5),
            "note": "Procedural validation only. The real G1 needs a T1 validation split and the 'no class worse than Original' check."},
    }
    with open(os.path.join(run_dir, "run_card.json"), "w") as handle:
        json.dump(card, handle, indent=2)
    print(json.dumps(card["validation_history"], indent=1))
    print(f"wrote {run_dir}")
    return card


if __name__ == "__main__":
    main()
