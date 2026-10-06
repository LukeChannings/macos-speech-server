{
  lib,
  stdenvNoCC,
  cacert,
  git,
}:

# This project is a macOS-native Swift 6.2 app that links CoreML, the Apple
# Neural Engine and AVSpeech via FluidAudio. nixpkgs ships only Swift 5.10,
# which can neither parse the `swift-tools-version: 6.2` manifest nor provide
# those Apple frameworks, so the build shells out to the SYSTEM Xcode toolchain
# (`/usr/bin/xcrun swift build`). That needs the host SDK and network access for
# SwiftPM dependency resolution, so the derivation is marked `__noChroot`:
# it is deliberately NOT a hermetic build. It is here so the nix-darwin module
# has a `package` to install and deploy; reproducibility comes from the pinned
# Package.resolved, not from Nix.
stdenvNoCC.mkDerivation (_finalAttrs: {
  pname = "speech-server";
  version = "0.1.0";

  src = ./.;

  __noChroot = true;

  # git: SwiftPM shells out to it to clone dependencies, and the Nix stdenv
  # PATH does not include the system git. cacert: the trust store for those
  # HTTPS clones.
  nativeBuildInputs = [
    cacert
    git
  ];

  dontConfigure = true;

  buildPhase = ''
    runHook preBuild

    export HOME="$TMPDIR/home"
    mkdir -p "$HOME"

    # SwiftPM clones its dependencies over HTTPS during the build (this is a
    # non-hermetic `__noChroot` build). The Nix build environment carries no
    # trust store, so point git/curl at nixpkgs' cacert bundle.
    export GIT_SSL_CAINFO="${cacert}/etc/ssl/certs/ca-bundle.crt"
    export SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"
    export NIX_SSL_CERT_FILE="${cacert}/etc/ssl/certs/ca-bundle.crt"

    /usr/bin/xcrun swift build \
      --configuration release \
      --disable-sandbox \
      --scratch-path "$TMPDIR/build"

    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall

    install -Dm755 "$TMPDIR/build/release/speech-server" "$out/bin/speech-server"
    # The speechsynthesis engine looks for this helper next to the server
    # binary; without it the engine falls back to `say` (~1 s slower warm
    # time-to-first-audio for the System Voice).
    install -Dm755 "$TMPDIR/build/release/speech-synthesis-helper" "$out/bin/speech-synthesis-helper"

    runHook postInstall
  '';

  meta = {
    description = "On-device OpenAI-compatible speech API server with a Wyoming endpoint for Home Assistant";
    license = lib.licenses.agpl3Only;
    platforms = lib.platforms.darwin;
    mainProgram = "speech-server";
  };
})
