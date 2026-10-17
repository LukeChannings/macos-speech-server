# nix-darwin service module for macos-speech-server.
#
# Runs `speech-server serve` as a launchd **gui agent** in the primary user's
# login session (`launchd.user.agents`, installed into
# ~<system.primaryUser>/Library/LaunchAgents), pointed at a YAML config
# rendered from `services.speech-server.settings`.
#
# Why an agent and not a system daemon: macOS only exposes the downloaded
# Enhanced/Premium voices, the Siri voices reachable through `say`, and the
# user's System Voice setting to a process in a GUI login session. A
# LaunchDaemon (root or a role account) sees only the ~70 built-in compact
# voices. HOME is inherited from the session, so FluidAudio's model caches land
# under the user's ~/Library and ~/.cache.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib) mkDefault mkIf mkOverride;

  # Log-path priority. It has to sit strictly between mkDefault (1000) and
  # mkOptionDefault (1500):
  #   - below mkDefault, so a host log funnel that claims agent log paths with
  #     mkDefault wins instead of conflicting (two mkDefaults with different
  #     values are an evaluation error, not an override);
  #   - above mkOptionDefault, because StandardOutPath is `nullOr path` with
  #     `default = null` at 1500. A second 1500 definition makes the merge fail
  #     with "defined both null and not null" on every host without a funnel.
  mkLogDefault = mkOverride 1250;
  cfg = config.services.speech-server;

  yamlFormat = pkgs.formats.yaml { };
  configFile = yamlFormat.generate "speech-server.yaml" cfg.settings;

  user = config.system.primaryUser;
  # The primary user's home, for the default log path. users.users.<name>.home
  # is null unless the host declares it; fall back to the macOS convention.
  # A null primaryUser is rejected by the assertion below.
  home =
    let
      declared = if user == null then null else config.users.users.${user}.home or null;
    in
    # toString: primaryUser is `nullOr str`; it keeps a null user from throwing
    # here (a coercion error) before the assertion can report it.
    if declared != null then declared else "/Users/${toString user}";
in
{
  imports = [
    ./options.nix
  ];

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = user != null;
        message = ''
          services.speech-server runs as a launchd gui agent in the primary
          user's login session; set `system.primaryUser`.
        '';
      }
    ];

    launchd.user.agents.speech-server = {
      # `command`, not a bare store-path ProgramArguments[0]: nix-darwin renders
      # it as `/bin/sh -c "/bin/wait4path /nix/store && exec …"`. Both binaries
      # live on the root volume, so on hosts where /nix mounts late (and GUI
      # login can come first) the agent waits for the store. A direct exec of a
      # missing store path fails the spawn with EX_CONFIG (78), and launchd
      # then penalty-boxes the job permanently; KeepAlive does not recover it.
      command = "${lib.escapeShellArg (lib.getExe' cfg.package "speech-server")} serve";

      # No WorkingDirectory on purpose: cwd is `/`, which is fine. The config
      # comes from SPEECH_SERVER_CONFIG (so the ./speech-server.yaml lookup is
      # never used) and the model caches are under HOME. The old daemon needed
      # a stateDir because it had no session HOME.
      serviceConfig = {
        EnvironmentVariables.SPEECH_SERVER_CONFIG = "${configFile}";
        # Agents default to Aqua already; stated explicitly so the server never
        # comes up in a Background (SSH / non-GUI) session where the voice
        # inventory is degraded.
        LimitLoadToSessionType = mkDefault "Aqua";
        RunAtLoad = mkDefault true;
        KeepAlive = mkDefault true;
        ProcessType = mkDefault "Background";
        # launchd discards stdout/stderr unless they name a file. See
        # mkLogDefault above: a host funnel's mkDefault or a plain assignment
        # takes over. ~/Library/Logs always exists and is writable by the
        # agent's user, so no pre-creation is needed.
        StandardOutPath = mkLogDefault "${home}/Library/Logs/speech-server.log";
        StandardErrorPath = mkLogDefault "${home}/Library/Logs/speech-server.log";
      };
    };
  };
}
