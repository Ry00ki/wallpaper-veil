# Wallpaper Veil automation

These are contributor and release-builder instructions. App users download the
release ZIP, copy `Wallpaper Veil.app` to Applications and open it; they do not
run these tools or install Python, Xcode, Git or Hammerspoon. See the
[installation guide](../../README.md).

`Wallpaper Veil checks` runs inexpensive Ubuntu checks on pushes and pull requests.
Its stable required-check name is **Source checks**. It compiles the Python files
and parses the application Lua with Lua 5.4; it does not exercise macOS features.

[Wallpaper Veil preview build](https://github.com/Ry00ki/wallpaper-veil/actions/workflows/preview-build.yml)
runs only through **Run workflow**. It downloads the official runtime pinned in
`runtime.json`, checks its SHA-256 and original signature, compiles the native
launcher and UI bridge, and packages the nested application. It verifies the code
signatures and the standalone bundle contract again after extracting
`wallpaper-veil-preview.zip`, then uploads
Actions artifacts with a 14-day retention period. It never launches the app or
exercises hardware. No release is published and no recurring schedule is enabled.

Treat every preview artifact as public. The package contains the app, a ZIP
checksum, sanitized build provenance, the public runtime pin and a package summary.
It must not contain user preferences, local receipts, private paths, credentials
or diagnostic logs. The workflow has read-only repository access; checkout does
not persist credentials.

The existing preview workflow uses the pinned official binary runtime. The launcher
and native UI bridge are compiled from source. An optional verified source-engine
input is supported by the local builder below. Preview bundles are ad hoc signed without Developer ID signing or notarization. Signing and ZIP checks do
not verify menu appearance, real display brightness, Accessibility permissions,
Spaces, sleep or wake. Those require local testing.

The runtime digest was read from the official GitHub release asset metadata:
[runtime 1.1.1 metadata](https://api.github.com/repos/Hammerspoon/hammerspoon/releases/tags/1.1.1).

Actions are pinned to the commit IDs behind official release tags, verified on
2026-10-30: checkout v7.0.1, setup-python v7.1.0 and upload-artifact v7.0.2.
When updating an action or runtime, verify the corresponding official metadata
and update the pin deliberately.


## Maintained source and historical engine inputs

Product Lua is maintained under `WallpaperVeil/core/`; the launcher, native UI
bridge and updater source are under `WallpaperVeil/native/`. The repository no
longer maintains a second full upstream application, Xcode workspace, Pods tree
or upstream test suite in its current working tree.

[`engine/upstream.json`](../../engine/upstream.json) records the qualified native
commit/tag/tree, architectures, bootstrap and exact header/legal Git objects.
The product builder validates the retained upstream history and materializes only
those declared headers and legal files into a temporary build directory. It
rejects undeclared engine overrides or a silently changed policy. Keep full
history and the pinned `1.1.1` tag available; a shallow product-only checkout is
not a complete source-build input. No generated upstream input tree is an app
runtime dependency.

The separate engine builder also validates the maintained checkout, then creates
a temporary detached worktree at the pinned historical commit. Its Xcode paths
refer to that historical worktree, never to the maintained product root. The
native compile recipe and its qualified 95 binaries/81 component notices remain
unchanged. Source pruning does not mean those native modules were rewritten or
removed from the shipped engine. See [architecture](../../docs/architecture.md),
[upstream maintenance](../../docs/upstream-maintenance.md) and the
[development guide](../../docs/development.md).

## Source-engine developer builds

The separate `Wallpaper Veil source engine build` workflow is manual only. It
compiles native source pinned to upstream 1.1.1 rather than downloading the engine
release binary. Its shared recipe is `WallpaperVeil/ci/build_source_engine.py`.
It uses the upstream Release scheme with Debug configuration, both Intel and
Apple Silicon architectures, and full Xcode on the standard public macOS runner.
It needs no Apple signing credentials, telemetry token, notarization or pod
installation. It retains 81 component notices, signs ad hoc, rejects sanitizer
runtime dependencies, and verifies the archive after extraction. This engine
artifact is an intermediate dependency and is never launched by the workflow.
The existing preview packaging workflow remains unchanged.

The successful baseline recipe was qualified in
[run 41007648485](https://github.com/Ry00ki/wallpaper-veil/actions/runs/41007648485).
The permanent shared-script workflow passed in
[run 41018053866](https://github.com/Ry00ki/wallpaper-veil/actions/runs/41018053866)
at recipe revision `69ff1cce2a7fd61b1cf5033131cfc5b0bba53945`.
This recipe intentionally pins native source to commit
`1469832361b4c3687ec7d589c1b4efe4d3b742ee`; it does not compile subsequent native
source edits. Changes to native source require a new audited recipe and engine.

Keep an extracted engine and its original ZIP/manifest together under
`build.noindex/source-engine`. After obtaining a source-engine artifact, extract
its outer artifact ZIP there and extract `wallpaper-veil-source-engine.zip` into
`build.noindex/source-engine/runtime` with `ditto --noqtn -x -k`. Then:

```sh
python3 WallpaperVeil/build_local.py \
  --runtime "../build.noindex/source-engine/runtime/Hammerspoon.app" \
  --source-engine-manifest "../build.noindex/source-engine/source-engine-manifest.json" \
  --source-engine-archive "../build.noindex/source-engine/wallpaper-veil-source-engine.zip" \
  --output "../build.noindex/source-candidate/Wallpaper Veil.app"
python3 WallpaperVeil/ci/package_preview.py \
  --app "../build.noindex/source-candidate/Wallpaper Veil.app" \
  --destination "../build.noindex/source-candidate-artifacts"
```

Both source flags are required. The builder verifies every original archive file/directory/symlink,
rejects duplicate/unsafe ZIP paths or extra/missing bundle entries, and checks
engine and bootstrap hashes, all 95 native components and both architectures,
unchanged native source, and the original deep signature before packaging. It
preserves the input manifest and marks source-built engine provenance separately
from the current Wallpaper Veil source HEAD. Packaging checks the report against
signed bundle provenance and emits `wallpaper-veil-source-engine.json` instead
of the official binary pin. Without source flags, an engine must match the
pinned official executable/bootstrap hashes; an ad hoc source build cannot be
silently described as the official runtime.

Edit `WallpaperVeil/version.json` once to set the product version, positive build
number, release tag and channel. The builder validates their consistency and
uses them for both bundles and signed provenance; packaging rejects mismatches.
Source-engine candidates remain unreleased until qualification. Static input/signature and packaging checks
do not qualify application startup, menu behavior, real brightness, login,
permissions or display lifecycle. Repeat local application acceptance and UI
checks before installation or release. Do not upload a developer's local build
log; the permanent workflow's retained log comes from its public CI runner.

## Single-copy package checks

`WallpaperVeil/standalone_contract.py` is a build-time, read-only audit. Packaging
requires one complete top-level `Wallpaper Veil.app` in the ZIP, internal relative
symlinks, and native dependencies/runpaths that resolve to the app or macOS
system libraries. It checks each Mach-O architecture and uses the nearest app's
executable context, including the nested runtime. A Homebrew/developer-path
library, absolute or escaping symlink, missing bundled library or mismatched
architecture fails packaging. The extracted app is checked again, with deep
strict signature verification; the package summary records both audits.

These checks do not launch the app or establish Gatekeeper/notarization,
permissions, a relocated/fresh-account launch or hardware behavior. The finished
app contains its executable Lua/native code; writable settings live in
Application Support. Release JSON/checksum files are verification records, not
files an app user must install. Keep actual launch/relocation and feature
qualification distinct from structural package proof.

## Version and installed release checks

`WallpaperVeil/version.json` is the single edit point for version, incremented build,
release tag and channel. The builder rejects inconsistencies and writes both app
bundles and provenance from it. Packaging checks those signed fields again.

Run all `test_*.py` and `test_*.lua` suites for a release, plus the changed feature's
real installed checks. Quit the running app before an explicit UI qualification:

```sh
open -n "$HOME/Applications/Wallpaper Veil.app" --args --ui-test
```

This mode opens About, checks native current/newer/error fixtures, then invokes
the same manual action against public GitHub. It writes `ui-check.json` and
`update-check.json` under Application Support. Normal startup performs no update
check. The UI test's diagnostics use the signed version metadata.

Before publication, verify a clean committed build, regression/feature results,
restoration, signatures and package provenance. After publication, anonymously
download the ZIP/checksum, verify the received artifact and perform a fresh
installed-app smoke check. The live updater should then identify the published
tag as current. Retain a verified previous release ZIP and disclose unqualified
hardware/permission cases.
