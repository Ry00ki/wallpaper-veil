# Bundled engine policy

`upstream.json` is the qualified origin/input policy for Wallpaper Veil's bundled native engine. It pins the retained Hammerspoon source tag/commit/tree, bootstrap and 87 exact Git objects needed for product headers/legal documents, plus the current qualification inventories and feature integration map.

The original native implementation lives in retained Git history, not an editable duplicate under current main. `WallpaperVeil/upstream.py` validates and materializes inputs into temporary build staging; `WallpaperVeil/ci/build_source_engine.py` compiles the pinned historical checkout when rebuilding is necessary.

Only this README and the reviewed policy are allowed here. No native patches are currently qualified. Policy changes also require updating its reviewed SHA-256 anchor and the relevant qualification evidence; ordinary documentation links below can be maintained independently.

- [Architecture](../docs/architecture.md)
- [Original-to-owned integration and upstream updates](../docs/upstream-maintenance.md)
- [Build instructions](../docs/development.md)
- [Third-party terms](../THIRD_PARTY_NOTICES.md)
