#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib.sh
. "${ROOT_DIR}/scripts/lib.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_eq() {
  local actual="$1"
  local expected="$2"
  local msg="${3:-mismatch}"
  if [ "$actual" != "$expected" ]; then
    printf 'FAIL: %s (expected=%q actual=%q)\n' "$msg" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-missing substring}"
  if ! printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    printf 'FAIL: %s (missing %q in %q)\n' "$msg" "$needle" "$haystack" >&2
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="${3:-unexpected substring}"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    printf 'FAIL: %s (unexpected %q)\n' "$msg" "$needle" >&2
    exit 1
  fi
}

# 1. Manifest lookup sanity
# shellcheck source=distributions/lix.env
. "${ROOT_DIR}/distributions/lix.env"
[ -n "$LIX_VERSION" ]
[ -n "$(manifest_tarball_sha256 x86_64-linux)" ]
[ -n "$(manifest_tarball_sha256 aarch64-linux)" ]
[ -n "$(manifest_tarball_sha256 aarch64-darwin)" ]
[ -n "$(manifest_installer_sha256 x86_64-linux)" ]
[ -n "$(manifest_installer_sha256 aarch64-linux)" ]
[ -n "$(manifest_installer_sha256 aarch64-darwin)" ]

# 2. build_nix_conf merging & key preservation
conf_out="$(build_nix_conf \
  "install" \
  "true" \
  "runner" \
  "Linux" \
  "ghp_secret_123" \
  "https://github.com" \
  $'https://cache.example.org\nhttps://cache2.example.org' \
  "key1:abc key2:def" \
  "nixpkgs=channel:nixos-unstable" \
  $'# comment\nextra-access-tokens = example.com=tok2\nextra-substituters = https://third.example.org\nmax-jobs = 4')"

assert_contains "$conf_out" "trusted-users = root runner" "trusted-users generated"
assert_contains "$conf_out" "extra-access-tokens = github.com=ghp_secret_123 example.com=tok2" "access tokens merged"
assert_contains "$conf_out" "extra-substituters = https://cache.example.org https://cache2.example.org https://third.example.org" "substituters merged"
assert_contains "$conf_out" "extra-trusted-public-keys = key1:abc key2:def" "public keys emitted"
assert_contains "$conf_out" "nix-path = nixpkgs=channel:nixos-unstable" "nix-path emitted"
assert_contains "$conf_out" "max-jobs = 4" "extra line preserved"

env_conf_out="$(build_nix_conf \
  "env" \
  "true" \
  "runner" \
  "Darwin" \
  "ghp_secret_123" \
  "https://ghe.internal.example/api/v3" \
  "https://cache.example.org" \
  "" \
  "" \
  "max-jobs = 2")"

assert_not_contains "$env_conf_out" "trusted-users" "env mode omits trusted-users"
assert_contains "$env_conf_out" "extra-access-tokens = ghe.internal.example=ghp_secret_123" "GHES host extracted"
assert_contains "$env_conf_out" "max-jobs = 2" "env mode keeps max-jobs"

# 3. prepare.sh skip-if-installed path (with mock nix binary)
skip_case="${TMP_ROOT}/skip"
mkdir -p "${skip_case}/bin"
cat >"${skip_case}/bin/nix" <<'EOF'
#!/usr/bin/env bash
echo "nix (Lix, like Nix) 2.96.0"
EOF
chmod +x "${skip_case}/bin/nix"

: >"${skip_case}/gh_out"
: >"${skip_case}/gh_env"
: >"${skip_case}/gh_path"
: >"${skip_case}/gh_summary"

env -i \
  PATH="${skip_case}/bin:/usr/bin:/bin:/run/current-system/sw/bin" \
  HOME="${skip_case}" \
  USER="runner" \
  RUNNER_TEMP="${skip_case}" \
  GITHUB_OUTPUT="${skip_case}/gh_out" \
  GITHUB_ENV="${skip_case}/gh_env" \
  GITHUB_PATH="${skip_case}/gh_path" \
  GITHUB_STEP_SUMMARY="${skip_case}/gh_summary" \
  INPUT_DISTRIBUTION="lix" \
  INPUT_GITHUB_TOKEN="ghp_should_not_leak_in_summary" \
  INPUT_GITHUB_SERVER_URL="https://github.com" \
  INPUT_SUBSTITUTERS="https://cache2.example.org" \
  INPUT_EXTRA_CONF="max-jobs = 2" \
  INPUT_REINSTALL="false" \
  INPUT_KVM="false" \
  INPUT_SUMMARY="true" \
  bash "${ROOT_DIR}/scripts/prepare.sh" >/dev/null

skip_out="$(<"${skip_case}/gh_out")"
skip_env="$(<"${skip_case}/gh_env")"
skip_sum="$(<"${skip_case}/gh_summary")"

assert_contains "$skip_out" "skip=true" "skip-if-installed sets skip=true"
assert_contains "$skip_out" "skipped=true" "skip-if-installed sets skipped=true"
assert_contains "$skip_out" "cache-hit=skipped" "skip-if-installed sets cache-hit=skipped"
assert_contains "$skip_out" "version=2.96.0" "skip-if-installed parses version"
assert_contains "$skip_env" "max-jobs = 2" "skip-if-installed propagates NIX_CONFIG"
assert_not_contains "$skip_sum" "ghp_should_not_leak_in_summary" "summary must never contain tokens"

# 4. prepare.sh fresh-install path (reinstall=true bypasses mock nix)
fresh_case="${TMP_ROOT}/fresh"
mkdir -p "$fresh_case"
: >"${fresh_case}/gh_out"
env -i \
  PATH="${skip_case}/bin:/usr/bin:/bin:/run/current-system/sw/bin" \
  HOME="${fresh_case}" \
  RUNNER_TEMP="${fresh_case}" \
  GITHUB_OUTPUT="${fresh_case}/gh_out" \
  INPUT_DISTRIBUTION="lix" \
  INPUT_REINSTALL="true" \
  bash "${ROOT_DIR}/scripts/prepare.sh"

fresh_out="$(<"${fresh_case}/gh_out")"
assert_contains "$fresh_out" "skip=false" "reinstall=true forces skip=false"
assert_contains "$fresh_out" "version=${LIX_VERSION}" "fresh resolve picks pinned Lix version"
assert_contains "$fresh_out" "installer-version=${LIX_INSTALLER_VERSION}" "fresh resolve picks pinned installer version"
assert_contains "$fresh_out" "cache-key=nix-action-lix-" "fresh resolve sets cache-key"

# 5. install.sh cache-hit & stale-file pruning & arg construction
inst_case="${TMP_ROOT}/install"
cache_dir="${inst_case}/cache"
mock_bin="${inst_case}/bin"
mkdir -p "$cache_dir" "$mock_bin"

sys="$(detect_system)"
mock_installer="${cache_dir}/lix-installer-2.95.2-${sys}"
mock_tarball="${cache_dir}/lix-2.96.0-${sys}.tar.xz"
stale_installer="${cache_dir}/lix-installer-2.94.0-${sys}"
stale_tarball="${cache_dir}/lix-2.95.2-${sys}.tar.xz"

cat >"$mock_installer" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"${MOCK_ARGS_FILE:?}"
for ((i = 1; i <= $#; i++)); do
  if [ "${!i}" = "--extra-conf" ]; then
    j=$((i + 1))
    cp "${!j}" "${MOCK_CAPTURED_CONF:?}"
  fi
done
EOF
chmod +x "$mock_installer"
printf 'dummy tarball' >"$mock_tarball"
: >"$stale_installer"
: >"$stale_tarball"

inst_sha="$(sha256_file "$mock_installer")"
pkg_sha="$(sha256_file "$mock_tarball")"

# Mock nix binary for post-install check + empty curl stub that fails if network is attempted
cat >"${mock_bin}/nix" <<'EOF'
#!/usr/bin/env bash
echo "nix (Lix, like Nix) 2.96.0"
EOF
cat >"${mock_bin}/curl" <<'EOF'
#!/usr/bin/env bash
echo "ERROR: unexpected curl invocation on cache hit" >&2
exit 99
EOF
chmod +x "${mock_bin}/nix" "${mock_bin}/curl"

: >"${inst_case}/gh_out"
: >"${inst_case}/gh_env"
: >"${inst_case}/gh_path"
: >"${inst_case}/gh_summary"

env -i \
  PATH="${mock_bin}:/usr/bin:/bin:/run/current-system/sw/bin" \
  HOME="${inst_case}" \
  USER="runner" \
  RUNNER_TEMP="${inst_case}" \
  GITHUB_OUTPUT="${inst_case}/gh_out" \
  GITHUB_ENV="${inst_case}/gh_env" \
  GITHUB_PATH="${inst_case}/gh_path" \
  GITHUB_STEP_SUMMARY="${inst_case}/gh_summary" \
  MOCK_ARGS_FILE="${inst_case}/captured_args" \
  MOCK_CAPTURED_CONF="${inst_case}/captured_conf" \
  PREPARED_DISTRIBUTION="lix" \
  PREPARED_SYSTEM="$sys" \
  PREPARED_VERSION="2.96.0" \
  PREPARED_INSTALLER_VERSION="2.95.2" \
  PREPARED_TARBALL_SHA256="$pkg_sha" \
  PREPARED_INSTALLER_SHA256="$inst_sha" \
  PREPARED_CACHE_DIR="$cache_dir" \
  PREPARED_START_TS="$(date +%s)" \
  CACHE_HIT="true" \
  INPUT_GITHUB_TOKEN="ghp_test_token_abc" \
  INPUT_GITHUB_SERVER_URL="https://github.com" \
  INPUT_SUBSTITUTERS="https://cache.lix.systems" \
  INPUT_EXTRA_CONF="extra-access-tokens = example.com=xyz" \
  INPUT_INIT="none" \
  INPUT_KVM="false" \
  INPUT_TRUST_RUNNER_USER="true" \
  INPUT_MODIFY_PROFILE="false" \
  INPUT_REINSTALL="false" \
  INPUT_CACHE_INSTALLER="true" \
  INPUT_EXTRA_ARGS="--logger compact" \
  INPUT_SUMMARY="true" \
  bash "${ROOT_DIR}/scripts/install.sh" >/dev/null

captured_args="$(<"${inst_case}/captured_args")"
captured_conf="$(<"${inst_case}/captured_conf")"
inst_out="$(<"${inst_case}/gh_out")"

if [ "$(uname -s)" = "Linux" ]; then
  assert_contains "$captured_args" $'install\nlinux\n--init\nnone' "linux --init none passed first"
fi
assert_contains "$captured_args" "--no-confirm" "--no-confirm passed"
assert_contains "$captured_args" "--nix-package-url" "--nix-package-url passed"
assert_contains "$captured_args" "$mock_tarball" "cached local tarball path passed"
assert_contains "$captured_args" "--no-modify-profile" "--no-modify-profile passed"
assert_contains "$captured_args" "--logger" "extra-args passed"
assert_not_contains "$captured_args" "ghp_test_token_abc" "token must not appear in CLI args"
assert_contains "$captured_conf" "extra-access-tokens = github.com=ghp_test_token_abc example.com=xyz" "extra.conf merged tokens"
assert_contains "$inst_out" "cache-hit=true" "cache-hit output is true"
assert_contains "$inst_out" "version=2.96.0" "version output is 2.96.0"

[ ! -e "$stale_installer" ] || { echo "FAIL: stale installer not pruned" >&2; exit 1; }
[ ! -e "$stale_tarball" ] || { echo "FAIL: stale tarball not pruned" >&2; exit 1; }
# 6. .github/scripts/update-hash.sh offline smoke test (simulating Renovate postUpgradeTasks bump)
upd_case="${TMP_ROOT}/update"
mkdir -p "${upd_case}/distributions" "${upd_case}/scripts" "${upd_case}/.github/scripts" "${upd_case}/bin"
cp "${ROOT_DIR}/scripts/lib.sh" "${upd_case}/scripts/"
cp "${ROOT_DIR}/.github/scripts/update-hash.sh" "${upd_case}/.github/scripts/"
cp "${ROOT_DIR}/distributions/lix.env" "${upd_case}/distributions/lix.env"
sed 's/LIX_VERSION="[^"]*"/LIX_VERSION="2.97.0"/' "${ROOT_DIR}/distributions/lix.env" >"${upd_case}/distributions/lix.env"

cat >"${upd_case}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "--help" ]; then
  exit 0
fi
out=""
url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o|--output) out="$2"; shift 2 ;;
    -r|--retry|--retry-delay|--connect-timeout|--proto|--tlsv1.2)
      case "$1" in -r|--retry|--retry-delay|--connect-timeout|--proto|--tlsv1.2)
        if [ "$1" = "--proto" ] || [ "$1" = "--tlsv1.2" ]; then
          if [ "$1" = "--proto" ]; then shift 2; else shift; fi
        else
          shift 2
        fi
        ;;
      esac
      ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
case "$url" in
  *lix-2.97.0-x86_64-linux.tar.xz.sha256) printf '1111111111111111111111111111111111111111111111111111111111111111  file\n' >"$out" ;;
  *lix-2.97.0-aarch64-linux.tar.xz.sha256) printf '2222222222222222222222222222222222222222222222222222222222222222  file\n' >"$out" ;;
  *lix-2.97.0-aarch64-darwin.tar.xz.sha256) printf '3333333333333333333333333333333333333333333333333333333333333333  file\n' >"$out" ;;
  *2.97.0/lix-installer-*) exit 22 ;;
  *2.95.2/lix-installer-x86_64-linux) printf 'inst-x64-2952' >"$out" ;;
  *2.95.2/lix-installer-aarch64-linux) printf 'inst-arm64-2952' >"$out" ;;
  *2.95.2/lix-installer-aarch64-darwin) printf 'inst-darwin-2952' >"$out" ;;
  *2.98.0/lix-installer-x86_64-linux) printf 'inst-x64-2980' >"$out" ;;
  *2.98.0/lix-installer-aarch64-linux) printf 'inst-arm64-2980' >"$out" ;;
  *2.98.0/lix-installer-aarch64-darwin) printf 'inst-darwin-2980' >"$out" ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${upd_case}/bin/curl"

env -i \
  PATH="${upd_case}/bin:/usr/bin:/bin:/run/current-system/sw/bin" \
  HOME="${upd_case}" \
  bash "${upd_case}/.github/scripts/update-hash.sh" >/dev/null

updated_manifest="$(<"${upd_case}/distributions/lix.env")"
assert_contains "$updated_manifest" 'LIX_VERSION="2.97.0"' "update-lix keeps bumped version"
assert_contains "$updated_manifest" 'LIX_TARBALL_SHA256_X86_64_LINUX="1111111111111111111111111111111111111111111111111111111111111111"' "update-lix updates x86_64-linux hash"
assert_contains "$updated_manifest" 'LIX_INSTALLER_VERSION="2.95.2"' "update-lix preserves installer version when 2.97.0 installer absent"

# 7. update-lix.sh refreshes installer sha256 when Renovate bumps LIX_INSTALLER_VERSION
sed 's/LIX_INSTALLER_VERSION="[^"]*"/LIX_INSTALLER_VERSION="2.98.0"/' "${upd_case}/distributions/lix.env" >"${upd_case}/distributions/lix.env.tmp"
mv "${upd_case}/distributions/lix.env.tmp" "${upd_case}/distributions/lix.env"

env -i \
  PATH="${upd_case}/bin:/usr/bin:/bin:/run/current-system/sw/bin" \
  HOME="${upd_case}" \
  bash "${upd_case}/.github/scripts/update-hash.sh" >/dev/null

updated_inst_manifest="$(<"${upd_case}/distributions/lix.env")"
expected_inst_sha="$(sha256_string "inst-x64-2980")"
assert_contains "$updated_inst_manifest" 'LIX_INSTALLER_VERSION="2.98.0"' "update-lix keeps bumped installer version"
assert_contains "$updated_inst_manifest" "LIX_INSTALLER_SHA256_X86_64_LINUX=\"${expected_inst_sha}\"" "update-lix refreshes installer sha256"

printf 'All smoke tests passed.\n'
