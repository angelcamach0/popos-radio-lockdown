# Minimal Setup (Script-Only)

## 1) Requirements
- Pop!_OS / Ubuntu-like system
- `systemd`, `NetworkManager` (`nmcli`), `rfkill`, `polkit`
- `sudo` access

## 2) Install and enable
```bash
chmod +x gdm_network_lockdown.sh
./gdm_network_lockdown.sh lock
./gdm_network_lockdown.sh status
```

## 3) Disable and remove
```bash
./gdm_network_lockdown.sh revert --strict
./gdm_network_lockdown.sh revert --smart
./gdm_network_lockdown.sh revert --smart --greeter-autoconnect
./gdm_network_lockdown.sh status
```

## 4) Optional Wi-Fi profile policy helpers
```bash
./gdm_network_lockdown.sh policy-status
./gdm_network_lockdown.sh policy-greeter --profile "<wifi profile>"
./gdm_network_lockdown.sh policy-user-only --profile "<wifi profile>" --user "$USER"
```
