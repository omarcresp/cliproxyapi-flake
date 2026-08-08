{
  description = "CLIProxyAPI and its Management Center packaged from upstream release artifacts";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      releases = import ./releases.nix;

      serverRepo = "router-for-me/CLIProxyAPI";
      panelRepo = "router-for-me/Cli-Proxy-API-Management-Center";

      assetSuffixes = {
        x86_64-linux = "linux_amd64";
        aarch64-darwin = "darwin_aarch64";
      };

      supportedSystems = builtins.attrNames releases.server.sources;

      eachSystem = f: lib.genAttrs supportedSystems (system: f nixpkgs.legacyPackages.${system});

      mkServer =
        pkgs:
        let
          system = pkgs.stdenv.hostPlatform.system;
          inherit (releases.server) version;
        in
        pkgs.stdenv.mkDerivation {
          pname = "cliproxyapi";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/${serverRepo}/releases/download/v${version}/CLIProxyAPI_${version}_${assetSuffixes.${system}}.tar.gz";
            inherit (releases.server.sources.${system}) hash;
          };

          # Release archives are flat: cli-proxy-api, LICENSE, README*,
          # config.example.yaml. There is no top-level directory to strip.
          sourceRoot = ".";

          # The default Linux artifact is built with CGO_ENABLED=1 for the
          # dynamic plugin host, so it needs the usual interpreter rewrite.
          # The darwin artifact links only against libSystem.
          nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.autoPatchelfHook
          ];

          buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
            pkgs.stdenv.cc.cc.lib
          ];

          dontConfigure = true;
          dontBuild = true;

          installPhase = ''
            runHook preInstall

            install -Dm755 cli-proxy-api "$out/bin/cliproxyapi"
            install -Dm644 config.example.yaml "$out/share/cliproxyapi/config.example.yaml"

            runHook postInstall
          '';

          meta = {
            description = "Wraps Claude Code, Codex, Gemini and Grok subscriptions as an OpenAI/Anthropic compatible API";
            homepage = "https://github.com/${serverRepo}";
            license = lib.licenses.mit;
            mainProgram = "cliproxyapi";
            platforms = supportedSystems;
            sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
          };
        };

      mkPanel =
        pkgs:
        let
          inherit (releases.panel) version;
        in
        pkgs.stdenvNoCC.mkDerivation {
          pname = "cliproxyapi-management-center";
          inherit version;

          src = pkgs.fetchurl {
            url = "https://github.com/${panelRepo}/releases/download/v${version}/management.html";
            inherit (releases.panel) hash;
          };

          dontUnpack = true;

          # CLIProxyAPI resolves the control panel through MANAGEMENT_STATIC_PATH,
          # which expects a directory containing management.html. Pinning the asset
          # here replaces the GitHub download upstream performs on first access,
          # and lets disable-auto-update-panel keep it from being refreshed.
          installPhase = ''
            runHook preInstall

            install -Dm444 "$src" "$out/share/cliproxyapi/static/management.html"

            runHook postInstall
          '';

          meta = {
            description = "Web UI for managing a CLIProxyAPI instance";
            homepage = "https://github.com/${panelRepo}";
            license = lib.licenses.mit;
            platforms = supportedSystems;
          };
        };
    in
    {
      packages = eachSystem (pkgs: rec {
        cliproxyapi = mkServer pkgs;
        cliproxyapi-management-center = mkPanel pkgs;
        default = cliproxyapi;
      });

      homeModules = rec {
        cliproxyapi = import ./modules/home-manager.nix self;
        default = cliproxyapi;
      };

      # Retained for consumers still using the pre-rename output name.
      homeManagerModules = self.homeModules;
    };
}
