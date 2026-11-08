#!/usr/bin/env bash
set -euo pipefail

die() {
  printf '::error::%s\n' "$*" >&2
  exit 1
}

warn() {
  printf '::warning::%s\n' "$*" >&2
}

info() {
  printf '%s\n' "$*"
}

detect_system() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  if [ "$os" = "Darwin" ]; then
    if [ "$arch" = "i386" ]; then
      if (sysctl hw.optional.x86_64 2>/dev/null || true) | grep -q ': 1'; then
        arch="x86_64"
      fi
    elif [ "$arch" = "x86_64" ]; then
      if (sysctl hw.optional.arm64 2>/dev/null || true) | grep -q ': 1'; then
        arch="arm64"
      fi
    fi
  fi

  case "$os:$arch" in
    Linux:x86_64 | Linux:amd64)
      printf 'x86_64-linux'
      ;;
    Linux:aarch64 | Linux:arm64)
      printf 'aarch64-linux'
      ;;
    Darwin:arm64 | Darwin:aarch64)
      printf 'aarch64-darwin'
      ;;
    Darwin:x86_64)
      printf 'x86_64-darwin'
      ;;
    *)
      die "Unsupported platform: ${os}/${arch}"
      ;;
  esac
}
manifest_tarball_sha256() {
  case "$1" in
    x86_64-linux) printf '%s' "${LIX_TARBALL_SHA256_X86_64_LINUX:-}" ;;
    aarch64-linux) printf '%s' "${LIX_TARBALL_SHA256_AARCH64_LINUX:-}" ;;
    aarch64-darwin) printf '%s' "${LIX_TARBALL_SHA256_AARCH64_DARWIN:-}" ;;
    x86_64-darwin) printf '%s' "${LIX_TARBALL_SHA256_X86_64_DARWIN:-}" ;;
    *) printf '' ;;
  esac
}

manifest_installer_sha256() {
  case "$1" in
    x86_64-linux) printf '%s' "${LIX_INSTALLER_SHA256_X86_64_LINUX:-}" ;;
    aarch64-linux) printf '%s' "${LIX_INSTALLER_SHA256_AARCH64_LINUX:-}" ;;
    aarch64-darwin) printf '%s' "${LIX_INSTALLER_SHA256_AARCH64_DARWIN:-}" ;;
    x86_64-darwin) printf '%s' "${LIX_INSTALLER_SHA256_X86_64_DARWIN:-}" ;;
    *) printf '' ;;
  esac
}


sha256_file() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    die "Neither sha256sum nor shasum is available"
  fi
}

sha256_string() {
  local value="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
  else
    die "Neither sha256sum nor shasum is available"
  fi
}

verify_sha256() {
  local file="$1"
  local expected="$2"
  local actual
  [ -f "$file" ] || return 1
  [ -n "$expected" ] || return 0
  actual="$(sha256_file "$file")"
  [ "$actual" = "$expected" ]
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command -v sudo >/dev/null 2>&1; then
    sudo "$@"
  else
    die "Root privileges required to run '$1', and sudo is not installed"
  fi
}

download_file() {
  local url="$1"
  local dest="$2"
  local -a curl_args

  command -v curl >/dev/null 2>&1 || die "curl is required to download ${url}"

  curl_args=(
    --proto '=https'
    --tlsv1.2
    --fail
    --silent
    --show-error
    --location
    --retry 5
    --retry-delay 2
    --connect-timeout 15
    --output "$dest"
  )

  if curl --help all 2>/dev/null | grep -q -- '--retry-all-errors'; then
    curl_args+=(--retry-all-errors)
  fi

  curl "${curl_args[@]}" "$url"
}

extract_host() {
  local url="$1"
  local rest
  rest="${url#*://}"
  rest="${rest%%/*}"
  printf '%s' "$rest"
}

normalize_ws() {
  printf '%s' "$1" | tr ',\r\n\t' '    ' | awk '{
    out = ""
    for (i = 1; i <= NF; i++) {
      out = (out == "" ? $i : out " " $i)
    }
    printf "%s", out
  }'
}

write_gh_kv() {
  local target="$1"
  local key="$2"
  local value="$3"
  [ -n "$target" ] || return 0
  case "$value" in
    *$'\n'*)
      local delim="EOF_NIX_ACTION_${RANDOM}_$$"
      {
        printf '%s<<%s\n' "$key" "$delim"
        printf '%s\n' "$value"
        printf '%s\n' "$delim"
      } >>"$target"
      ;;
    *)
      printf '%s=%s\n' "$key" "$value" >>"$target"
      ;;
  esac
}

write_gh_output() {
  write_gh_kv "${GITHUB_OUTPUT:-}" "$1" "$2"
}

write_gh_env() {
  write_gh_kv "${GITHUB_ENV:-}" "$1" "$2"
}

add_gh_path() {
  local dir="$1"
  if [ -d "$dir" ]; then
    case ":${PATH}:" in
      *":${dir}:"*) ;;
      *) PATH="${dir}:${PATH}" ;;
    esac
    if [ -n "${GITHUB_PATH:-}" ]; then
      printf '%s\n' "$dir" >>"$GITHUB_PATH"
    fi
  fi
}

build_nix_conf() {
  local mode="$1"
  local trust_runner_user="$2"
  local runner_user="$3"
  local os_type="$4"
  local github_token="$5"
  local github_server_url="$6"
  local substituters="$7"
  local trusted_public_keys="$8"
  local nix_path="$9"
  local extra_conf="${10}"

  local access_tokens=""
  if [ -n "$github_token" ]; then
    local host
    host="$(extract_host "${github_server_url:-https://github.com}")"
    if [ -n "$host" ]; then
      access_tokens="${host}=${github_token}"
    fi
  fi

  local norm_subs norm_keys
  norm_subs="$(normalize_ws "$substituters")"
  norm_keys="$(normalize_ws "$trusted_public_keys")"

  awk \
    -v mode="$mode" \
    -v trust_user="$trust_runner_user" \
    -v runner_user="$runner_user" \
    -v os_type="$os_type" \
    -v init_tokens="$access_tokens" \
    -v init_subs="$norm_subs" \
    -v init_keys="$norm_keys" \
    -v nix_path="$nix_path" \
    '
    function trim(s) {
      sub(/^[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function append_val(cur, add) {
      add = trim(add)
      if (add == "") return cur
      if (cur == "") return add
      return cur " " add
    }
    BEGIN {
      tokens = init_tokens
      subs = init_subs
      keys = init_keys
      has_trusted_users = 0
      extra_count = 0
    }
    {
      line = $0
      sub(/\r$/, "", line)
      t = trim(line)
      if (t == "" || substr(t, 1, 1) == "#") next
      eq = index(line, "=")
      if (eq > 0) {
        k = trim(substr(line, 1, eq - 1))
        v = trim(substr(line, eq + 1))
        if (k == "extra-access-tokens") {
          tokens = append_val(tokens, v)
          next
        }
        if (k == "extra-substituters") {
          subs = append_val(subs, v)
          next
        }
        if (k == "extra-trusted-public-keys") {
          keys = append_val(keys, v)
          next
        }
        if (k == "trusted-users") {
          has_trusted_users = 1
        }
      }
      extra_lines[++extra_count] = line
    }
    END {
      if (mode == "install" && trust_user == "true" && !has_trusted_users) {
        tu = "root"
        if (os_type == "Darwin") {
          tu = tu " @admin"
        }
        if (runner_user != "" && runner_user != "root") {
          tu = tu " " runner_user
        }
        printf "trusted-users = %s\n", tu
      }
      if (tokens != "") {
        printf "extra-access-tokens = %s\n", tokens
      }
      if (subs != "") {
        printf "extra-substituters = %s\n", subs
      }
      if (keys != "") {
        printf "extra-trusted-public-keys = %s\n", keys
      }
      if (mode == "install" && nix_path != "") {
        printf "nix-path = %s\n", nix_path
      }
      for (i = 1; i <= extra_count; i++) {
        printf "%s\n", extra_lines[i]
      }
    }
  ' <<<"$extra_conf"
}

setup_kvm_permissions() {
  if [ "$(uname -s)" = "Linux" ] && [ "${INPUT_KVM:-true}" = "true" ] && [ -e /dev/kvm ]; then
    if ! { [ -r /dev/kvm ] && [ -w /dev/kvm ]; }; then
      run_root chmod a+rw /dev/kvm || warn "Failed to update /dev/kvm permissions"
    fi
  fi
}

propagate_nix_env() {
  local nix_link
  if [ -n "${NIX_STATE_HOME:-}" ]; then
    nix_link="${NIX_STATE_HOME}/profile"
  else
    nix_link="${HOME}/.nix-profile"
  fi

  add_gh_path "${nix_link}/bin"
  add_gh_path "/nix/var/nix/profiles/default/bin"

  if [ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]; then
    set +u
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
    set -u
  elif [ -f /nix/var/nix/profiles/default/etc/profile.d/nix.sh ]; then
    set +u
    # shellcheck disable=SC1091
    . /nix/var/nix/profiles/default/etc/profile.d/nix.sh
    set -u
  fi

  if [ -n "${NIX_PROFILES:-}" ]; then
    write_gh_env "NIX_PROFILES" "$NIX_PROFILES"
  else
    write_gh_env "NIX_PROFILES" "/nix/var/nix/profiles/default ${nix_link}"
  fi

  if [ -n "${NIX_SSL_CERT_FILE:-}" ]; then
    write_gh_env "NIX_SSL_CERT_FILE" "$NIX_SSL_CERT_FILE"
  elif [ -e /etc/ssl/certs/ca-certificates.crt ]; then
    write_gh_env "NIX_SSL_CERT_FILE" "/etc/ssl/certs/ca-certificates.crt"
  elif [ "$(uname -s)" = "Darwin" ] && [ -e /etc/ssl/cert.pem ]; then
    write_gh_env "NIX_SSL_CERT_FILE" "/etc/ssl/cert.pem"
  elif [ -e /nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt ]; then
    write_gh_env "NIX_SSL_CERT_FILE" "/nix/var/nix/profiles/default/etc/ssl/certs/ca-bundle.crt"
  fi

  if [ -z "${TMPDIR:-}" ] && [ -n "${RUNNER_TEMP:-}" ]; then
    write_gh_env "TMPDIR" "$RUNNER_TEMP"
  fi

  if [ -n "${INPUT_NIX_PATH:-}" ]; then
    write_gh_env "NIX_PATH" "$INPUT_NIX_PATH"
  fi
}

write_step_summary() {
  local distribution="$1"
  local version="$2"
  local system="$3"
  local cache_hit="$4"
  local skipped="$5"
  local init_mode="$6"
  local elapsed_s="$7"

  [ "${INPUT_SUMMARY:-true}" = "true" ] || return 0
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0

  {
    printf '### nix-action\n\n'
    printf '| Setting | Value |\n'
    printf '| --- | --- |\n'
    # shellcheck disable=SC2016
    printf '| Distribution | `%s` |\n' "$distribution"
    # shellcheck disable=SC2016
    printf '| Version | `%s` |\n' "$version"
    # shellcheck disable=SC2016
    printf '| System | `%s` |\n' "$system"
    # shellcheck disable=SC2016
    printf '| Init | `%s` |\n' "$init_mode"
    # shellcheck disable=SC2016
    printf '| Cache | `%s` |\n' "$cache_hit"
    # shellcheck disable=SC2016
    printf '| Skipped reinstall | `%s` |\n' "$skipped"
    # shellcheck disable=SC2016
    printf '| Duration | `%ss` |\n\n' "$elapsed_s"
  } >>"$GITHUB_STEP_SUMMARY"
}
