# Draft: COSMIC Feature Proposal Issue

Title:
`Feature request: optional radios-off policy on lock screen and logout`

Body:

## Summary
I would like to propose an optional COSMIC feature:

`Disable radios on lock/logout`

When enabled by the user, COSMIC should:
- turn Wi-Fi/WWAN/Bluetooth off on lock and logout/greeter
- restore radios after successful unlock/login
- persist behavior across reboot

## Motivation
Some users want an explicit privacy/security posture while the device is locked or logged out.
This reduces wireless attack surface while unattended.

## Current prototype status
I built and validated a proof-of-concept in userspace scripts (systemd + nmcli + rfkill + PAM hooks) with repeated lock/unlock, logout/login, and reboot tests.

Prototype repo and docs:
- https://github.com/<YOUR_USERNAME>/<YOUR_REPO>

Important finding:
- On this COSMIC setup, lock/unlock event sources can be inconsistent (e.g., lock edge visible, unlock edge less reliable), so robust behavior benefits from a unified native session event model.

## Proposed upstream behavior
Add an optional setting in COSMIC settings:
- `Disable radios on lock/logout` (default off)

Expected behavior matrix:
1. Feature off: no behavior change.
2. Feature on:
- lock -> radios off
- unlock -> radios restored
- logout/greeter -> radios off
- login -> radios restored
- reboot -> policy still active

## UX notes
- This should be explicit and discoverable in Settings (Network/Privacy/Security section).
- Users should retain manual control while logged in/unlocked.

## Technical notes (implementation preference)
Prefer native COSMIC implementation over external scripts/PAM patching:
- session/lock/logout lifecycle handled in COSMIC components (Rust)
- policy persisted in COSMIC settings daemon
- radio control through standard system interfaces (NM/BlueZ/polkit)

## Validation plan
- lock/unlock x3
- logout/login x3
- reboot validation
- ensure no regressions in normal network toggling

## Questions for maintainers
1. Which repo should own core logic for this feature?
2. Which repo should own settings UI toggle?
3. Are there existing lock/unlock state APIs in COSMIC components that should be used?
