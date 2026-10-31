# Wallpaper Veil third-party notices

Wallpaper Veil's original code is licensed under the MIT licence, reproduced in [WallpaperVeil/LICENSE](WallpaperVeil/LICENSE). The root [LICENSE](LICENSE) retains the Hammerspoon copyright notice and MIT terms alongside Wallpaper Veil's copyright notice.

## Hammerspoon and original source

The bundled engine is based on Hammerspoon 1.1.1, commit `1469832361b4c3687ec7d589c1b4efe4d3b742ee`, build 6936. Each release's provenance identifies whether its verified engine input was source-built or from the pinned official release. Hammerspoon's original MIT licence is preserved verbatim in [LICENSES/Hammerspoon-MIT.txt](LICENSES/Hammerspoon-MIT.txt), with original credits in [CREDITS.md](CREDITS.md).

The duplicated upstream working-tree folders were removed from current main; original code and terms remain in retained tag/history `1.1.1`. This does not remove the bundled engine or its licensing obligations. See the [integration map and update procedure](docs/upstream-maintenance.md).

## Bundled component terms

Dependencies retain their own copyrights and licences. Wallpaper Veil's MIT declaration does not replace those terms. The qualified [input policy](engine/upstream.json) lists all 81 component notices and the two CocoaPods acknowledgement files by original path and Git object. The builder recovers the exact pinned bytes into temporary staging and preserves their original relative paths in the app's acknowledgements.

- [Pinned third-party licence text](https://github.com/Hammerspoon/hammerspoon/blob/1469832361b4c3687ec7d589c1b4efe4d3b742ee/Pods/Target%20Support%20Files/Pods-Hammerspoon/Pods-Hammerspoon-acknowledgements.markdown)
- [Pinned machine-readable acknowledgements](https://github.com/Hammerspoon/hammerspoon/blob/1469832361b4c3687ec7d589c1b4efe4d3b742ee/Pods/Target%20Support%20Files/Pods-Hammerspoon/Pods-Hammerspoon-acknowledgements.plist)

The builder retains project MIT, original Hammerspoon MIT, credits, this notice, component documents and Lua 5.4.7 licence documentation under the nested runtime's `Contents/Resources/Acknowledgements`. Qualified source-built inputs also retain their source-engine notice inventory. Preserve these documents in redistributed bundles and review them when changing/removing dependencies. The source remains available at its pinned historical identity.
