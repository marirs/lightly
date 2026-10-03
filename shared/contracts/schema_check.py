"""Minimal JSON Schema (2020-12 subset) validator for the shared contracts, plus edit-recipe reader rules.

Only the keywords the contracts use are implemented: type, const, enum, minimum, maximum, exclusiveMinimum,
minLength, maxLength, pattern, properties, required, additionalProperties (false), items, prefixItems,
minItems, maxItems, oneOf, $ref (local "#/$defs/..."). Unknown keywords in a schema are an error, so the
schema cannot silently use something this checker ignores. Annotation keywords are allowed.
"""
from __future__ import annotations

import json
import re
from pathlib import Path

CONTRACTS = Path(__file__).resolve().parent
EDIT_RECIPE_SCHEMA = CONTRACTS / "edit-recipe-v1.json"

ANNOTATIONS = {"$schema", "$id", "title", "description", "$defs"}
SUPPORTED = {"type", "const", "enum", "minimum", "maximum", "exclusiveMinimum", "minLength", "maxLength", "pattern",
             "properties", "required", "additionalProperties", "items", "prefixItems", "minItems", "maxItems", "oneOf", "$ref"}
TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}


def _is_type(value, name: str) -> bool:
    if name == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if name == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, TYPES[name])


class Validator:
    def __init__(self, schema: dict):
        self.root = schema

    def errors(self, instance) -> list[str]:
        out: list[str] = []
        self._check(self.root, instance, "$", out)
        return out

    def _resolve(self, ref: str) -> dict:
        if not ref.startswith("#/"):
            raise ValueError(f"only local refs are supported: {ref}")
        node = self.root
        for part in ref[2:].split("/"):
            node = node[part]
        return node

    def _check(self, schema: dict, value, path: str, out: list[str]) -> None:
        unknown = set(schema) - SUPPORTED - ANNOTATIONS
        if unknown:
            raise ValueError(f"unsupported schema keywords at {path}: {sorted(unknown)}")
        if "$ref" in schema:
            self._check(self._resolve(schema["$ref"]), value, path, out)
        if "type" in schema:
            names = schema["type"] if isinstance(schema["type"], list) else [schema["type"]]
            if not any(_is_type(value, n) for n in names):
                out.append(f"{path}: expected {schema['type']}")
                return
        if "const" in schema:
            expected = schema["const"]
            # JSON true is not 1: compare the bool-ness too (Python treats True == 1).
            if value != expected or isinstance(value, bool) != isinstance(expected, bool):
                out.append(f"{path}: expected {expected!r}")
        if "enum" in schema and value not in schema["enum"]:
            out.append(f"{path}: {value!r} not in {schema['enum']}")
        if _is_type(value, "number"):
            if "minimum" in schema and value < schema["minimum"]:
                out.append(f"{path}: {value} < {schema['minimum']}")
            if "maximum" in schema and value > schema["maximum"]:
                out.append(f"{path}: {value} > {schema['maximum']}")
            if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
                out.append(f"{path}: {value} <= {schema['exclusiveMinimum']}")
        if isinstance(value, str):
            if "minLength" in schema and len(value) < schema["minLength"]:
                out.append(f"{path}: shorter than {schema['minLength']}")
            if "maxLength" in schema and len(value) > schema["maxLength"]:
                out.append(f"{path}: longer than {schema['maxLength']}")
            if "pattern" in schema and not re.search(schema["pattern"], value):
                out.append(f"{path}: {value!r} does not match {schema['pattern']}")
        if isinstance(value, dict):
            for key in schema.get("required", []):
                if key not in value:
                    out.append(f"{path}: missing {key}")
            properties = schema.get("properties", {})
            for key, item in value.items():
                if key in properties:
                    self._check(properties[key], item, f"{path}.{key}", out)
                elif schema.get("additionalProperties") is False:
                    out.append(f"{path}: unknown key {key}")
        if isinstance(value, list):
            if "minItems" in schema and len(value) < schema["minItems"]:
                out.append(f"{path}: fewer than {schema['minItems']} items")
            if "maxItems" in schema and len(value) > schema["maxItems"]:
                out.append(f"{path}: more than {schema['maxItems']} items")
            prefix = schema.get("prefixItems", [])
            for i, item in enumerate(value):
                if i < len(prefix):
                    self._check(prefix[i], item, f"{path}[{i}]", out)
                elif "items" in schema:
                    self._check(schema["items"], item, f"{path}[{i}]", out)
        if "oneOf" in schema:
            matches = 0
            for option in schema["oneOf"]:
                trial: list[str] = []
                self._check(option, value, path, trial)
                matches += not trial
            if matches != 1:
                out.append(f"{path}: matches {matches} of oneOf (expected exactly 1)")


def recipe_rule_errors(state: dict) -> list[str]:
    """Reader rules the schema cannot express (edit-recipe-v1.json descriptions say 'checked by readers')."""
    out = []
    tools = state["tools"]

    def rect_ok(rect, path):
        x, y, w, h = rect
        if w <= 0 or h <= 0 or x + w > 1 + 1e-9 or y + h > 1 + 1e-9:
            out.append(f"{path}: rectangle outside the frame")

    rect_ok(tools["edit"]["geometry"]["crop"]["rect"], "$.tools.edit.geometry.crop.rect")
    for i, entry in enumerate(tools["portrait"]["faces"]):
        rect_ok(entry["face"]["box"], f"$.tools.portrait.faces[{i}].face.box")
    wm = tools["watermark"]
    for part in ("signature", "text", "logo"):
        if (wm[part] is not None) != (wm["type"] == part):
            out.append(f"$.tools.watermark.{part}: must be set exactly when type is {part}")
    stops = (tools["background"]["replacement"] or {}).get("stops")
    if stops and [s["position"] for s in stops] != sorted(s["position"] for s in stops):
        out.append("$.tools.background.replacement.stops: positions must not decrease")
    depth = tools["background"]["focus"]["depth"]
    if (depth["source"] == "subject-matte") != (depth["map"] is None):
        out.append("$.tools.background.focus.depth.map: null exactly when source is subject-matte")
    # Contract fixes 1 (G3): without depth the blur stays 0; a mask-only blur is never rendered (§R8).
    if depth["source"] == "subject-matte" and tools["background"]["focus"]["blur"] != 0:
        out.append("$.tools.background.focus.blur: must be 0 when the depth source is subject-matte (no depth)")
    for i, stroke in enumerate(tools["edit"]["remove"]["strokes"]):
        if (stroke["result"]["status"] == "applied") != (stroke["result"]["patch"] is not None):
            out.append(f"$.tools.edit.remove.strokes[{i}].result.patch: set exactly when applied")
    return out


def validate_edit_recipe(state) -> list[str]:
    errors = Validator(json.loads(EDIT_RECIPE_SCHEMA.read_text())).errors(state)
    return errors or recipe_rule_errors(state)
