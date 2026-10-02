{
  description = "macos-speech-server — on-device OpenAI-compatible speech API + Wyoming server";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-compat.url = "https://git.lix.systems/lix-project/flake-compat/archive/main.tar.gz";
    flake-compat.flake = false;
    treefmt-nix.url = "github:numtide/treefmt-nix";
  };

  outputs =
    {
      self,
      treefmt-nix,
      flake-parts,
      ...
    }@inputs:
    flake-parts.lib.mkFlake { inherit inputs self; } {
      imports = [
        flake-parts.flakeModules.easyOverlay
        treefmt-nix.flakeModule
        ./nix/flake-parts/darwinModules.nix
      ];

      # Darwin only: the server links CoreML, the Apple Neural Engine and
      # AVSpeech, none of which exist off macOS. FluidAudio's ASR/TTS models run
      # on the ANE and Qwen3 needs macOS 15+. There is no Linux build.
      systems = [
        "aarch64-darwin"
        "x86_64-darwin"
      ];

      perSystem =
        { config, pkgs, ... }:
        {
          packages.speech-server = pkgs.callPackage ./package.nix { };

          overlayAttrs = {
            inherit (config.packages) speech-server;
          };

          # The developer shell (entered by .envrc → shell.nix → this). Carries
          # the Nix meta-tooling (the treefmt wrapper) and git. The Swift 6.2
          # toolchain itself is NOT provided by Nix — nixpkgs ships Swift 5.10,
          # which cannot parse this package's `swift-tools-version: 6.2` manifest
          # nor link the Apple frameworks FluidAudio needs. Build and format with
          # the system Xcode toolchain (`xcrun swift build`, `xcrun swift format`).
          devShells.default = pkgs.mkShell {
            packages = [
              pkgs.git
              config.treefmt.build.wrapper
            ];
          };

          treefmt = {
            programs.nixfmt.enable = true;
            programs.deadnix.enable = true;
            programs.statix.enable = true;
            # Keep the `{ ... }:` set pattern in default.nix: `nix-build -A` only
            # auto-calls set-pattern lambdas, but statix's empty_pattern lint
            # would rewrite it to `_:`, which nix-build refuses to auto-call.
            programs.statix.disabled-lints = [ "empty_pattern" ];
            # Swift is formatted with the Xcode-bundled `swift format` (see
            # .swift-format), not by treefmt — nixpkgs' swift-format is 5.10-era
            # and does not understand this repo's rule set.
          };
        };

      flake.darwinModules.default = ./nix/modules/nix-darwin.nix;
    };
}
