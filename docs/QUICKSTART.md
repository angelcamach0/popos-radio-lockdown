# Quickstart (End Users)

## Prereqs
- Pop!_OS / Ubuntu-like system with:
  - `systemd`
  - `NetworkManager` (`nmcli`)
  - `rfkill`
  - `polkit`
  - PAM files for COSMIC/GDM (`/etc/pam.d/cosmic-greeter` and/or `gdm-*`)

## Install / Enable
```bash
cd popos-radio-lockdown
chmod +x scripts/gdm_network_lockdown.sh
./scripts/gdm_network_lockdown.sh lock
./scripts/gdm_network_lockdown.sh status
```

Optional Wi-Fi policy snapshot mode (captures active profile policy during `lock` to help smart revert candidate selection):
```bash
PRELOGIN_MANAGE_WIFI_POLICY=1 ./scripts/gdm_network_lockdown.sh lock
```

Explicit policy commands:
```bash
./scripts/gdm_network_lockdown.sh policy-status
./scripts/gdm_network_lockdown.sh policy-greeter --profile "CamachoFam-5G"
./scripts/gdm_network_lockdown.sh policy-user-only --profile "CamachoFam-5G" --user "$USER"
```

## Expected behavior
- Lock screen or logout/greeter: radios forced OFF.
- Unlock/login: radios restored ON once; user can toggle normally.
- Reboot: policy persists while locked.
- By default, Wi-Fi profile policy is untouched.
- Optional: use `revert --smart` to set `autoconnect=yes` on candidate Wi-Fi profile(s).
- Optional: add `--greeter-autoconnect` to also set `permissions=""` for greeter auto-connect.

## Smoke test (recommended)
1. Lock/unlock once.
2. Logout/login once.
3. Reboot once.
4. Check:
```bash
cat /run/prelogin-radio-lock.session
nmcli radio
rfkill list | sed -n '1,40p'
```

## Disable / Remove (full revert)
```bash
./scripts/gdm_network_lockdown.sh revert --strict
./scripts/gdm_network_lockdown.sh status
```

Smart revert options:
```bash
./scripts/gdm_network_lockdown.sh revert --smart
./scripts/gdm_network_lockdown.sh revert --smart --greeter-autoconnect
./scripts/gdm_network_lockdown.sh status
```

After `revert`, reboot and confirm radios behave normally with no forced policy.

## Flags reference
- `--strict`: revert without changing Wi-Fi profile policy (default).
- `--smart`: revert and set autoconnect on candidate Wi-Fi profile(s).
- `--greeter-autoconnect`: with `--smart`, also set `permissions=""`.
- `--profile "<name>"`: target profile for `policy-*` commands.
- `--user <name>`: user for `policy-user-only`.
- `PRELOGIN_RADIO_DEBUG=1`: enable debug logs.
- `PRELOGIN_MANAGE_WIFI_POLICY=1`: capture active Wi-Fi profile policy during `lock` for smart revert candidate hints.

## Compatibility / update note
This is robust on tested COSMIC Pop!_OS systems, but not fully independent of desktop updates.
- Changes in lock/unlock signaling, PAM stacks, or NM behavior can affect it.
- If behavior changes after updates, run:
```bash
./scripts/gdm_network_lockdown.sh revert
./scripts/gdm_network_lockdown.sh lock
```
and re-run the smoke test.
