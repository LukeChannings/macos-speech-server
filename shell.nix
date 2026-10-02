# Developer shell, entered by `.envrc` (`use nix`). Delegates to the flake's
# `devShells.default` via flake-compat so there is a single source of truth.
#
# NB: this shell does NOT provide a Swift toolchain. nixpkgs ships Swift 5.10,
# which cannot build this Swift 6.2 / Apple-framework package. Build, test and
# format with the system Xcode toolchain: `xcrun swift build`, `swift test`,
# `swift format --in-place --recursive Sources/ Tests/`.
(import ./. { }).devShells.${builtins.currentSystem}.default
