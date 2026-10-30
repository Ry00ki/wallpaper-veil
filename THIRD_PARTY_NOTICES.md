# Wallpaper Veil third-party notices

Wallpaper Veil's original code is licensed under the MIT licence, reproduced in [WallpaperVeil/LICENSE](WallpaperVeil/LICENSE). The root [LICENSE](LICENSE) retains the Hammerspoon copyright notice and MIT terms alongside Wallpaper Veil's copyright notice.

## Hammerspoon

This source copy is based on Hammerspoon 1.1.1, commit `1469832361b4c3687ec7d589c1b4efe4d3b742ee`. The prototype packages the official Hammerspoon 1.1.1 build 6936 native runtime. Hammerspoon is MIT-licensed. Its original licence is preserved verbatim in [LICENSES/Hammerspoon-MIT.txt](LICENSES/Hammerspoon-MIT.txt), and its credits are retained in [CREDITS.md](CREDITS.md).

Hammerspoon is based on Mjolnir, which is based on Hydra. Hammerspoon's icon is attributed to Juerd Waalboer in its credits. Retain those notices while the corresponding material remains included.

## Bundled components

Dependencies retain their own copyright notices and licences. Wallpaper Veil's MIT declaration does not replace those terms. The checked-in component sources retain their original notices; the CocoaPods acknowledgement files include component-specific terms, including MIT, BSD and public-domain notices:

- [Third-party licence text](<Pods/Target Support Files/Pods-Hammerspoon/Pods-Hammerspoon-acknowledgements.markdown>)
- [Machine-readable acknowledgements](<Pods/Target Support Files/Pods-Hammerspoon/Pods-Hammerspoon-acknowledgements.plist>)

The builder copies the project licence, Wallpaper Veil's MIT licence, the original Hammerspoon MIT licence, this notice, upstream credits and dependency acknowledgements into the nested runtime's `Contents/Resources/Acknowledgements`. It also copies component licence/notice files from extension and vendor sources, plus the Lua 5.4.7 licence documentation, under `Acknowledgements/Components`, preserving source-relative paths and a build manifest. Preserve these files and relevant component notices in redistributed source and app bundles. Review notices again when changing or removing dependencies.
