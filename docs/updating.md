# Updates and release channels

About Wallpaper Veil checks the public GitHub release list when it opens. Stable and Preview are independent lists. Stable tags such as `v1.0.0` require GitHub's prerelease flag to be false; preview tags such as `v1.0.1-preview.1` require it to be true. Drafts, malformed tags and inconsistent channels are ignored. Numeric semantic version comparison prevents current/older versions from being installed automatically. Stable is the recommended UI choice; choosing a preview explicitly opts into an early-access build.

Choose **Download & Install** for a newer version. Merely opening About never downloads or installs an app. The existing app keeps running through download and verification; settings and login registration are not changed by the updater.

## Native installation transaction

1. Discovery binds the exact repository, release/tag/channel and asset ID/name/size/SHA-256. The native downloader fetches and verifies the bound build receipt, then streams the ZIP over HTTPS with bounded time/size and restricted GitHub/CDN redirects. Cancellation removes its private download staging.
2. The package reader checks ZIP bounds, local/central headers, CRCs, supported compression, expansion limits and a single app root. It rejects traversal, case/Unicode aliases, special files, unsafe symlinks and writes through symlink parents before extraction. New files use no-follow/exclusive opens in an owned private directory.
3. Native code validates bundle IDs, version/build/tag/channel, host requirements, embedded provenance, signed executable hashes and nested/all-architecture code seals. The target's parent must be writable. Current ad hoc builds trust the fixed repository's HTTPS/digests; a future Developer ID installation requires continuity of its Apple-anchored signing identity, not just a matching TeamID string.
4. The app copies its bundled `WallpaperVeilUpdater` into a private job directory. The installer owns `update.lock` and a durable journal. After a nonce-bound ready receipt, the current app quits through its normal shutdown path. No hardware-changing acceptance test runs during an end-user update.
5. A same-volume atomic swap keeps the previous bundle available for rollback. The new outer launcher accepts only the active installer's nonce-bound relaunch, starts the bundled runtime and waits for its ordinary menu/module/identity health checks. A fresh health receipt binds the nonce, version, build, source, process and actual installed path.
6. Only confirmed startup commits the update. Failure restores the verified old bundle and relaunches it; unexpected recovery identity preserves the recovery material and reports an error. The launcher detects an interrupted journal on a later opening and starts recovery before ordinary launch. Recovery copies remain verified ZIPs after successful cleanup.

Download/preparation can be cancelled before installer handoff. Once replacement begins, the installer must finish or recover it. Unwritable/read-only or translocated app locations require moving the app to a writable Applications folder or performing a manual replacement; the updater does not request a privileged helper or password workaround. It uses macOS frameworks/system libraries, without Python, Git, Xcode or a separately installed Hammerspoon.

## Qualification and distribution limits

The release process uses focused native download/archive/transaction regressions and installed-app checks, including a real public update path. Fixture launch/stop/health observers establish the transaction's decisions and actual filesystem swaps; they do not establish a real GUI launch or Gatekeeper approval. Those results are recorded separately.

Stable is a project release channel, not Apple certification. Builds remain ad hoc signed and unnotarized until Developer ID/notarization is available. macOS may require first-open or renewed Accessibility approval. The updater does not grant permissions or remove quarantine protections. Physical clock/widget and sleep/Spaces/display-reconnect qualification remains in issues #3/#4; signing/notarization remains #7.

For versions before 1.0, replace the app manually once to gain this installer. Manual ZIP replacement and the GitHub release page remain available for recovery. See [installation](../README.md#install-and-use), [development](development.md) and [architecture](architecture.md).
