{
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    mkEnableOption
    mkOption
    mkPackageOption
    types
    ;

  yamlFormat = pkgs.formats.yaml { };
in
{
  options.services.speech-server = {
    enable = mkEnableOption "macos-speech-server on-device speech API + Wyoming server";

    package = mkPackageOption pkgs "speech-server" { };

    # The entire speech-server.yaml, expressed as a Nix attrset and serialised
    # to YAML at build time. The daemon is pointed at the result via
    # SPEECH_SERVER_CONFIG. Mirrors speech-server.yaml.example one-for-one:
    # all keys are optional and fall back to the binary's built-in defaults.
    settings = mkOption {
      inherit (yamlFormat) type;
      default = { };
      example = {
        log_level = "notice";
        servers = {
          http = {
            host = "0.0.0.0";
            port = 8080;
          };
          wyoming.port = 10300;
        };
        stt = {
          engine = "parakeet";
          parakeet.model_version = "v3";
        };
        tts.engine = "kokoro";
      };
      description = ''
        Contents of speech-server.yaml as a Nix attrset. Serialised to YAML and
        passed to the daemon through the SPEECH_SERVER_CONFIG environment
        variable. See speech-server.yaml.example for the full schema; every
        field is optional and defaults to the server's built-in value.

        Note the listen host/port can also be driven from here
        (`servers.http.host`, `servers.http.port`, `servers.wyoming.*`).
      '';
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/speech-server";
      description = ''
        Working directory and HOME for the daemon. FluidAudio caches its
        downloaded ASR/TTS CoreML models under here
        (Library/Application Support/FluidAudio and .cache/fluidaudio), so this
        must be writable and persist across restarts. Created on activation.
      '';
    };

    logDir = mkOption {
      type = types.str;
      default = "/var/log";
      description = "Directory for the daemon's stdout/stderr log files.";
    };
  };
}
