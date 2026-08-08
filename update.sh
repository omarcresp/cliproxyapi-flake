#!/usr/bin/env bash
set -euo pipefail

# Regenerates releases.nix from the newest ready upstream releases.
#
# Hashes come from the `digest` field GitHub publishes alongside each release
# asset, so nothing is downloaded here. A release is only considered once every
# asset we need carries a valid digest -- upstream ships assets incrementally,
# and picking up a half-published tag would pin a hash that never resolves.

server_repo="router-for-me/CLIProxyAPI"
panel_repo="router-for-me/Cli-Proxy-API-Management-Center"

for cmd in curl jq; do
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "Missing required command: ${cmd}" >&2
    exit 1
  fi
done

curl_auth_args=()
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
  curl_auth_args=(-H "Authorization: Bearer ${GITHUB_TOKEN}")
fi

fetch_releases() {
  local repo="$1"
  curl -fsSL "${curl_auth_args[@]}" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/${repo}/releases?per_page=100"
}

to_sri() {
  local digest="$1"
  local hex_hash="${digest#sha256:}"

  if command -v nix >/dev/null 2>&1; then
    nix hash convert --hash-algo sha256 --from base16 --to sri "${hex_hash}"
  elif command -v xxd >/dev/null 2>&1 && command -v base64 >/dev/null 2>&1; then
    printf 'sha256-%s\n' "$(printf '%s' "${hex_hash}" | xxd -r -p | base64 | tr -d '\n')"
  else
    echo "Missing required command for SRI conversion. Install nix or xxd+base64." >&2
    exit 1
  fi
}

# Emits the newest non-prerelease whose required assets all carry a digest.
# $2 is a jq expression producing the list of asset names a release must have,
# with the tag's version available as $version.
select_ready_release() {
  local releases_json="$1"
  local required_expr="$2"
  local label="$3"
  local candidate_tag release_json selected_tag

  candidate_tag="$(jq -r '[.[] | select(.prerelease == false)][0].tag_name // empty' <<<"${releases_json}")"

  release_json="$(
    jq -c --argjson dummy 0 '
      def valid_digest:
        type == "string" and test("^sha256:[0-9a-fA-F]{64}$");

      def version:
        .tag_name | if startswith("v") then .[1:] else . end;

      def ready:
        . as $release
        | version as $version
        | ('"${required_expr}"') as $required
        | all($required[]; . as $name | any($release.assets[]?; .name == $name and (.digest | valid_digest)));

      [.[] | select(.prerelease == false) | select(ready)][0] // empty
    ' <<<"${releases_json}"
  )"

  if [[ -z "${release_json}" ]]; then
    echo "Could not find a complete ${label} release in the first 100 GitHub releases." >&2
    exit 1
  fi

  selected_tag="$(jq -r '.tag_name' <<<"${release_json}")"
  if [[ -n "${candidate_tag}" && "${candidate_tag}" != "${selected_tag}" ]]; then
    echo "Newest ${label} release '${candidate_tag}' is not ready; keeping '${selected_tag}' until all required assets and digests are published." >&2
  fi

  printf '%s\n' "${release_json}"
}

asset_hash() {
  local release_json="$1"
  local asset_name="$2"
  local digest

  digest="$(
    jq -r --arg name "${asset_name}" '
      .assets[] | select(.name == $name) | .digest // empty
    ' <<<"${release_json}" | head -n 1
  )"

  if [[ -z "${digest}" ]]; then
    echo "Could not find a digest for asset '${asset_name}'." >&2
    exit 1
  fi

  if [[ ! "${digest}" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
    echo "Unexpected digest format for '${asset_name}': ${digest}" >&2
    exit 1
  fi

  to_sri "${digest}"
}

write_release_notes() {
  local component="$1"
  local release_json="$2"

  if [[ -z "${RELEASE_NOTES_DIR:-}" ]]; then
    return
  fi

  mkdir -p "${RELEASE_NOTES_DIR}"
  jq -r '.body // ""' <<<"${release_json}" >"${RELEASE_NOTES_DIR}/${component}.md"
  jq -r '.html_url // ""' <<<"${release_json}" >"${RELEASE_NOTES_DIR}/${component}.url"
}

version_of() {
  jq -r '.tag_name | if startswith("v") then .[1:] else . end' <<<"$1"
}

server_releases="$(fetch_releases "${server_repo}")"
panel_releases="$(fetch_releases "${panel_repo}")"

server_release="$(select_ready_release "${server_releases}" \
  '["CLIProxyAPI_\($version)_linux_amd64.tar.gz", "CLIProxyAPI_\($version)_darwin_aarch64.tar.gz"]' \
  server)"
panel_release="$(select_ready_release "${panel_releases}" '["management.html"]' panel)"

server_version="$(version_of "${server_release}")"
panel_version="$(version_of "${panel_release}")"

linux_hash="$(asset_hash "${server_release}" "CLIProxyAPI_${server_version}_linux_amd64.tar.gz")"
darwin_hash="$(asset_hash "${server_release}" "CLIProxyAPI_${server_version}_darwin_aarch64.tar.gz")"
panel_hash="$(asset_hash "${panel_release}" "management.html")"

write_release_notes server "${server_release}"
write_release_notes panel "${panel_release}"

cat <<EOF
{
  server = {
    version = "${server_version}";
    sources = {
      x86_64-linux.hash = "${linux_hash}";
      aarch64-darwin.hash = "${darwin_hash}";
    };
  };

  panel = {
    version = "${panel_version}";
    hash = "${panel_hash}";
  };
}
EOF
