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
  inherit (lib) mkDefault mkIf;
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

    launchd.user.agents.speech-server.serviceConfig = {
      ProgramArguments = [
        "${cfg.package}/bin/speech-server"
        "serve"
      ];
      EnvironmentVariables.SPEECH_SERVER_CONFIG = "${configFile}";
      # Agents default to Aqua already; stated explicitly so the server never
      # comes up in a Background (SSH / non-GUI) session where the voice
      # inventory is degraded.
      LimitLoadToSessionType = mkDefault "Aqua";
      RunAtLoad = true;
      KeepAlive = true;
      ProcessType = "Background";
      # launchd discards stdout/stderr unless they name a file. These are
      # mkDefault so a host log funnel (or a plain assignment) takes over
      # placement and rotation; ~/Library/Logs always exists and is writable by
      # the agent's user, so no pre-creation is needed.
      StandardOutPath = mkDefault "${home}/Library/Logs/speech-server.log";
      StandardErrorPath = mkDefault "${home}/Library/Logs/speech-server.log";
    };
  };
}
