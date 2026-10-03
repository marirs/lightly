"""Write the edit-recipe v1 (EditState schema 3) example fixtures in canonical form.

    python shared/contracts/make_edit_recipe_examples.py [--check]

Every example is built from `neutral_state()` (the approved prototype's `newSession` defaults,
docs/ui/app/app.js) plus the changes one tool makes, in the same order as the prototype's screens
(docs/ui/app/screens.js). Canonical encoding: keys in schema order (insertion order here), no
whitespace, no trailing newline, integers without a decimal point; Swift and Kotlin writers must
reproduce these bytes exactly.
"""
from __future__ import annotations

import copy
import json
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
OUT = REPO / "shared/fixtures/edit-recipe"
EDIT_STATE_FIXTURES = REPO / "shared/fixtures/edit-state"

# Shared with the schema-2 fixtures so a migrated document is directly comparable.
SOURCE = {"assetId": "content://media/picker/0/42",
          "fingerprint": {"headSha256": "ab" * 32, "byteSize": 1048576, "pixelWidth": 4032, "pixelHeight": 3024},
          "orientation": 6}
AUTO_APPLIED = {"modelId": "ia3dlut", "modelVersion": "research-fivek-1", "weights": [1.5, -0.25, -0.75],
                "guardrail": "endpoint-v1", "strength": 0.75}
AUTO_NONE = {"modelId": "ia3dlut", "modelVersion": "no-model-in-build", "weights": [0, 0, 0], "guardrail": None, "strength": 0}
# Pack ids are real (presets/develop-design-ui.json); lookVersion values are illustrative 12-hex strings.
LOOK_PORTRAIT_GLOW = {"lookId": "look-d8704f3622765f1c77c4", "lookVersion": "5f0c2a9e13b7", "strength": 1}
LOOK_LANDSCAPE = {"lookId": "look-b101de2ee5d340ac5621", "lookVersion": "0d4e6b1a9c22", "strength": 0.6}
DEFAULT_GRAIN_SEED = int(SOURCE["fingerprint"]["headSha256"][:8], 16)  # fixed at edit creation (README)

SEGMENTATION = {"id": "subject-segmentation", "version": "2025.1"}
DEPTH_MODEL = {"id": "monocular-depth", "version": "2025.1"}
FACE_DETECTOR = {"id": "face-landmarks", "version": "2025.1"}
INPAINT_MODEL = {"id": "inpaint", "version": "2025.1"}


def derived(seed: str, model: dict, width: int, height: int) -> dict:
    return {"sha256": (seed * 64)[:64], "model": model, "width": width, "height": height}


def neutral_tools() -> dict:
    return {
        "background": {
            "subject": {"matte": None, "refinements": []},
            "replacement": None,
            "focus": {"blur": 0, "depthOfField": 40, "style": "lens", "bokeh": "round", "styleAmount": 50, "target": None,
                      "depth": {"source": "subject-matte", "map": None, "focusDepth": None, "replacementDepth": 1}},
        },
        "portrait": {"faces": []},
        "edit": {
            "geometry": {"quarterTurns": 0, "flipHorizontal": False, "flipVertical": False,
                         "perspective": {"vertical": 0, "horizontal": 0}, "straighten": 0,
                         "crop": {"aspect": "original", "rect": [0, 0, 1, 1]}},
            "adjust": {"exposure": 0, "contrast": 0, "highlights": 0, "shadows": 0, "temp": 0, "tint": 0, "saturation": 0,
                       "vibrance": 0, "sharpness": 0, "clarity": 0, "noise": 0},
            "remove": {"strokes": []},
        },
        "effects": {
            "lightLeak": {"enabled": False, "style": "warm", "intensity": 55, "x": 18, "y": 14, "rotation": 0},
            "grain": {"enabled": False, "style": "film", "amount": 30, "size": 40, "roughness": 50, "seed": DEFAULT_GRAIN_SEED},
            "vignette": {"enabled": False, "amount": 35, "size": 60, "softness": 60},
        },
        "watermark": {"type": "none", "signature": None, "text": None, "logo": None, "placement": "photo", "position": 8,
                      "offset": None, "size": 34, "opacity": 85, "colour": "#FFFFFF"},
        "border": {"type": "none", "colour": "#FFFFFF", "width": 4, "spacing": 3, "mat": "#F4F1EC"},
    }


def neutral_state(auto=AUTO_APPLIED, look=None, revision=0) -> dict:
    return {"schema": 3, "recipeVersion": 1, "source": copy.deepcopy(SOURCE), "auto": copy.deepcopy(auto),
            "look": copy.deepcopy(look), "revision": revision, "tools": neutral_tools()}


def face(box, **changes) -> dict:
    entry = {"face": {"box": box, "detector": FACE_DETECTOR},
             "skin": {"smoothing": 0, "blemishes": 0, "evenTone": 0, "keepTexture": 85},
             "underEye": {"brighten": 0, "softenLines": 0}, "eyes": {"brighten": 0, "clarity": 0},
             "teeth": {"brighten": 0}, "hair": {"definition": 0, "flyaways": 0, "shine": 0}}
    for path, value in changes.items():
        group, key = path.split("__")
        entry[group][key] = value
    return entry


def estimated_depth(focus_depth=None) -> dict:
    """An estimated (Depth Anything V2 Small) map; focusDepth null = resolved at render from the default target."""
    return {"source": "estimated", "map": derived("e7", DEPTH_MODEL, 512, 384), "focusDepth": focus_depth, "replacementDepth": 1}


def with_matte(state: dict) -> dict:
    state["tools"]["background"]["subject"]["matte"] = derived("5a", SEGMENTATION, 1008, 756)
    return state


SIGNATURE_DRAWN = {"signatureId": "sig-1", "signatureVersion": "9b2d4f61c0aa", "kind": "drawn"}
SIGNATURE_IMPORTED = {"signatureId": "sig-2", "signatureVersion": "71e0c3d58b19", "kind": "imported"}


def examples() -> dict[str, dict]:
    out: dict[str, dict] = {}
    out["neutral"] = neutral_state(auto=AUTO_NONE)

    s = neutral_state(look=LOOK_LANDSCAPE, revision=3)
    out["develop-look-amount-auto"] = s

    s = with_matte(neutral_state(revision=2))
    s["tools"]["background"]["replacement"] = {"kind": "image", "image": {"kind": "bundled", "id": "background.landscape_01"},
                                               "x": 50, "y": 40, "scale": 120}
    out["background-replace-image"] = s
    s = with_matte(neutral_state(revision=2))
    s["tools"]["background"]["replacement"] = {"kind": "colour", "colour": "#3C4A55"}
    out["background-replace-colour"] = s
    s = with_matte(neutral_state(revision=2))
    s["tools"]["background"]["replacement"] = {"kind": "gradient", "angle": 160,
                                               "stops": [{"colour": "#F6D5B8", "position": 0}, {"colour": "#9EB7D6", "position": 1}]}
    out["background-replace-gradient"] = s
    s = with_matte(neutral_state(revision=4))
    s["tools"]["background"]["subject"]["refinements"] = [
        {"mode": "add", "radius": 0.02, "points": [[0.41, 0.3], [0.43, 0.32], [0.45, 0.33]]},
        {"mode": "erase", "radius": 0.015, "points": [[0.6, 0.52]]}]
    s["tools"]["background"]["replacement"] = {"kind": "image", "image": {"kind": "file", "sha256": "c3" * 32},
                                               "x": 50, "y": 50, "scale": 100}
    focus = s["tools"]["background"]["focus"]
    focus.update(blur=55, depthOfField=30, style="lens", bokeh="hex", target=[0.4, 0.48])
    focus["depth"] = {"source": "embedded", "map": derived("d1", {"id": "embedded-depth", "version": "heic-auxiliary"}, 768, 576),
                      "focusDepth": 0.22, "replacementDepth": 1}
    out["background-focus-embedded-depth-after-replacement"] = s
    s = with_matte(neutral_state(revision=2))
    focus = s["tools"]["background"]["focus"]
    focus.update(blur=40, depthOfField=55, style="soft", styleAmount=70)
    focus["depth"] = {"source": "estimated", "map": derived("e7", DEPTH_MODEL, 512, 384), "focusDepth": None, "replacementDepth": 1}
    out["background-focus-estimated-soft"] = s
    s = with_matte(neutral_state(revision=2))
    focus = s["tools"]["background"]["focus"]
    focus.update(blur=35, style="motion", styleAmount=75)  # direction = 75 * 3.6 - 180 = 90 degrees
    focus["depth"] = estimated_depth()
    out["background-focus-estimated-motion"] = s
    s = with_matte(neutral_state(revision=2))
    s["tools"]["background"]["focus"].update(blur=45, style="swirl", styleAmount=60, bokeh="star")
    s["tools"]["background"]["focus"]["depth"] = estimated_depth()
    out["background-focus-swirl"] = s

    s = neutral_state(revision=5)
    s["tools"]["portrait"]["faces"] = [
        face([0.37, 0.09, 0.28, 0.3], skin__smoothing=24, skin__blemishes=40, skin__evenTone=18, underEye__brighten=20,
             underEye__softenLines=15, eyes__brighten=15, teeth__brighten=20, hair__definition=30),
        face([0.62, 0.12, 0.2, 0.24], skin__smoothing=10, skin__keepTexture=95, eyes__clarity=12, hair__flyaways=25, hair__shine=10)]
    out["portrait-two-faces"] = s

    s = neutral_state(revision=6)
    s["tools"]["edit"]["geometry"] = {"quarterTurns": 1, "flipHorizontal": True, "flipVertical": False,
                                      "perspective": {"vertical": 18, "horizontal": -6}, "straighten": -3,
                                      "crop": {"aspect": "4:5", "rect": [0.1, 0.05, 0.6, 0.9]}}
    out["edit-geometry"] = s
    s = neutral_state(revision=3)
    s["tools"]["edit"]["adjust"] = {"exposure": 12, "contrast": 10, "highlights": -20, "shadows": 25, "temp": 15, "tint": -4,
                                    "saturation": 0, "vibrance": 12, "sharpness": 30, "clarity": 15, "noise": 20}
    out["edit-adjust"] = s
    s = neutral_state(revision=3)
    s["tools"]["edit"]["remove"]["strokes"] = [
        {"radius": 0.02, "points": [[0.62, 0.3], [0.7, 0.28], [0.77, 0.27]],
         "result": {"status": "applied", "patch": derived("9e", INPAINT_MODEL, 412, 160)}},
        {"radius": 0.03, "points": [[0.2, 0.8]], "result": {"status": "failed", "patch": None}}]
    out["edit-remove-strokes"] = s

    s = neutral_state(look=LOOK_PORTRAIT_GLOW, revision=4)
    s["tools"]["effects"]["lightLeak"].update(enabled=True, style="amber", intensity=60, x=80, y=10, rotation=-30)
    s["tools"]["effects"]["grain"].update(enabled=True, style="coarse", amount=45)
    s["tools"]["effects"]["vignette"].update(enabled=True)
    out["effects-combined-on-top-of-preset"] = s

    s = neutral_state(revision=2)
    s["tools"]["watermark"].update(type="signature", signature=SIGNATURE_DRAWN, size=30, colour="#111111")
    out["watermark-signature-drawn"] = s
    s = neutral_state(revision=3)
    s["tools"]["watermark"].update(type="signature", signature=SIGNATURE_IMPORTED, offset=[0.7, 0.86])
    out["watermark-signature-imported-dragged"] = s
    s = neutral_state(revision=2)
    s["tools"]["watermark"].update(type="text", text={"text": "A. Rivera", "font": "Cormorant Garamond"}, position=7, opacity=70)
    out["watermark-text"] = s
    s = neutral_state(revision=2)
    s["tools"]["watermark"].update(type="logo", logo={"image": {"kind": "file", "sha256": "1f" * 32}}, position=2)
    out["watermark-logo"] = s
    s = neutral_state(revision=3)
    s["tools"]["watermark"].update(type="text", text={"text": "A. Rivera", "font": "Caveat"}, placement="border")
    s["tools"]["border"].update(type="solid", width=8)
    out["watermark-text-on-border"] = s

    s = neutral_state(revision=1)
    s["tools"]["border"].update(type="solid", width=5)
    out["border-solid"] = s
    s = neutral_state(revision=1)
    s["tools"]["border"].update(type="frame", colour="#111111", width=3, spacing=5)
    out["border-frame"] = s
    s = neutral_state(revision=2)
    s["tools"]["border"].update(type="polaroid")
    s["tools"]["watermark"].update(type="signature", signature=SIGNATURE_DRAWN, placement="border")
    out["border-polaroid-signature-on-margin"] = s

    out["demo-combined"] = demo_combined()
    return out


def demo_combined() -> dict:
    """The approved 'Combined edit, one session' (docs/ui/app/screens.js DEMO), steps 1-7, on the woman photo."""
    s = with_matte(neutral_state(look=LOOK_PORTRAIT_GLOW, revision=7))      # 1 Develop preset (Portrait stop 13)
    s["tools"]["background"]["replacement"] = {"kind": "image", "image": {"kind": "bundled", "id": "background.landscape_01"},
                                               "x": 50, "y": 50, "scale": 120}  # 2 background replaced
    s["tools"]["background"]["focus"].update(blur=55, target=[0.4, 0.48])  # 3 focus & blur on the new background
    # Depth under the face, stored as depth (0 near): 1 - disparity 0.458 measured on this photo (contract-fixes-1.md).
    s["tools"]["background"]["focus"]["depth"] = estimated_depth(focus_depth=0.54)
    s["tools"]["portrait"]["faces"] = [face([0.29, 0.37, 0.22, 0.25], skin__smoothing=22, skin__blemishes=35,
                                            underEye__brighten=15)]          # 4 portrait
    s["tools"]["effects"]["vignette"].update(enabled=True)                 # 5 effects
    s["tools"]["effects"]["grain"].update(enabled=True, amount=25)
    s["tools"]["watermark"].update(type="signature", signature=SIGNATURE_DRAWN, size=30)  # 6 signature
    s["tools"]["border"].update(type="polaroid")                           # 7 polaroid, signature on the margin
    s["tools"]["watermark"]["placement"] = "border"
    return s


def invalid_examples() -> dict[str, dict]:
    out = {}
    s = neutral_state()
    s["tools"]["edit"]["extra"] = True
    out["invalid-unknown-tool-key"] = s
    s = neutral_state()
    s["tools"]["background"]["focus"]["blur"] = 120
    out["invalid-blur-out-of-range"] = s
    s = neutral_state()
    s["tools"]["border"]["colour"] = "white"
    out["invalid-colour-name"] = s
    s = neutral_state()
    s["schema"] = 4
    out["invalid-future-schema"] = s
    s = neutral_state()
    del s["tools"]["effects"]
    out["invalid-missing-effects"] = s
    s = neutral_state()
    s["tools"]["background"]["focus"]["depth"]["source"] = "lidar-guess"
    out["invalid-depth-source"] = s
    s = neutral_state(look=LOOK_LANDSCAPE)
    s["look"]["strength"] = 1.5
    out["invalid-look-strength"] = s
    s = with_matte(neutral_state(revision=2))
    s["tools"]["background"]["focus"].update(blur=35, style="motion", styleAmount=75)
    out["invalid-blur-without-depth"] = s   # subject-matte cannot blur (contract fixes 1, gap G3)
    return out


def migrate_schema2(state2: dict, grain_seed: int) -> dict:
    """Schema 2 -> 3: keys and values unchanged, recipeVersion 1 and neutral tools added (README)."""
    migrated = {"schema": 3, "recipeVersion": 1, "source": state2["source"], "auto": state2["auto"],
                "look": state2["look"], "revision": state2["revision"], "tools": neutral_tools()}
    migrated["tools"]["effects"]["grain"]["seed"] = grain_seed
    return migrated


def encode(value) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def all_files() -> dict[str, bytes]:
    files = {f"{name}.json": encode(state) for name, state in examples().items()}
    files.update({f"{name}.json": encode(state) for name, state in invalid_examples().items()})
    v2 = json.loads((EDIT_STATE_FIXTURES / "v2-with-look.json").read_text())
    files["migrated-from-v2-with-look.json"] = encode(
        migrate_schema2(v2, int(v2["source"]["fingerprint"]["headSha256"][:8], 16)))
    return files


def main(argv) -> int:
    files = all_files()
    if "--check" in argv:
        stale = [n for n, data in files.items() if not (OUT / n).exists() or (OUT / n).read_bytes() != data]
        if stale:
            print("out of date:", ", ".join(stale))
            return 1
        return 0
    OUT.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        (OUT / name).write_bytes(data)
    print(f"wrote {len(files)} files to {OUT}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
