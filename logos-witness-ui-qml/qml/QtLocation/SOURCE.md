# Vendored Qt 6.9.2 QtLocation QML import

This directory is copied verbatim from
`github:nixos/nixpkgs/e9f00bd893984bc8ce46c895c3bf7cac95331127#qt6.qtlocation`
(the nixpkgs rev `logos-basecamp/flake.lock` pins, so the ABI matches
basecamp's bundled Qt by construction).

Why vendored: basecamp does not bundle `QtLocation`/`QtPositioning`. Its
launch wrapper also hard-resets `QT_PLUGIN_PATH`, so we can't extend it
from a parent shell. Bundling the QML import dir inside the UI plugin
makes Qt's resolver pick it up from
`<plugin-install-dir>/qml/QtLocation/qmldir`.

Refresh procedure when basecamp's pin moves: see README → "Vendored Qt
imports".

`metadata.json` declares the matching Nix packages under
`nix.packages.runtime` for documentation; `mkLogosQmlModule`'s QML-only
build path does not currently consume them. If/when it does, the vendored
copy can be retired.
