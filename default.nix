# A function so the legacy entrypoint is `import ./. {}` — the form shell.nix
# uses and the form a flake-compat CI loader would call. The args are accepted
# and ignored; `...` keeps it forward-compatible with any extra args.
#
# The `{ ... }:` set pattern is load-bearing: `nix-build -A` only auto-calls
# set-pattern lambdas, so `nix-build default.nix -A speech-server` depends on
# it. statix's empty_pattern lint would otherwise collapse it to `_:` (which
# nix-build refuses to auto-call) — the flake's treefmt config disables that
# lint to preserve it.
{ ... }:
let
  lockFile = builtins.fromJSON (builtins.readFile ./flake.lock);
  flake-compat-node = lockFile.nodes.${lockFile.nodes.root.inputs.flake-compat};
  flake-compat = fetchTarball {
    inherit (flake-compat-node.locked) url;
    sha256 = flake-compat-node.locked.narHash;
  };

  flake = import flake-compat {
    src = ./.;
    copySourceTreeToStore = false;
    useBuiltinsFetchTree = true;
  };

  system = builtins.currentSystem;
in
flake.defaultNix
// {
  inherit (flake.defaultNix.packages.${system}) speech-server;
}
