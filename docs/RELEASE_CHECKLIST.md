# Release Checklist

## Release identity
- Project name: `popos-radio-lockdown`
- Suggested release title: `v1.0.0 - Lock/Logout Radio Policy Toggle for COSMIC Pop!_OS`

## Pre-release checks
1. Script syntax
```bash
bash -n scripts/gdm_network_lockdown.sh
```
2. Help output
```bash
./scripts/gdm_network_lockdown.sh
```
3. Repo clean
```bash
git status --short
```

## Functional validation matrix
Run on a real COSMIC Pop!_OS session.

1. Enable feature
```bash
./scripts/gdm_network_lockdown.sh lock
./scripts/gdm_network_lockdown.sh status
```
2. Validate lock/unlock (repeat 3x)
- Lock screen: radios should go OFF.
- Unlock: radios should return ON.

3. Validate logout/login (repeat 3x)
- Logout/greeter: radios OFF.
- Login: radios ON.

4. Reboot persistence
- Reboot with feature enabled.
- Confirm behavior remains correct.

5. Disable feature
```bash
./scripts/gdm_network_lockdown.sh revert
./scripts/gdm_network_lockdown.sh status
```
- Reboot and confirm no forced radio policy remains.

6. Optional policy command checks
```bash
./scripts/gdm_network_lockdown.sh policy-status
./scripts/gdm_network_lockdown.sh policy-greeter --profile "<wifi profile>"
./scripts/gdm_network_lockdown.sh policy-user-only --profile "<wifi profile>" --user "$USER"
```

## Security checks
- `revert` removes all installed units/scripts/rules/hooks.
- No debug logs enabled by default (`PRELOGIN_RADIO_DEBUG` not set).
- Wi-Fi profile backup/restore mode is opt-in only (`PRELOGIN_MANAGE_WIFI_POLICY=1`).
- No secrets, personal profile names, or machine-specific data committed.

## Files to include in release
- `scripts/gdm_network_lockdown.sh`
- `docs/QUICKSTART.md`
- `docs/gdm_network_lockdown_revert_audit.md`
- `docs/architecture.md`
- `docs/online_research.md`
- `README.md`

## GitHub release notes template
```md
## popos-radio-lockdown v1.0.0

### What this does
Adds a lock/logout radio policy toggle for COSMIC Pop!_OS:
- Lock/logout: Wi-Fi/WWAN/Bluetooth forced OFF
- Unlock/login: radios restored ON

### Included
- `scripts/gdm_network_lockdown.sh`
- Quickstart and troubleshooting docs
- Revert-safe uninstall path
- Explicit Wi-Fi profile policy commands (`policy-status`, `policy-greeter`, `policy-user-only`)

### Usage
```bash
./scripts/gdm_network_lockdown.sh lock
./scripts/gdm_network_lockdown.sh status
./scripts/gdm_network_lockdown.sh revert
```

### Notes
- Designed/tested on COSMIC Pop!_OS.
- Not guaranteed independent of future COSMIC/PAM/NM changes.
- If behavior changes after updates:
```bash
./scripts/gdm_network_lockdown.sh revert
./scripts/gdm_network_lockdown.sh lock
```
```

## Tag + push example
```bash
git tag -a v1.0.0 -m "popos-radio-lockdown v1.0.0"
git push origin master
git push origin v1.0.0
```
