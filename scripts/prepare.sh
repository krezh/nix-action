#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "${ACTION_DIR}/scripts/lib.sh"

start_ts="$(date +%s)"
distribution="${INPUT_DISTRIBUTION:-lix}"

case "$distribution" in
  lix) ;;
  *) die "Unsupported distribution '${distribution}'. Currently supported: lix" ;;
esac

# shellcheck source=distributions/lix.env
. "${ACTION_DIR}/distributions/lix.env"

system="$(detect_system)"
os_type="$(uname -s)"

find_existing_nix() {
  if command -v nix >/dev/null 2>&1; then
    command -v nix
    return 0
  fi
  if [ -x /nix/var/nix/profiles/default/bin/nix ]; then
    printf '/nix/var/nix/profiles/default/bin/nix'
    return 0
  fi
  return 1
}

if [ "${INPUT_REINSTALL:-false}" != "true" ] && existing_nix="$(find_existing_nix)"; then
  setup_kvm_permissions
  propagate_nix_env

  env_conf="$(build_nix_conf \
    "env" \
    "${INPUT_TRUST_RUNNER_USER:-true}" \
    "${USER:-}" \
    "$os_type" \
    "${INPUT_GITHUB_TOKEN:-}" \
    "${INPUT_GITHUB_SERVER_URL:-https://github.com}" \
    "${INPUT_SUBSTITUTERS:-}" \
    "${INPUT_TRUSTED_PUBLIC_KEYS:-}" \
    "${INPUT_NIX_PATH:-}" \
    "${INPUT_EXTRA_CONF:-}")"

  if [ -n "$env_conf" ]; then
    if [ -n "${NIX_CONFIG:-}" ]; then
      write_gh_env "NIX_CONFIG" "${NIX_CONFIG}"$'\n'"${env_conf}"
    else
      write_gh_env "NIX_CONFIG" "$env_conf"
    fi
  fi

  installed_version="$("$existing_nix" --version 2>/dev/null | awk 'NR == 1 {print $NF}' || printf 'unknown')"
  elapsed_s="$(( $(date +%s) - start_ts ))"

  info "Nix is already installed at ${existing_nix} (${installed_version}); skipping installer."

  write_gh_output "skip" "true"
  write_gh_output "skipped" "true"
  write_gh_output "cache-hit" "skipped"
  write_gh_output "distribution" "$distribution"
  write_gh_output "version" "$installed_version"
  write_gh_output "nix-path" "$existing_nix"

  write_step_summary "$distribution" "$installed_version" "$system" "skipped" "true" "existing" "$elapsed_s"
  exit 0
fi

target_version="${INPUT_VERSION:-$LIX_VERSION}"
installer_version="${INPUT_INSTALLER_VERSION:-$LIX_INSTALLER_VERSION}"

if [ "$system" = "x86_64-darwin" ] && [ -z "${INPUT_PACKAGE_URL:-}" ]; then
  case "$target_version" in
    2.90.* | 2.91.* | 2.92.* | 2.93.* | 2.94.* | 2.95.*) ;;
    *)
      die "Lix ${target_version} dropped x86_64-darwin binaries. Use aarch64-darwin (macOS arm64 runners) or set an older version (<= 2.95.x) / package-url."
      ;;
  esac
fi

tarball_sha256=""
if [ -z "${INPUT_PACKAGE_URL:-}" ] && [ "$target_version" = "$LIX_VERSION" ]; then
  tarball_sha256="$(manifest_tarball_sha256 "$system")"
fi

installer_sha256=""
if [ -z "${INPUT_INSTALLER_URL:-}" ] && [ "$installer_version" = "$LIX_INSTALLER_VERSION" ]; then
  installer_sha256="$(manifest_installer_sha256 "$system")"
fi

if [ -n "${INPUT_INSTALLER_URL:-}" ]; then
  inst_url_hash="$(sha256_string "$INPUT_INSTALLER_URL")"
  inst_key_part="inst-url-${inst_url_hash:0:12}"
elif [ -n "$installer_sha256" ]; then
  inst_key_part="inst-${installer_version}-${installer_sha256:0:12}"
else
  inst_key_part="inst-${installer_version}"
fi
if [ -n "${INPUT_PACKAGE_URL:-}" ]; then
  pkg_url_hash="$(sha256_string "$INPUT_PACKAGE_URL")"
  pkg_key_part="pkg-url-${pkg_url_hash:0:12}"
elif [ -n "$tarball_sha256" ]; then
  pkg_key_part="pkg-${target_version}-${tarball_sha256:0:12}"
else
  pkg_key_part="pkg-${target_version}"
fi

cache_dir="${RUNNER_TEMP:-/tmp}/nix-action-cache"
restore_key="nix-action-${distribution}-${system}-${inst_key_part}-"
cache_key="${restore_key}${pkg_key_part}"

write_gh_output "skip" "false"
write_gh_output "system" "$system"
write_gh_output "distribution" "$distribution"
write_gh_output "version" "$target_version"
write_gh_output "installer-version" "$installer_version"
write_gh_output "tarball-sha256" "$tarball_sha256"
write_gh_output "installer-sha256" "$installer_sha256"
write_gh_output "cache-dir" "$cache_dir"
write_gh_output "cache-key" "$cache_key"
write_gh_output "restore-key" "$restore_key"
write_gh_output "start-ts" "$start_ts"
