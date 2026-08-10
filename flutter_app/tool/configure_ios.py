#!/usr/bin/env python3
"""Post-generate iOS configuration for flutter_app.

Run immediately after `flutter create` — locally or in CI. `ios/` is
gitignored and regenerated on every build, so neither of the values below can
live in a committed file. This script is where they live instead.

Applies:
  - IPHONEOS_DEPLOYMENT_TARGET floor (google_mlkit_commons requires 15.5;
    `pod install` fails outright below it)
  - NSCameraUsageDescription (the camera package hard-crashes on first access
    without it — a failure that no compile check can catch)

Both patches are idempotent, and neither returns without re-reading the file
from disk and confirming the value actually landed. A patch that quietly does
nothing is the specific hazard here: it produces a green build that crashes on
device, so silence is never treated as success.

Usage:
    python tool/configure_ios.py [ios_dir]

`ios_dir` defaults to the `ios/` beside this script's parent, and exists so the
logic can be exercised against a copied tree without touching a real one.
"""

from __future__ import annotations

import plistlib
import re
import sys
from pathlib import Path

DEPLOYMENT_TARGET = "15.5"
CAMERA_KEY = "NSCameraUsageDescription"
CAMERA_USAGE_DESCRIPTION = "Record your golf swing so the app can analyze it."

# The pbxproj is NeXTSTEP ASCII plist, not XML, so plistlib cannot read it
# (it supports FMT_XML and FMT_BINARY only) and a text patch is the only
# option short of a third-party dependency.
#
# These two patterns are deliberately asymmetric. Substitution matches a bare
# numeric value; counting matches anything up to the semicolon. If both used
# the narrow pattern, a value this script cannot rewrite — a quoted "15.5", an
# $(inherited) — would be invisible to the numerator AND the denominator at
# once, and the post-condition would pass while leaving that configuration on
# the old floor. A check that shares its blind spots with the operation it
# checks is not a check.
_SUBSTITUTE_TARGET = re.compile(r"IPHONEOS_DEPLOYMENT_TARGET = [\d.]+;")
_COUNT_TARGET = re.compile(r"IPHONEOS_DEPLOYMENT_TARGET = ([^;]+);")

# The Podfile carries the same floor for CocoaPods, and needs the same
# asymmetry: substitution accepts the line commented or active at any version,
# counting looks only at active lines but tolerates leading whitespace so an
# indented line cannot slip past the check.
_SUBSTITUTE_PLATFORM = re.compile(r"^[ \t]*#?[ \t]*platform :ios.*$", re.MULTILINE)
_COUNT_PLATFORM = re.compile(r"^[ \t]*platform :ios(.*)$", re.MULTILINE)


class PatchError(RuntimeError):
    """A patch did not land. Never allowed to pass as success."""


def patch_info_plist(plist_path: Path) -> None:
    """Set the camera usage description, then prove it is there."""
    try:
        with plist_path.open("rb") as handle:
            plist = plistlib.load(handle)
    except plistlib.InvalidFileException as error:
        # plistlib's own message is just "Invalid file", which does not say
        # which file. Failures here have to be diagnosable from CI output.
        raise PatchError(f"{plist_path}: not a readable plist ({error}).") from error

    if not isinstance(plist, dict):
        raise PatchError(f"{plist_path}: root is {type(plist).__name__}, expected a dict.")

    # Assignment rather than insertion: identical on the first run and the
    # fifth, with no already-present branch and no chance of a duplicate key.
    plist[CAMERA_KEY] = CAMERA_USAGE_DESCRIPTION

    with plist_path.open("wb") as handle:
        plistlib.dump(plist, handle)

    with plist_path.open("rb") as handle:
        written = plistlib.load(handle)

    actual = written.get(CAMERA_KEY)
    if actual != CAMERA_USAGE_DESCRIPTION:
        raise PatchError(
            f"{plist_path}: {CAMERA_KEY} reads {actual!r} after writing, "
            f"expected {CAMERA_USAGE_DESCRIPTION!r}."
        )


def patch_deployment_target(pbxproj_path: Path) -> None:
    """Raise every build configuration to the target floor, then prove it."""
    original = pbxproj_path.read_text(encoding="utf-8")
    patched, _ = _SUBSTITUTE_TARGET.subn(
        f"IPHONEOS_DEPLOYMENT_TARGET = {DEPLOYMENT_TARGET};", original
    )
    if patched != original:
        pbxproj_path.write_text(patched, encoding="utf-8")

    # The post-condition reads the file as written and ignores how many
    # substitutions happened. A count of zero means "already correct" and
    # "pattern no longer matches" alike; only the resulting state separates
    # them, because the benign case always leaves a positive denominator.
    values = _COUNT_TARGET.findall(pbxproj_path.read_text(encoding="utf-8"))

    if not values:
        raise PatchError(
            f"{pbxproj_path}: no IPHONEOS_DEPLOYMENT_TARGET found at all. A "
            "generated project always carries one per build configuration, so "
            "the pattern no longer matches this project format."
        )

    stale = sorted({value for value in values if value != DEPLOYMENT_TARGET})
    if stale:
        left_behind = len(values) - values.count(DEPLOYMENT_TARGET)
        raise PatchError(
            f"{pbxproj_path}: {left_behind} of {len(values)} build "
            f"configurations still target {', '.join(stale)} instead of "
            f"{DEPLOYMENT_TARGET}."
        )


def patch_podfile(podfile_path: Path) -> None:
    """Pin CocoaPods to the target floor, then prove it.

    The generated Podfile ships the platform line commented out, which is why
    CocoaPods was inferring 13.0 from the project. Substitution accepts the
    line in any state — commented, active, any version — so a rerun converges
    on the same result instead of needing an already-patched branch.
    """
    original = podfile_path.read_text(encoding="utf-8")
    active_line = f"platform :ios, '{DEPLOYMENT_TARGET}'"
    patched, replacements = _SUBSTITUTE_PLATFORM.subn(active_line, original)

    # If the template ever drops the commented line entirely there is nothing
    # to substitute, and silently building on CocoaPods' inferred default is
    # the exact failure this script exists to prevent. Add the line instead.
    if replacements == 0:
        patched = f"{active_line}\n\n{patched}"

    if patched != original:
        podfile_path.write_text(patched, encoding="utf-8")

    actives = _COUNT_PLATFORM.findall(podfile_path.read_text(encoding="utf-8"))
    if not actives:
        raise PatchError(
            f"{podfile_path}: no active `platform :ios` line after patching. "
            "CocoaPods would fall back to its inferred default."
        )

    stale = sorted(line.strip() for line in actives if DEPLOYMENT_TARGET not in line)
    if stale:
        raise PatchError(
            f"{podfile_path}: active platform line reads "
            f"{', '.join(stale)} instead of {DEPLOYMENT_TARGET}."
        )


def main(argv: list[str]) -> int:
    if len(argv) > 2:
        print(f"usage: {Path(argv[0]).name} [ios_dir]", file=sys.stderr)
        return 2

    ios_dir = Path(argv[1]) if len(argv) == 2 else Path(__file__).resolve().parent.parent / "ios"

    if not ios_dir.is_dir():
        print(
            f"error: {ios_dir} does not exist. Run `flutter create .` first: "
            "the platform folders are gitignored and generated, not committed.",
            file=sys.stderr,
        )
        return 1

    plist_path = ios_dir / "Runner" / "Info.plist"
    pbxproj_path = ios_dir / "Runner.xcodeproj" / "project.pbxproj"
    podfile_path = ios_dir / "Podfile"

    for path in (plist_path, pbxproj_path, podfile_path):
        if not path.is_file():
            print(
                f"error: {path} is missing. `flutter create` should have "
                "produced it; the generated tree looks incomplete.",
                file=sys.stderr,
            )
            return 1

    try:
        patch_info_plist(plist_path)
        patch_deployment_target(pbxproj_path)
        patch_podfile(podfile_path)
    except (PatchError, plistlib.InvalidFileException, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    print(
        f"ios: {CAMERA_KEY} set; deployment target {DEPLOYMENT_TARGET} "
        f"in every build configuration and in the Podfile"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
