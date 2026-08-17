#!/usr/bin/env python3
"""Post-generate iOS configuration for flutter_app.

Run immediately after `flutter create` — locally or in CI. `ios/` is
gitignored and regenerated on every build, so neither of the values below can
live in a committed file. This script is where they live instead.

Applies:
  - IPHONEOS_DEPLOYMENT_TARGET floor (google_mlkit_commons requires 15.5;
    `pod install` fails outright below it) — in project.pbxproj, and in the
    Podfile when one exists
  - NSCameraUsageDescription (the camera package hard-crashes on first access
    without it — a failure that no compile check can catch)

Every patch is idempotent, and none returns without re-reading the file from
disk and confirming the value actually landed. A patch that quietly does
nothing is the specific hazard here: it produces a green build that crashes on
device, so silence is never treated as success.

**The Podfile is conditional, and only its absence is.** `flutter create`
generates a Podfile only on a host with a working Xcode — see
`xcode_generates_podfiles()` — so on Windows or Linux there is nothing to
patch and demanding one would fail the documented local workflow by design. If
a Podfile is present it is patched regardless of host; if it is absent on a
host that could not have produced one, that is reported and skipped; if it is
absent on a host that *should* have produced one, that is still fatal. The
guarantee is preserved exactly where the build happens.

Usage:
    python tool/configure_ios.py [ios_dir]

`ios_dir` defaults to the `ios/` beside this script's parent, and exists so the
logic can be exercised against a copied tree without touching a real one.
"""

from __future__ import annotations

import os
import plistlib
import re
import subprocess
import sys
from pathlib import Path

DEPLOYMENT_TARGET = "15.5"
CAMERA_KEY = "NSCameraUsageDescription"
CAMERA_USAGE_DESCRIPTION = "Record your golf swing so the app can analyze it."

# Measured against the pinned SDK, not predicted: `flutter create --project-name
# golf_swing_analyzer` camelCases the name and emits com.example.golfSwingAnalyzer.
# Only the org segment differs from what we want, but the rewrite replaces the
# whole identifier so a template change to the default org cannot slip through.
# Underscores are deliberately absent — Apple specifies bundle IDs as
# alphanumerics, hyphens and periods, and an App ID cannot be renamed once made.
BUNDLE_ID = "io.github.floresgl1.golfSwingAnalyzer"

# TestFlight asks an export-compliance question on every build unless the answer
# is declared here. False is a statement that the app uses no non-exempt
# encryption: it ships no custom cryptography, and HTTPS/ML Kit are exempt.
ENCRYPTION_KEY = "ITSAppUsesNonExemptEncryption"

# Expose the app's Documents directory in Files (On My iPhone > <app>), which
# is where the corpus lives. Without these the only way off the device is the
# share sheet, and the share sheet is one dependency deep in platform quirks:
# it cost four builds to a popover-anchor rule, then silently dropped the
# .jsonl attachment because iOS could not classify the extension. Both keys
# are needed — UIFileSharingEnabled alone lists the folder, and
# LSSupportsOpeningDocumentsInPlace lets files be opened and copied from it.
#
# This does not replace the share sheet; it is a second path that depends on
# nothing but the filesystem, for a corpus that P0.1 cannot proceed without.
FILE_SHARING_KEY = "UIFileSharingEnabled"
DOCS_IN_PLACE_KEY = "LSSupportsOpeningDocumentsInPlace"

# Signing is configured from the environment because the values are account
# secrets that must not live in the repo. Absent = build unsigned, which is what
# local runs and the compile-only CI job want.
TEAM_ENV = "IOS_DEVELOPMENT_TEAM"
PROFILE_ENV = "IOS_PROVISIONING_PROFILE_SPECIFIER"
IDENTITY_ENV = "IOS_CODE_SIGN_IDENTITY"
DEFAULT_IDENTITY = "Apple Distribution"

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

# One pattern for both bundle-identifier shapes, rewritten in a single pass by a
# callable. The generated tree carries the app id three times and a DERIVED
# `<app id>.RunnerTests` three more; two sequential substitutions cannot express
# that without the second undoing the first, and a single naive substitution
# gets the right answer only by luck of substring ordering. The callable makes
# the derivation explicit: read the suffix off the current value, keep it.
#
# Matching any identifier rather than only `com.example.*` is what makes reruns
# converge — the pattern accepts its own output and maps it to itself.
_ANY_BUNDLE_ID = re.compile(r"PRODUCT_BUNDLE_IDENTIFIER = ([\w.\-]+);")
_TESTS_SUFFIX = ".RunnerTests"

# Signing settings go in the project-level xcconfig rather than the pbxproj.
# Measured: the Runner app target carries NO signing settings in any build
# configuration (the three `CODE_SIGN_STYLE = Automatic` in the generated
# project belong to RunnerTests, which `flutter build ipa` never archives). With
# nothing at target level to override it, project xcconfig applies cleanly — so
# this is a whole-block write to a nearly empty file instead of surgical
# insertion into a NeXTSTEP plist the parser cannot read.
#
# The delimiters use `//`, xcconfig's line-comment syntax. `#` is NOT a comment
# here — it introduces a preprocessor directive, which is why the template's own
# `#include "Generated.xcconfig"` works. A `#`-prefixed delimiter made Xcode fail
# the archive with `unsupported preprocessor directive '>>>'`, a failure no
# amount of reading the file back could have caught, because the file was
# written exactly as intended and it was the intent that was wrong.
_SIGNING_BEGIN = "// >>> configure_ios.py managed signing block - do not edit by hand"
_SIGNING_END = "// <<< configure_ios.py managed signing block"

# Only these may start with `#` in an xcconfig. Anything else is a directive
# Xcode does not know, and it is fatal at archive time.
_XCCONFIG_DIRECTIVE = re.compile(r"^#include\??\s", re.MULTILINE)
_XCCONFIG_HASH_LINE = re.compile(r"^#.*$", re.MULTILINE)
_SIGNING_BLOCK = re.compile(
    re.escape(_SIGNING_BEGIN) + r".*?" + re.escape(_SIGNING_END) + r"\n?",
    re.DOTALL,
)


# Mirrors Flutter's own Xcode probe rather than approximating it. From the
# pinned SDK, `flutter_tools/lib/src/ios/xcodeproj.dart`:
#
#     if (!_platform.isMacOS || !_fileSystem.file('/usr/bin/xcodebuild').existsSync()) {
#     ...
#     bool get isInstalled => version != null;   // version parsed from `xcodebuild -version`
#
# and `macos/cocoapods.dart` returns early from `setupPodfile()` when that is
# false. `shutil.which("xcodebuild")` would NOT be equivalent: on a Mac with
# only the Command Line Tools installed the shim at /usr/bin/xcodebuild exists
# and is on PATH, but `xcodebuild -version` fails, so Flutter reads Xcode as
# absent and skips Podfile generation. Predicting Flutter's behaviour requires
# running the same check Flutter runs.
_XCODEBUILD = Path("/usr/bin/xcodebuild")
_XCODE_VERSION = re.compile(r"Xcode ([0-9.]+).*Build version (\w+)", re.DOTALL)


class PatchError(RuntimeError):
    """A patch did not land. Never allowed to pass as success."""


def xcode_generates_podfiles() -> bool:
    """True when this host's Flutter would have generated a Podfile.

    Answers one narrow question — is a missing Podfile expected here, or is it
    evidence of a broken tree? — so it is deliberately conservative: anything
    unexpected reads as "no Xcode", which downgrades a missing Podfile to a
    reported skip rather than inventing a failure on a host that was never
    going to have one.
    """
    if sys.platform != "darwin" or not _XCODEBUILD.is_file():
        return False

    try:
        result = subprocess.run(
            [str(_XCODEBUILD), "-version"],
            capture_output=True,
            text=True,
            timeout=60,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return False

    return result.returncode == 0 and _XCODE_VERSION.search(result.stdout) is not None


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
    # This is the one patch that gets idempotency from the data structure
    # itself rather than from a carefully written pattern.
    wanted = {
        CAMERA_KEY: CAMERA_USAGE_DESCRIPTION,
        ENCRYPTION_KEY: False,
        FILE_SHARING_KEY: True,
        DOCS_IN_PLACE_KEY: True,
    }
    plist.update(wanted)

    with plist_path.open("wb") as handle:
        plistlib.dump(plist, handle)

    with plist_path.open("rb") as handle:
        written = plistlib.load(handle)

    for key, value in wanted.items():
        actual = written.get(key)
        # `is not` on the bool would be right but reads as a typo; compare by
        # type and value so False never matches a 0 that drifted in.
        if type(actual) is not type(value) or actual != value:
            raise PatchError(
                f"{plist_path}: {key} reads {actual!r} after writing, "
                f"expected {value!r}."
            )


def patch_bundle_identifier(pbxproj_path: Path) -> tuple[int, int]:
    """Point every target at our bundle id, keeping the test suffix derived."""
    tests_id = f"{BUNDLE_ID}{_TESTS_SUFFIX}"

    def rewrite(match: re.Match[str]) -> str:
        suffix = _TESTS_SUFFIX if match.group(1).endswith(_TESTS_SUFFIX) else ""
        return f"PRODUCT_BUNDLE_IDENTIFIER = {BUNDLE_ID}{suffix};"

    original = pbxproj_path.read_text(encoding="utf-8")
    patched, _ = _ANY_BUNDLE_ID.subn(rewrite, original)
    if patched != original:
        pbxproj_path.write_text(patched, encoding="utf-8")

    values = _ANY_BUNDLE_ID.findall(pbxproj_path.read_text(encoding="utf-8"))
    if not values:
        raise PatchError(
            f"{pbxproj_path}: no PRODUCT_BUNDLE_IDENTIFIER found at all. A "
            "generated project always carries one per build configuration, so "
            "the pattern no longer matches this project format."
        )

    app_count = values.count(BUNDLE_ID)
    tests_count = values.count(tests_id)

    unexpected = sorted(set(values) - {BUNDLE_ID, tests_id})
    if unexpected:
        raise PatchError(
            f"{pbxproj_path}: {len(values) - app_count - tests_count} of "
            f"{len(values)} configurations still read {', '.join(unexpected)}."
        )

    # The two shapes are counted separately on purpose. A single total would
    # pass if they had collapsed into one identifier — which builds a project
    # whose app and test bundles claim the same id, and is invalid. Requiring
    # both to be non-empty catches that; requiring an exact 3/3 would instead
    # false-alarm the day the template adds a build configuration.
    if not app_count or not tests_count:
        raise PatchError(
            f"{pbxproj_path}: expected both an app identifier and a "
            f"{_TESTS_SUFFIX} one, got app={app_count} tests={tests_count}. "
            "The two targets must not share a bundle identifier."
        )

    return app_count, tests_count


def patch_signing(xcconfig_path: Path, team: str, profile: str, identity: str) -> None:
    """Write the manual-signing block into the release xcconfig, then prove it."""
    block = "\n".join(
        [
            _SIGNING_BEGIN,
            "CODE_SIGN_STYLE = Manual",
            f"DEVELOPMENT_TEAM = {team}",
            f"PROVISIONING_PROFILE_SPECIFIER = {profile}",
            f"CODE_SIGN_IDENTITY = {identity}",
            _SIGNING_END,
        ]
    )

    original = xcconfig_path.read_text(encoding="utf-8")

    # Replacing a delimited block is what makes this idempotent: the second run
    # overwrites the first run's output rather than appending beside it. An
    # append-if-missing would stack a fresh block on every rerun, and xcconfig
    # takes the LAST assignment — so stale values would win silently.
    if _SIGNING_BLOCK.search(original):
        patched = _SIGNING_BLOCK.sub(block + "\n", original)
    else:
        patched = original.rstrip("\n") + "\n\n" + block + "\n"

    if patched != original:
        xcconfig_path.write_text(patched, encoding="utf-8")

    written = xcconfig_path.read_text(encoding="utf-8")
    blocks = _SIGNING_BLOCK.findall(written)
    if len(blocks) != 1:
        raise PatchError(
            f"{xcconfig_path}: found {len(blocks)} managed signing blocks after "
            "writing, expected exactly 1."
        )

    # Encodes the lesson that cost a CI round: every `#` line in an xcconfig is
    # a directive, and an unrecognised one fails the archive rather than being
    # ignored as a comment. Checked against the whole file so a hand-added `#`
    # comment is caught here instead of inside xcodebuild.
    bad = [
        line
        for line in _XCCONFIG_HASH_LINE.findall(written)
        if not _XCCONFIG_DIRECTIVE.match(line)
    ]
    if bad:
        raise PatchError(
            f"{xcconfig_path}: {len(bad)} line(s) start with '#' but are not "
            f"#include directives: {bad!r}. In xcconfig '#' means a preprocessor "
            "directive, not a comment — Xcode fails the archive on unknown ones. "
            "Use '//' for comments."
        )

    expected = {
        "CODE_SIGN_STYLE": "Manual",
        "DEVELOPMENT_TEAM": team,
        "PROVISIONING_PROFILE_SPECIFIER": profile,
        "CODE_SIGN_IDENTITY": identity,
    }
    for key, value in expected.items():
        # Anchored to the whole file, not the block, so an assignment placed
        # AFTER the block — which xcconfig would let win — fails the check.
        matches = re.findall(rf"^{re.escape(key)} = (.*)$", written, re.MULTILINE)
        if matches[-1:] != [value]:
            raise PatchError(
                f"{xcconfig_path}: {key} resolves to {matches[-1:] or ['nothing']} "
                f"instead of {value!r}. xcconfig takes the last assignment."
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
    xcconfig_path = ios_dir / "Flutter" / "Release.xcconfig"

    for path in (plist_path, pbxproj_path):
        if not path.is_file():
            print(
                f"error: {path} is missing. `flutter create` should have "
                "produced it; the generated tree looks incomplete.",
                file=sys.stderr,
            )
            return 1

    # PRESENCE decides whether the Podfile is patched; only its ABSENCE is
    # judged against the host. A tree generated on a Mac and copied to Windows
    # still carries a Podfile, and it is still patched here — gating the patch
    # itself on the host would skip a file that is sitting right there.
    podfile_present = podfile_path.is_file()

    if not podfile_present:
        if xcode_generates_podfiles():
            print(
                f"error: {podfile_path} is missing, but this host has a working "
                "Xcode, so `flutter create` did generate one and something "
                "removed it. Refusing to configure a tree whose build would "
                "fall back to CocoaPods' inferred deployment target.",
                file=sys.stderr,
            )
            return 1

        print(
            f"warning: {podfile_path} does not exist, and this host has no "
            "working Xcode, so `flutter create` never generated one. Skipping "
            "the Podfile patch. THIS TREE IS NOT READY TO BUILD — the Podfile "
            "patch still has to run on the macOS host that builds it.",
            file=sys.stderr,
        )

    # Signing is opt-in via the environment. All-or-nothing on purpose: a run
    # with a team but no profile would produce a project that looks configured
    # for manual signing and cannot sign, which fails deep inside xcodebuild
    # with a message that does not name the cause.
    team = os.environ.get(TEAM_ENV, "").strip()
    profile = os.environ.get(PROFILE_ENV, "").strip()
    identity = os.environ.get(IDENTITY_ENV, "").strip() or DEFAULT_IDENTITY
    sign = bool(team and profile)

    if (team or profile) and not sign:
        missing = TEAM_ENV if not team else PROFILE_ENV
        print(
            f"error: {missing} is unset but the other signing variable is set. "
            "Configure both or neither — a half-configured signing block "
            "cannot sign and fails obscurely inside xcodebuild.",
            file=sys.stderr,
        )
        return 1

    if sign and not xcconfig_path.is_file():
        print(
            f"error: {xcconfig_path} is missing, so there is nowhere to put the "
            "signing settings. `flutter create` always produces it.",
            file=sys.stderr,
        )
        return 1

    try:
        patch_info_plist(plist_path)
        patch_deployment_target(pbxproj_path)
        app_count, tests_count = patch_bundle_identifier(pbxproj_path)
        if podfile_present:
            patch_podfile(podfile_path)
        if sign:
            patch_signing(xcconfig_path, team, profile, identity)
    except (PatchError, plistlib.InvalidFileException, ValueError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    # The summary names the Podfile either way. A run that skipped it must not
    # read as a fully configured tree — that is the same silence-as-success
    # hazard this script exists to prevent, one level up.
    podfile_state = (
        "and in the Podfile"
        if podfile_present
        else "-- PODFILE NOT PATCHED, it does not exist on this host"
    )
    print(
        f"ios: {CAMERA_KEY} set; {ENCRYPTION_KEY}=false; "
        f"{FILE_SHARING_KEY}/{DOCS_IN_PLACE_KEY}=true; "
        f"deployment target {DEPLOYMENT_TARGET} in every build configuration "
        f"{podfile_state}"
    )
    print(
        f"ios: bundle id {BUNDLE_ID} "
        f"({app_count} app / {tests_count} test configurations)"
    )
    # Named either way, for the same reason the Podfile is: an unsigned run must
    # not read as a signed one.
    print(
        f"ios: manual signing configured for team {team}, profile {profile!r}"
        if sign
        else f"ios: NOT SIGNED -- {TEAM_ENV}/{PROFILE_ENV} unset, build will be "
        "unsigned"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
