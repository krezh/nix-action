#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "${ACTION_DIR}/scripts/lib.sh"

distribution="${PREPARED_DISTRIBUTION:-lix}"
system="${PREPARED_SYSTEM:-$(detect_system)}"
version="${PREPARED_VERSION:?missing PREPARED_VERSION}"
installer_version="${PREPARED_INSTALLER_VERSION:?missing PREPARED_INSTALLER_VERSION}"
tarball_sha256="${PREPARED_TARBALL_SHA256:-}"
installer_sha256="${PREPARED_INSTALLER_SHA256:-}"
cache_dir="${PREPARED_CACHE_DIR:-${RUNNER_TEMP:-/tmp}/nix-action-cache}"
cache_hit_raw="${CACHE_HIT:-}"
start_ts="${PREPARED_START_TS:-$(date +%s)}"
os_type="$(uname -s)"

mkdir -p "$cache_dir"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [ -n "${INPUT_INSTALLER_URL:-}" ]; then
  installer_url="$INPUT_INSTALLER_URL"
  inst_url_hash="$(sha256_string "$installer_url")"
  installer_name="lix-installer-url-${inst_url_hash:0:12}-${system}"
else
  installer_url="https://install.lix.systems/lix/${installer_version}/lix-installer-${system}"
  installer_name="lix-installer-${installer_version}-${system}"
fi
installer_bin="${cache_dir}/${installer_name}"

for stale in "${cache_dir}"/lix-installer-*; do
  [ -e "$stale" ] || continue
  if [ "$stale" != "$installer_bin" ]; then
    rm -f "$stale"
  fi
done

installer_from_cache="false"
if [ -x "$installer_bin" ] && verify_sha256 "$installer_bin" "$installer_sha256"; then
  installer_from_cache="true"
  info "Using cached lix-installer (${installer_version})"
else
  info "Downloading lix-installer from ${installer_url}"
  dl_installer="${tmp_dir}/lix-installer"
  download_file "$installer_url" "$dl_installer"
  if [ -n "$installer_sha256" ] && ! verify_sha256 "$dl_installer" "$installer_sha256"; then
    actual_sha="$(sha256_file "$dl_installer")"
    die "SHA256 mismatch for lix-installer (${installer_url}): expected ${installer_sha256}, got ${actual_sha}"
  fi
  chmod +x "$dl_installer"
  mv -f "$dl_installer" "$installer_bin"
fi

package_arg=""
tarball_from_cache="false"
if [ -n "${INPUT_PACKAGE_URL:-}" ] && { [ -e "$INPUT_PACKAGE_URL" ] || printf '%s' "$INPUT_PACKAGE_URL" | grep -q '^file://'; }; then
  package_arg="$INPUT_PACKAGE_URL"
  tarball_from_cache="true"
  info "Using local Lix package at ${package_arg}"
else
  if [ -n "${INPUT_PACKAGE_URL:-}" ]; then
    tarball_url="$INPUT_PACKAGE_URL"
    pkg_url_hash="$(sha256_string "$tarball_url")"
    tarball_name="lix-pkg-url-${pkg_url_hash:0:12}-${system}.tar.xz"
  else
    tarball_url="https://releases.lix.systems/lix/lix-${version}/lix-${version}-${system}.tar.xz"
    tarball_name="lix-${version}-${system}.tar.xz"
  fi
  tarball_path="${cache_dir}/${tarball_name}"

  for stale in "${cache_dir}"/lix-*.tar.xz; do
    [ -e "$stale" ] || continue
    if [ "$stale" != "$tarball_path" ]; then
      rm -f "$stale"
    fi
  done

  if [ -z "$tarball_sha256" ] && [ -z "${INPUT_PACKAGE_URL:-}" ]; then
    sha_file="${tmp_dir}/lix.tar.xz.sha256"
    if download_file "${tarball_url}.sha256" "$sha_file"; then
      tarball_sha256="$(awk '{print $1}' "$sha_file")"
    else
      warn "Could not download ${tarball_url}.sha256; skipping checksum verification for custom version"
    fi
  fi

  if [ -f "$tarball_path" ] && verify_sha256 "$tarball_path" "$tarball_sha256"; then
    tarball_from_cache="true"
    info "Using cached Lix tarball (${version})"
  else
    info "Downloading Lix ${version} tarball from ${tarball_url}"
    dl_tarball="${tmp_dir}/lix.tar.xz"
    download_file "$tarball_url" "$dl_tarball"
    if [ -n "$tarball_sha256" ] && ! verify_sha256 "$dl_tarball" "$tarball_sha256"; then
      actual_sha="$(sha256_file "$dl_tarball")"
      die "SHA256 mismatch for ${tarball_url}: expected ${tarball_sha256}, got ${actual_sha}"
    fi
    mv -f "$dl_tarball" "$tarball_path"
  fi
  package_arg="$tarball_path"
fi

effective_cache_hit="false"
if [ "${INPUT_CACHE_INSTALLER:-true}" != "true" ]; then
  effective_cache_hit="skipped"
elif [ "$cache_hit_raw" = "true" ] && [ "$installer_from_cache" = "true" ] && [ "$tarball_from_cache" = "true" ]; then
  effective_cache_hit="true"
elif [ "$installer_from_cache" = "true" ] || [ "$tarball_from_cache" = "true" ]; then
  effective_cache_hit="partial"
fi

setup_kvm_permissions

init_input="${INPUT_INIT:-auto}"
effective_init="$init_input"
if [ "$init_input" = "auto" ]; then
  if [ "$os_type" = "Darwin" ]; then
    effective_init="launchd"
  else
    if [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1 && systemctl status >/dev/null 2>&1; then
      effective_init="systemd"
    else
      effective_init="none"
    fi
  fi
fi

if [ "${INPUT_REINSTALL:-false}" = "true" ] && [ -f /nix/receipt.json ] && [ -x /nix/lix-installer ]; then
  info "Uninstalling existing Lix installation before reinstall"
  run_root /nix/lix-installer uninstall --no-confirm || warn "Previous uninstall returned non-zero; continuing with --force"
fi

extra_conf_file="${tmp_dir}/extra.conf"
build_nix_conf \
  "install" \
  "${INPUT_TRUST_RUNNER_USER:-true}" \
  "${USER:-}" \
  "$os_type" \
  "${INPUT_GITHUB_TOKEN:-}" \
  "${INPUT_GITHUB_SERVER_URL:-https://github.com}" \
  "${INPUT_SUBSTITUTERS:-}" \
  "${INPUT_TRUSTED_PUBLIC_KEYS:-}" \
  "${INPUT_NIX_PATH:-}" \
  "${INPUT_EXTRA_CONF:-}" >"$extra_conf_file"
chmod 600 "$extra_conf_file"

install_args=(install)
if [ "$os_type" = "Linux" ] && [ "$effective_init" = "none" ]; then
  install_args+=(linux --init none)
elif [ "$os_type" = "Linux" ] && [ "$init_input" != "auto" ]; then
  install_args+=(linux --init "$effective_init")
elif [ "$os_type" = "Darwin" ] && [ "$init_input" != "auto" ] && [ "$init_input" != "launchd" ]; then
  die "Unsupported init '${init_input}' on Darwin (expected auto or launchd)"
fi

install_args+=(
  --no-confirm
  --nix-package-url "$package_arg"
)

if [ -s "$extra_conf_file" ]; then
  install_args+=(--extra-conf "$extra_conf_file")
fi

if [ "${INPUT_MODIFY_PROFILE:-true}" = "false" ]; then
  install_args+=(--no-modify-profile)
fi

if [ "${INPUT_REINSTALL:-false}" = "true" ]; then
  install_args+=(--force)
fi

if [ -n "${INPUT_EXTRA_ARGS:-}" ]; then
  set -f
  IFS=$' \t\n' read -r -a extra_cli_args <<<"$INPUT_EXTRA_ARGS"
  set +f
  install_args+=("${extra_cli_args[@]}")
fi

info "Installing Lix ${version} (init=${effective_init})"
"$installer_bin" "${install_args[@]}"
propagate_nix_env

nix_bin="$(command -v nix || true)"
if [ -z "$nix_bin" ] && [ -x /nix/var/nix/profiles/default/bin/nix ]; then
  nix_bin="/nix/var/nix/profiles/default/bin/nix"
fi
[ -n "$nix_bin" ] || die "Lix installation completed but 'nix' binary was not found"

installed_version="$("$nix_bin" --version 2>/dev/null | awk '{print $NF}' || printf '%s' "$version")"
elapsed_s="$(( $(date +%s) - start_ts ))"

write_gh_output "version" "$installed_version"
write_gh_output "nix-path" "$nix_bin"
write_gh_output "cache-hit" "$effective_cache_hit"

write_step_summary "$distribution" "$installed_version" "$system" "$effective_cache_hit" "false" "$effective_init" "$elapsed_s"
