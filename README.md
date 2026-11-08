# nix-action

Personal GitHub Action for installing Nix (currently Lix) across workflows, with cached installer/tarball artifacts and Renovate-managed pins.

## Workflow example

```yaml
- uses: krezh/nix-action@v1
```

## Behavior

- Caches `lix-installer` and `lix-<version>-<system>.tar.xz` together in `actions/cache` (with `restore-keys` so Lix updates keep the cached installer binary) and passes the local tarball via `--nix-package-url`.
- Skips reinstall when `nix` is already present (`reinstall: false`), applying job-scoped `NIX_CONFIG`, `NIX_PATH`, and `PATH`.
- Auto-detects container jobs without systemd (`--init none`) and enables `/dev/kvm` on Linux when present.
- Writes `extra-conf`, `substituters`, `trusted-public-keys`, `trusted-users`, and `extra-access-tokens` via a `0600` `--extra-conf` file before daemon startup, merging duplicate `extra-*` keys cleanly.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `distribution` | `lix` | Distribution (`lix`). |
| `version` | Pinned in `distributions/lix.env` | Lix version override. |
| `installer-version` | Pinned in `distributions/lix.env` | `lix-installer` version override. |
| `installer-url` | — | Override URL for the installer binary. |
| `package-url` | — | Override URL or local path for the distribution tarball. |
| `github-token` | `${{ github.token }}` | Token added to `extra-access-tokens`. |
| `github-server-url` | `${{ github.server_url }}` | Server URL paired with `github-token`. |
| `extra-conf` | — | Extra configuration lines for `nix.custom.conf`. |
| `substituters` | — | Space- or newline-separated `extra-substituters`. |
| `trusted-public-keys` | — | Space- or newline-separated `extra-trusted-public-keys`. |
| `nix-path` | — | Exported as `NIX_PATH` and set as `nix-path`. |
| `init` | `auto` | Init mode (`auto`, `systemd`, `launchd`, `none`). |
| `kvm` | `"true"` | Enable `/dev/kvm` permissions on Linux when present. |
| `trust-runner-user` | `"true"` | Add runner user to `trusted-users`. |
| `modify-profile` | `"true"` | Update shell profiles during install. |
| `reinstall` | `"false"` | Force reinstall if Nix/Lix is already present. |
| `cache-installer` | `"true"` | Cache installer binary and tarball with `actions/cache`. |
| `extra-args` | — | Extra CLI flags passed to `lix-installer install`. |
| `summary` | `"true"` | Write summary table to `$GITHUB_STEP_SUMMARY`. |

## Outputs

| Output | Description |
| --- | --- |
| `version` | Installed Nix/Lix version. |
| `distribution` | Active distribution (`lix`). |
| `cache-hit` | `true`, `partial`, `false`, or `skipped`. |
| `skipped` | `true` when reusing an existing install. |
| `nix-path` | Path to the installed `nix` binary. |

## Maintenance

- Renovate updates `distributions/lix.env` via `.renovaterc.json5` and `.github/scripts/update-hash.sh`.
- Release Please creates `vX.Y.Z` releases, auto-merges release PRs once `CI` passes, and updates `v1`.
