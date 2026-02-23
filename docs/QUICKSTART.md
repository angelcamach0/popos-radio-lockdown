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

## Expected behavior
- Lock screen or logout/greeter: radios forced OFF.
- Unlock/login: radios restored ON once; user can toggle normally.
- Reboot: policy persists while locked.
- Active Wi-Fi profile policy is backed up and normalized for greeter connectivity while feature is enabled; `revert` restores original profile policy.

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
./scripts/gdm_network_lockdown.sh revert
./scripts/gdm_network_lockdown.sh status
```

After `revert`, reboot and confirm radios behave normally with no forced policy.

## Compatibility / update note
This is robust on tested COSMIC Pop!_OS systems, but not fully independent of desktop updates.
- Changes in lock/unlock signaling, PAM stacks, or NM behavior can affect it.
- If behavior changes after updates, run:
```bash
./scripts/gdm_network_lockdown.sh revert
./scripts/gdm_network_lockdown.sh lock
```
and re-run the smoke test.
