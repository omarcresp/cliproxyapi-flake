# cliproxyapi-flake

[![Nix Flake](https://img.shields.io/badge/Nix-flake-5277C3?logo=nixos&logoColor=white)](https://nixos.org/)
[![Platform](https://img.shields.io/badge/platform-linux%20%7C%20macOS-6b7280)](https://github.com/omarcresp/cliproxyapi-flake)

A Nix flake packaging [CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) and its
[Management Center](https://github.com/router-for-me/Cli-Proxy-API-Management-Center) from upstream release artifacts,
with a home-manager module that runs it as a per-user service on both Linux and macOS.

## Why This Flake

- **The Management Center is pinned, not downloaded.** CLIProxyAPI normally fetches `management.html` from GitHub on
  first access and refreshes it every three hours. This flake pins the asset and points the service at it through
  `MANAGEMENT_STATIC_PATH`, so the panel is reproducible and available offline.
- **A per-user service, not a system daemon.** OAuth enrollment (`cliproxyapi -claude-login`, `-codex-login`, ...) is
  interactive and writes credentials into your home directory. The module uses a launchd agent on darwin and a systemd
  user service on Linux, so logins and the service share one identity.
- **Mutable config, on purpose.** The Management Center writes back to `config.yaml` and hot-reloads it. The module
  seeds that file once and then leaves it alone, so the panel stays fully functional and your secrets never enter the
  Nix store.

## Quick Start

```bash
nix run github:omarcresp/cliproxyapi-flake -- --help
nix build github:omarcresp/cliproxyapi-flake#cliproxyapi
```

## Home Manager

```nix
{
  inputs.cliproxyapi.url = "github:omarcresp/cliproxyapi-flake";

  # ... in your home-manager configuration:
  imports = [ inputs.cliproxyapi.homeModules.default ];

  services.cliproxyapi = {
    enable = true;

    settings = {
      host = "127.0.0.1";
      port = 8317;
      debug = false;
      remote-management = {
        allow-remote = false;
        disable-auto-update-panel = true;
      };
    };

    # Run at activation time, so secrets stay out of the Nix store.
    secretKeyCommand = "/usr/local/bin/op read op://Personal/cliproxyapi/secret-key";
    apiKeyCommand = "/usr/local/bin/op read op://Personal/cliproxyapi/proxy-key";
  };
}
```

The panel is then at <http://127.0.0.1:8317/management.html>, and the value from `secretKeyCommand` is what logs you in.

### Options

| Option | Default | Notes |
| --- | --- | --- |
| `settings` | `{}` | Seed config, written **only** when `config.yaml` is absent |
| `configDir` | `~/.cli-proxy-api` | Holds `config.yaml`, `auth/`, `logs/` — all mutable state |
| `localModel` | `true` | Use the embedded model catalog instead of fetching it from GitHub at startup |
| `secretKeyCommand` | `null` | stdout becomes `remote-management.secret-key` |
| `apiKeyCommand` | `null` | stdout becomes `api-keys[0]` |
| `tailscaleServePort` | `null` | darwin only; publishes the loopback listener to the tailnet |
| `managementCenter` | pinned panel | Set to a different package to override the panel |

`localModel` defaults to `true` so the service starts with no network access at all. Disable it to pick up newly
released upstream models without waiting for a package bump.

### Exposing to a tailnet

`tailscale serve` state lives in the node's control-plane record rather than any config file, so no Nix module can
express it. Setting `tailscaleServePort` applies it idempotently at activation instead:

```nix
services.cliproxyapi.tailscaleServePort = 8317;
```

CLIProxyAPI itself stays bound to `127.0.0.1` — nothing listens on untrusted networks. A missing or logged-out
`tailscaled` prints a warning rather than failing the activation.

## Updating

`releases.nix` holds the pinned versions and hashes for both upstreams. `./update.sh` regenerates it, and CI runs
hourly to bump, build, and commit.

## Credits

All the actual work belongs to [router-for-me/CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI) and
[router-for-me/Cli-Proxy-API-Management-Center](https://github.com/router-for-me/Cli-Proxy-API-Management-Center).
This repo only packages their release artifacts.
