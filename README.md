# Pop!_OS Radio Lockdown (Lockout/Logout)

Purpose: enforce Wi-Fi/WWAN/Bluetooth OFF on lock screen and logout/greeter, then restore ON after successful unlock/login.

## Current Design
- System lock watcher (`prelogin-lockwatch.service`) tracks lock state from logind signals.
- System guard (`prelogin-radio-guard.service`) enforces OFF/ON transitions via `nmcli` + `rfkill`.
- Greeter controls blocked with polkit rule.
- User restore fallbacks:
  - user-session unlock watcher service
  - PAM `pam_exec` restore hook on display-manager PAM stacks

## Why multiple restore paths
On this COSMIC/Pop!_OS setup, `Lock` is visible but `Unlock` is not always emitted through the same signal path. Restore must also be tied to successful auth/session-open.

## Files
- `scripts/gdm_network_lockdown.sh`
- `docs/QUICKSTART.md`
- `docs/gdm_network_lockdown_revert_audit.md`
- `docs/architecture.md`
- `docs/online_research.md`
- `docs/CONTRIBUTING_DEV_SETUP.md`
- `docs/upstream_issue_draft.md`

## Usage
```bash
./scripts/gdm_network_lockdown.sh lock
./scripts/gdm_network_lockdown.sh status
./scripts/gdm_network_lockdown.sh revert
./scripts/gdm_network_lockdown.sh policy-status [--profile "<wifi profile>"]
./scripts/gdm_network_lockdown.sh policy-greeter [--profile "<wifi profile>"]
./scripts/gdm_network_lockdown.sh policy-user-only [--profile "<wifi profile>"] [--user <username>]
```

## Quick Validation
Use `docs/QUICKSTART.md` for setup + smoke test + revert verification.

## Compatibility
This project is stable on tested COSMIC Pop!_OS setups, but not guaranteed to be independent of future COSMIC/PAM/NetworkManager updates.
If an OS update changes behavior, the recommended recovery is:
```bash
./scripts/gdm_network_lockdown.sh revert
./scripts/gdm_network_lockdown.sh lock
```
then rerun the smoke test from `docs/QUICKSTART.md`.

## Safety
- `lock` installs files/services and PAM hook backups.
- `revert` removes installed artifacts and restores PAM files.
- Optional Wi-Fi policy backup/restore is available only when enabled with:
```bash
PRELOGIN_MANAGE_WIFI_POLICY=1 ./scripts/gdm_network_lockdown.sh lock
PRELOGIN_MANAGE_WIFI_POLICY=1 ./scripts/gdm_network_lockdown.sh revert
```

## What `lock` Sets Up
Running `./scripts/gdm_network_lockdown.sh lock` automatically:
- writes system scripts/units
- enables and starts system services
- writes the polkit rule for greeter restrictions
- installs PAM hook and creates PAM file backups for clean revert
- enables user restore/watch services

## Flags And Env
- `--profile "<name>"`: target a specific Wi-Fi profile (supports spaces).
- `--user <name>`: username for `policy-user-only` (defaults to current user).
- `PRELOGIN_RADIO_DEBUG=1`: enable runtime debug logs for PAM/guard helpers.
- `PRELOGIN_MANAGE_WIFI_POLICY=1`: enable lock/revert backup/restore of active Wi-Fi profile policy.

## Release Integrity
Use the `.sha256` files attached to the release:
- `gdm_network_lockdown.sh.sha256`
- `popos-radio-lockdown-minimal-v1.0.0.tar.gz.sha256`

Reference hashes for `v1.0.0`:
- `gdm_network_lockdown.sh`
  `2464aafbfff7c42310d17391150d4ac4746715405b848d498fc4c8793a2f4ee7`
- `popos-radio-lockdown-minimal-v1.0.0.tar.gz`
  `92b571ca91f2827de16c9da103e42d65eb5439b87a2e92c863c343330f533a51`

Verify:
```bash
sha256sum -c gdm_network_lockdown.sh.sha256
sha256sum -c popos-radio-lockdown-minimal-v1.0.0.tar.gz.sha256
```
Expected:
- `...: OK` for each file
- `...: FAILED` means re-download artifact + checksum file
