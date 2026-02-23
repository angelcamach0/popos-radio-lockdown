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
```

## Safety
- `lock` installs files/services and PAM hook backups.
- `revert` removes installed artifacts and restores PAM files from backups.
