# v1.0.0 (Documented Release)

## Summary
`popos-radio-lockdown` provides a lock/logout radio policy toggle for COSMIC Pop!_OS:
- lock/logout: force Wi-Fi/WWAN/Bluetooth OFF
- unlock/login: restore radios ON

## Included
- `scripts/gdm_network_lockdown.sh`
- `docs/QUICKSTART.md`
- `docs/gdm_network_lockdown_revert_audit.md`
- `docs/architecture.md`
- `docs/online_research.md`

## Core commands
```bash
./scripts/gdm_network_lockdown.sh lock
./scripts/gdm_network_lockdown.sh status
./scripts/gdm_network_lockdown.sh revert
```

## Optional Wi-Fi policy commands
```bash
./scripts/gdm_network_lockdown.sh policy-status [--profile "<wifi profile>"]
./scripts/gdm_network_lockdown.sh policy-greeter [--profile "<wifi profile>"]
./scripts/gdm_network_lockdown.sh policy-user-only [--profile "<wifi profile>"] [--user <username>]
```

## Flags
- `PRELOGIN_RADIO_DEBUG=1`: enable debug logs
- `PRELOGIN_MANAGE_WIFI_POLICY=1`: enable lock/revert backup+restore of active Wi-Fi profile policy

## Compatibility
Validated on COSMIC Pop!_OS. Behavior can be affected by upstream changes in COSMIC lock signaling, PAM stack behavior, or NetworkManager/rfkill behavior.

## Safety
- `lock` installs scripts/units/rules/hooks and enables services.
- `revert` removes installed artifacts and restores PAM files from backups.
