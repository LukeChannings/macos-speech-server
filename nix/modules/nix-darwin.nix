# nix-darwin service module for macos-speech-server.
#
# Runs `speech-server serve` as a launchd daemon, pointed at a YAML config
# rendered from `services.speech-server.settings`. The daemon's HOME is set to
# stateDir so FluidAudio's model cache persists there rather than in the
# root account's home.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkIf
    escapeShellArg
    ;
  cfg = config.services.speech-server;

  yamlFormat = pkgs.formats.yaml { };
  configFile = yamlFormat.generate "speech-server.yaml" cfg.settings;
in
{
  imports = [
    ./options.nix
  ];

  config = mkIf cfg.enable {
    system.activationScripts.speech-server-dirs.text = ''
      mkdir -p ${escapeShellArg cfg.stateDir} ${escapeShellArg cfg.logDir}
    '';

    launchd.daemons.speech-server = {
      serviceConfig = {
        ProgramArguments = [
          "${cfg.package}/bin/speech-server"
          "serve"
        ];
        EnvironmentVariables = {
          SPEECH_SERVER_CONFIG = "${configFile}";
          HOME = cfg.stateDir;
        };
        WorkingDirectory = cfg.stateDir;
        StandardOutPath = "${cfg.logDir}/speech-server.log";
        StandardErrorPath = "${cfg.logDir}/speech-server-error.log";
        RunAtLoad = true;
        KeepAlive = true;
        ProcessType = "Background";
      };
    };
  };
}
