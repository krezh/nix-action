#!/usr/bin/env bash
set -euo pipefail

ACTION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=scripts/lib.sh
. "${ACTION_DIR}/scripts/lib.sh"

MANIFEST="${ACTION_DIR}/distributions/lix.env"
# shellcheck source=distributions/lix.env
. "$MANIFEST"

latest_flag="false"
target_lix_version=""
target_installer_version=""

while [ $# -gt 0 ]; do
  case "$1" in
    --latest)
      latest_flag="true"
      shift
      ;;
    --lix-version)
      target_lix_version="${2:?missing value for --lix-version}"
      shift 2
      ;;
    --installer-version)
      target_installer_version="${2:?missing value for --installer-version}"
      shift 2
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [ "$latest_flag" = "true" ]; then
  command -v jq >/dev/null 2>&1 || die "jq is required for --latest"
  tags_json="${tmp_dir}/tags.json"
  download_file "https://git.lix.systems/api/v1/repos/lix-project/lix/tags?limit=25" "$tags_json"
  target_lix_version="$(jq -r '[.[].name | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))][0]' "$tags_json")"
  if [ -z "$target_lix_version" ] || [ "$target_lix_version" = "null" ]; then
    die "Failed to resolve latest Lix version"
  fi
fi

lix_version="${target_lix_version:-$LIX_VERSION}"
installer_version="${target_installer_version:-$LIX_INSTALLER_VERSION}"

fetch_tarball_sha256() {
  local ver="$1"
  local sys="$2"
  local out="${tmp_dir}/tarball-${sys}.sha256"
  download_file "https://releases.lix.systems/lix/lix-${ver}/lix-${ver}-${sys}.tar.xz.sha256" "$out"
  awk '{print $1}' "$out"
}

fetch_installer_sha256() {
  local ver="$1"
  local sys="$2"
  local out="${tmp_dir}/installer-${sys}"
  download_file "https://install.lix.systems/lix/${ver}/lix-installer-${sys}" "$out"
  sha256_file "$out"
}

probe_installer_exists() {
  local ver="$1"
  local sys="$2"
  curl --proto '=https' --tlsv1.2 -fsSL --retry 3 --retry-delay 1 -r 0-0 -o /dev/null "https://install.lix.systems/lix/${ver}/lix-installer-${sys}"
}

lix_sha_x86_64_linux="$(fetch_tarball_sha256 "$lix_version" "x86_64-linux")"
lix_sha_aarch64_linux="$(fetch_tarball_sha256 "$lix_version" "aarch64-linux")"
lix_sha_aarch64_darwin="$(fetch_tarball_sha256 "$lix_version" "aarch64-darwin")"

if [ -z "$target_installer_version" ] && [ "$lix_version" != "$installer_version" ]; then
  if probe_installer_exists "$lix_version" "x86_64-linux" &&
     probe_installer_exists "$lix_version" "aarch64-linux" &&
     probe_installer_exists "$lix_version" "aarch64-darwin"; then
    installer_version="$lix_version"
  fi
fi

inst_sha_x86_64_linux="$(fetch_installer_sha256 "$installer_version" "x86_64-linux")"
inst_sha_aarch64_linux="$(fetch_installer_sha256 "$installer_version" "aarch64-linux")"
inst_sha_aarch64_darwin="$(fetch_installer_sha256 "$installer_version" "aarch64-darwin")"
{
  printf 'LIX_VERSION="%s"\n' "$lix_version"
  printf 'LIX_TARBALL_SHA256_X86_64_LINUX="%s"\n' "$lix_sha_x86_64_linux"
  printf 'LIX_TARBALL_SHA256_AARCH64_LINUX="%s"\n' "$lix_sha_aarch64_linux"
  printf 'LIX_TARBALL_SHA256_AARCH64_DARWIN="%s"\n' "$lix_sha_aarch64_darwin"
  printf '\n'
  printf 'LIX_INSTALLER_VERSION="%s"\n' "$installer_version"
  printf 'LIX_INSTALLER_SHA256_X86_64_LINUX="%s"\n' "$inst_sha_x86_64_linux"
  printf 'LIX_INSTALLER_SHA256_AARCH64_LINUX="%s"\n' "$inst_sha_aarch64_linux"
  printf 'LIX_INSTALLER_SHA256_AARCH64_DARWIN="%s"\n' "$inst_sha_aarch64_darwin"
} >"${tmp_dir}/lix.env"

mv -f "${tmp_dir}/lix.env" "$MANIFEST"
info "Updated distributions/lix.env (lix=${lix_version}, lix-installer=${installer_version})"
