{
  lib,
  pkgs,
  ...
}:
let
  inherit (lib)
    literalExpression
    mkEnableOption
    mkOption
    mkRemovedOptionModule
    types
    ;

  yamlFormat = pkgs.formats.yaml { };
in
{
  imports = [
    # The module used to run a root-domain launchd daemon with its own HOME
    # and log directory. It is now a gui agent in the primary user's session
    # (see nix-darwin.nix), which inherits HOME from that session and leaves
    # log placement to the host.
    (mkRemovedOptionModule [ "services" "speech-server" "stateDir" ] ''
      speech-server now runs as a gui launchd agent in `system.primaryUser`'s
      login session, so HOME (and with it FluidAudio's model caches under
      ~/Library) comes from that session. There is no state directory to set.
    '')
    (mkRemovedOptionModule [ "services" "speech-server" "logDir" ] ''
      Set `launchd.user.agents.speech-server.serviceConfig.StandardOutPath` /
      `StandardErrorPath` instead; the module only provides mkDefault values.
    '')
  ];

  options.services.speech-server = {
    enable = mkEnableOption ''
      macos-speech-server, the on-device OpenAI-compatible speech API and
      Wyoming server, as a launchd gui agent in `system.primaryUser`'s login
      session'';

    package = mkOption {
      type = types.package;
      # Prefer a `speech-server` from the consumer's overlay (the usual
      # mkPackageOption convention), otherwise build this flake's own
      # package.nix against the consumer's pkgs — the same derivation the
      # flake exports as `packages.<system>.speech-server`.
      default = pkgs.speech-server or (pkgs.callPackage ../../package.nix { });
      defaultText = literalExpression "pkgs.speech-server or macos-speech-server.packages.\${system}.speech-server";
      description = ''
        The macos-speech-server package to run. Defaults to `pkgs.speech-server`
        when an overlay provides it, otherwise to this flake's package.
      '';
    };

    # The entire speech-server.yaml, expressed as a Nix attrset and serialised
    # to YAML at build time. The agent is pointed at the result via
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
        tts = {
          engine = "speechsynthesis";
          speechsynthesis.default_voice = "System Voice";
        };
      };
      description = ''
        Contents of speech-server.yaml as a Nix attrset. Serialised to YAML and
        passed to the agent through the SPEECH_SERVER_CONFIG environment
        variable. See speech-server.yaml.example for the full schema; every
        field is optional and defaults to the server's built-in value.

        Note the listen host/port can also be driven from here
        (`servers.http.host`, `servers.http.port`, `servers.wyoming.*`).
      '';
    };
  };
}
