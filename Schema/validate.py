"""Validates character.json files against the format schema.

Usage: python3 Schema/validate.py [path ...]
With no paths, validates every example under Schema/examples.
Needs the jsonschema package (pip install jsonschema).
"""
import glob
import json
import os
import sys

from jsonschema import Draft202012Validator

here = os.path.dirname(os.path.abspath(__file__))
with open(os.path.join(here, "character-0.3.schema.json")) as f:
    schema = json.load(f)
Draft202012Validator.check_schema(schema)
validator = Draft202012Validator(schema)

paths = sys.argv[1:] or sorted(glob.glob(os.path.join(here, "examples", "*", "character.json")))
if not paths:
    sys.exit("No files to validate")
failed = False
for path in paths:
    with open(path) as f:
        document = json.load(f)
    errors = sorted(validator.iter_errors(document), key=lambda e: list(e.path))
    for error in errors:
        location = "/".join(str(p) for p in error.path) or "(root)"
        print(f"{path}: {location}: {error.message}")
    failed = failed or bool(errors)
    if not errors:
        print(f"{path}: valid")
sys.exit(1 if failed else 0)
