self:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.cliproxyapi;

  yamlFormat = pkgs.formats.yaml { };

  isDarwin = pkgs.stdenv.hostPlatform.isDarwin;

  configFile = "${cfg.configDir}/config.yaml";

  panelDir = "${cfg.managementCenter}/share/cliproxyapi/static";

  # The seed template carries every setting except the secrets, which are
  # substituted at activation time so they never enter the Nix store.
  seedTemplate = yamlFormat.generate "cliproxyapi-config-seed.yaml" (
    cfg.settings
    // {
      auth-dir = "${cfg.configDir}/auth";
    }
  );

  environment =
    {
      MANAGEMENT_STATIC_PATH = panelDir;
    }
    // cfg.extraEnvironment;

  arguments =
    [
      (lib.getExe cfg.package)
      "-config"
      configFile
    ]
    ++ lib.optional cfg.localModel "-local-model";

  # Seeds config.yaml exactly once. The Management Center rewrites this file at
  # runtime (PUT /v0/management/config.yaml) and hot-reloads it, so an existing
  # file is always left alone -- Nix owns the package and the service, not the
  # config.
  #
  # Kept as its own program rather than inline activation text so the secrets
  # can be exported into yq's environment without ever passing through a
  # command line (visible in ps) or the Nix store.
  seedProgram = pkgs.writeShellApplication {
    name = "cliproxyapi-seed";
    runtimeInputs = [ pkgs.yq-go ];
    text = ''
      config_dir=${lib.escapeShellArg cfg.configDir}
      config_file=${lib.escapeShellArg configFile}

      mkdir -p "$config_dir/auth" "$config_dir/logs"
      chmod 700 "$config_dir"

      if [ -e "$config_file" ]; then
        echo "cliproxyapi: $config_file already exists, leaving it alone"
        exit 0
      fi

      CPA_SECRET=""
      CPA_PROXY=""
      ${lib.optionalString (cfg.secretKeyCommand != null) ''
        CPA_SECRET="$(${cfg.secretKeyCommand} 2>/dev/null || true)"
      ''}
      ${lib.optionalString (cfg.apiKeyCommand != null) ''
        CPA_PROXY="$(${cfg.apiKeyCommand} 2>/dev/null || true)"
      ''}
      export CPA_SECRET CPA_PROXY

      if [ -z "$CPA_SECRET" ]; then
        echo "cliproxyapi: WARNING could not read the management secret key." >&2
        echo "cliproxyapi: WARNING seeding without it; every /v0/management route will 404" >&2
        echo "cliproxyapi: WARNING until remote-management.secret-key is set in $config_file" >&2
      fi

      umask 077
      yq '.remote-management.secret-key = strenv(CPA_SECRET)
          | .api-keys = [strenv(CPA_PROXY)]' \
        ${seedTemplate} > "$config_file.tmp"

      chmod 600 "$config_file.tmp"
      mv "$config_file.tmp" "$config_file"
      echo "cliproxyapi: seeded $config_file"
    '';
  };

  seedScript = ''
    run ${lib.getExe seedProgram}
  '';

  # tailscale serve is control-plane node state, not a config file, and no Nix
  # module (including nix-darwin's) can express it -- so apply it idempotently
  # here instead. A missing or logged-out tailscaled must never fail a switch.
  tailscaleServeScript = lib.optionalString (isDarwin && cfg.tailscaleServePort != null) ''
    if [ -x ${lib.escapeShellArg cfg.tailscaleCommand} ]; then
      if ${lib.escapeShellArg cfg.tailscaleCommand} serve status 2>/dev/null | grep -q ${toString cfg.tailscaleServePort}; then
        verboseEcho "cliproxyapi: tailscale serve already published on ${toString cfg.tailscaleServePort}"
      elif ${lib.escapeShellArg cfg.tailscaleCommand} serve --bg --http=${toString cfg.tailscaleServePort} \
             http://127.0.0.1:${toString cfg.settings.port} 2>/dev/null; then
        noteEcho "cliproxyapi: published to the tailnet on port ${toString cfg.tailscaleServePort}"
      else
        warnEcho "cliproxyapi: tailscale serve failed (daemon down or logged out?); skipping"
      fi
    else
      warnEcho "cliproxyapi: ${cfg.tailscaleCommand} not found; skipping tailnet exposure"
    fi
  '';
in
{
  options.services.cliproxyapi = {
    enable = lib.mkEnableOption "CLIProxyAPI, wrapping AI CLI subscriptions as a local API";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi;
      defaultText = lib.literalExpression "cliproxyapi-flake.packages.\${system}.cliproxyapi";
      description = "The CLIProxyAPI package to run.";
    };

    managementCenter = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.cliproxyapi-management-center;
      defaultText = lib.literalExpression "cliproxyapi-flake.packages.\${system}.cliproxyapi-management-center";
      description = ''
        Management Center package, exposed to the service through
        MANAGEMENT_STATIC_PATH. Pinning it here replaces the download from
        GitHub that CLIProxyAPI otherwise performs on first access.
      '';
    };

    configDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.cli-proxy-api";
      defaultText = lib.literalExpression "\"\${config.home.homeDirectory}/.cli-proxy-api\"";
      description = ''
        Directory holding config.yaml and the auth/ credential store. This is
        mutable state: the Management Center writes to both.
      '';
    };

    localModel = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Use the embedded model catalog instead of fetching models.json and
        codex_client_models.json from GitHub at startup. Enabled by default so
        the service starts without network access; disable it to pick up new
        upstream models without bumping the package.
      '';
    };

    settings = lib.mkOption {
      type = yamlFormat.type;
      default = { };
      description = ''
        Seed configuration, written to config.yaml only when that file does not
        already exist. Subsequent edits made through the Management Center are
        never overwritten, so this is a starting point rather than a source of
        truth.
      '';
    };

    secretKeyCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = lib.literalExpression ''"op read op://Personal/cliproxyapi/secret-key"'';
      description = ''
        Command whose stdout becomes remote-management.secret-key in the seeded
        config. Run at activation time so the secret never reaches the Nix
        store. Failure is not fatal: the key is left empty and a warning is
        printed.
      '';
    };

    apiKeyCommand = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = lib.literalExpression ''"op read op://Personal/cliproxyapi/proxy-key"'';
      description = ''
        Command whose stdout becomes the first entry of api-keys in the seeded
        config. This is the key clients present to the proxy.
      '';
    };

    tailscaleServePort = lib.mkOption {
      type = lib.types.nullOr lib.types.port;
      default = null;
      example = 8317;
      description = ''
        When set on darwin, publish the loopback listener to the tailnet with
        `tailscale serve` at this port. Applied idempotently at activation;
        a missing or logged-out tailscaled warns instead of failing the switch.
      '';
    };

    tailscaleCommand = lib.mkOption {
      type = lib.types.str;
      default = "/usr/local/bin/tailscale";
      description = ''
        Path to the tailscale CLI. Defaults to the location used by the
        standalone macOS app, which is not managed by Nix.
      '';
    };

    extraEnvironment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables for the service.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.settings ? port;
        message = "services.cliproxyapi.settings.port must be set.";
      }
      {
        assertion = cfg.tailscaleServePort == null || isDarwin;
        message = "services.cliproxyapi.tailscaleServePort is only supported on darwin.";
      }
    ];

    home.packages = [ cfg.package ];

    home.activation.cliproxyapi = lib.hm.dag.entryAfter [ "writeBoundary" ] (
      seedScript + tailscaleServeScript
    );

    launchd.agents.cliproxyapi = lib.mkIf isDarwin {
      enable = true;
      config = {
        ProgramArguments = arguments;
        EnvironmentVariables = environment;
        WorkingDirectory = cfg.configDir;
        RunAtLoad = true;
        KeepAlive = true;
        StandardOutPath = "${cfg.configDir}/logs/cliproxyapi.log";
        StandardErrorPath = "${cfg.configDir}/logs/cliproxyapi.error.log";
      };
    };

    systemd.user.services.cliproxyapi = lib.mkIf (!isDarwin) {
      Unit = {
        Description = "CLIProxyAPI";
        After = [ "network-online.target" ];
        Wants = [ "network-online.target" ];
      };

      Service = {
        ExecStart = lib.escapeShellArgs arguments;
        Environment = lib.mapAttrsToList (name: value: "${name}=${value}") environment;
        WorkingDirectory = cfg.configDir;
        Restart = "on-failure";
        RestartSec = 5;
      };

      Install.WantedBy = [ "default.target" ];
    };
  };
}
