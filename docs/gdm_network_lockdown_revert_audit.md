# GDM Network Lockdown (Greeter + Lock-Screen) Audit and Guide

## Purpose
This guide documents `gdm_network_lockdown.sh` and the final behavior:
- Logged out (gdm greeter): Wi-Fi/WWAN forced OFF, Bluetooth blocked, toggles denied.
- Lock screen: Wi-Fi/WWAN forced OFF, Bluetooth blocked.
- Logged in + unlocked: radios are restored ON once per unlock/login event, then user keeps full manual control.
- `revert` removes all files/services created by `lock`.

Script path:
- `/home/acamacho/gdm_network_lockdown.sh`

## Why This Design Changed
`loginctl show-session ... LockedHint` stayed `no` on this COSMIC setup, so lock-screen state was not reliably detectable via polling.

New approach uses logind DBus signals instead:
- `org.freedesktop.login1.Session.Lock`
- `org.freedesktop.login1.Session.Unlock`

A watcher service writes a small state machine file at `/run/prelogin-radio-lock.session` with:
- `state=locked|unlocked`
- `seq=<monotonic event counter>`

The guard reacts to `seq` changes (edge-triggered) and is the only component that applies radio changes.
Guard now uses a strict transition state machine:
- `GREETER`: enforce OFF continuously
- `USER_READY`: user session active, radios ON
- `LOCKED`: lock event active, radios OFF

Transitions:
- `GREETER -> USER_READY`: run one ON restore
- `USER_READY -> LOCKED`: run one OFF action
- `LOCKED -> USER_READY`: run one ON restore
- `* -> GREETER`: enforce OFF continuously

Guard also includes an unlock-missed fallback: if internal state is `LOCKED` but
current watcher state reads `unlocked`, it performs one restore and returns to
`USER_READY`.

On greeter loops, guard consumes the current lock sequence so stale pre-login lock state does not force OFF/ON transitions on next login.
User-session detection is based on non-gdm `Active=yes` for desktop compatibility.
Lockwatch parses the session object path from each logind signal and only accepts events from non-gdm sessions that are not `State=closing`.

## Debug Timeline (What Failed and Why)
1. Initial lock-screen detection used `LockedHint`; on this COSMIC setup it remained `no`, so lock state was unreliable.
2. Moved to logind `Lock`/`Unlock` DBus signals; detection improved, but restore timing still failed in some cycles.
3. Added broad retry/timer restore loops; this improved recovery but caused aggressive re-scanning and UI/glitch side effects.
4. Simplified back to single-transition restore; this removed scan spam but could miss some unlock paths.
5. Final stable direction:
- guard is the only component that applies radio ON/OFF
- watcher only writes lock state (`state`, `seq`, `ts`)
- user-session entry triggers one mirrored ON action
- no timer-based auto-unlock fallback while lock state remains `locked`

Root cause of repeated failures:
- COSMIC/logind lock signaling and session timing are inconsistent enough that relying on one signal path alone was brittle.
- During login transitions, an old user session can remain `State=closing`; stale lock signals from that session can incorrectly force radios back OFF.
- Forcing reconnect too often caused unwanted Wi-Fi scans and display side effects.

Final resolution:
- deterministic OFF at greeter/logout
- deterministic ON once on user-session entry
- deterministic OFF/ON on lock/unlock transitions
- no timer-based restore loops in guard
- one-shot user-login restore via user systemd service (with legacy desktop autostart fallback) to improve post-login reliability if desktop signaling is inconsistent
- dedicated user unlock watcher (`prelogin-unlock-radio-watch.service`) listens on session DBus (`org.freedesktop.ScreenSaver` / `org.gnome.ScreenSaver`) and restores radios only on unlock, improving `lockout -> lockin` reliability without enabling radios at pre-login
- lockwatch now records every logind `Lock`/`Unlock` edge (no closing-session drop filter), preventing missed unlock restores on systems that keep stale `closing` sessions
- added PAM fallback for COSMIC stacks that emit `Lock` but not `Unlock`: a `pam_exec` hook on `/etc/pam.d/cosmic-greeter` restores radios on successful unlock/login session-open when lock state is `locked`

## Commands
```bash
./gdm_network_lockdown.sh lock
./gdm_network_lockdown.sh status
./gdm_network_lockdown.sh revert
```
`lock` now restarts both services so updated script logic applies immediately.

## Installed Components (`lock`)
1. Polkit rule:
- `/etc/polkit-1/rules.d/00-gdm-network-lockdown.rules`
2. Guard script:
- `/usr/local/sbin/prelogin-radio-guard.sh`
3. Guard service:
- `/etc/systemd/system/prelogin-radio-guard.service`
4. Lock watcher script:
- `/usr/local/sbin/prelogin-lockwatch.sh`
5. Lock watcher service:
- `/etc/systemd/system/prelogin-lockwatch.service`
6. Runtime state file (volatile):
- `/run/prelogin-radio-lock.session`
7. User login restore hook:
- `~/.local/bin/prelogin-login-radio-restore.sh`
- `~/.config/systemd/user/prelogin-login-radio-restore.service`
- `~/.config/autostart/prelogin-login-radio-restore.desktop` (legacy fallback)
8. User unlock watcher:
- `~/.local/bin/prelogin-unlock-radio-watch.sh`
- `~/.config/systemd/user/prelogin-unlock-radio-watch.service`
9. PAM unlock restore fallback:
- `/usr/local/sbin/prelogin-pam-unlock-restore.sh`
- `/etc/pam.d/cosmic-greeter` (one `pam_exec` line added by lock command)
- `/etc/pam.d/cosmic-greeter.prelogin-lockdown.bak` (backup used for exact revert)

## Behavior Matrix
| State | Wi-Fi/WWAN | Bluetooth | Toggle ability |
|---|---|---|---|
| Logged out (gdm) | Forced OFF via NetworkManager radio | Blocked | Denied by polkit |
| Screen locked | Forced OFF on lock transition | Blocked on lock transition | User regains manual control after unlock transition |
| Logged in + unlocked | Auto ON once after user-session entry | Unblocked | User can toggle normally |

Note: restore explicitly runs `nmcli networking on` before radio unblocks to clear airplane-mode state on systems that expose it separately.

## Revert Audit (Double-Checked)
`revert` performs:
1. `systemctl disable --now prelogin-radio-guard.service prelogin-lockwatch.service`
2. Remove all files listed above
3. Remove runtime lock file
4. Remove user login hook files
5. `systemctl daemon-reload`
6. `systemctl restart polkit`
7. Return to normal radio state immediately:
- `nmcli radio wifi on`
- `nmcli radio wwan on`
- `rfkill unblock bluetooth`

Verdict:
- PASS: created files/services are explicitly removed.
- PASS: no residual persistent NM/bluetooth config hacks in this version.
- PASS: reboot-safe; `lock` persists (systemd enabled), `revert` persists removal.

## Verification Steps
```bash
# Install policy
./gdm_network_lockdown.sh lock

# Check install health
./gdm_network_lockdown.sh status

# Lock test
# Press Super+L, wait 2-4 seconds, confirm Wi-Fi drops and BT is blocked

# Unlock test
# Unlock session, wait 2-4 seconds, confirm radios come back and manual toggles work

# Logout test
# Log out to greeter and confirm radios OFF / toggles blocked
# Log in and confirm reconnect behavior

# Full cleanup
./gdm_network_lockdown.sh revert
./gdm_network_lockdown.sh status
```

## Final Validation (2026-02-23)
Tested on Pop!_OS COSMIC with repeated manual cycles and reboot persistence checks.

Observed pass results:
1. Reboot persistence:
- After reboot (with policy locked), services came up and policy remained active.
2. Lockout -> lockin:
- On lock: guard logged `transition=USER_READY_to_LOCKED` and executed `force_restricted`.
- On unlock: PAM hook logged `auth-accept` + `restore-trigger`; guard consumed unlock request and executed `force_user_ready_once`.
- Radios returned to enabled without manual intervention.
3. Logout -> login:
- Radios stayed off at greeter/logout state and restored after successful login.
4. Repeated cycles:
- Multiple lock/unlock and logout/login cycles remained stable.

Implementation notes validated by traces:
- COSMIC occasionally flips `lock_state=locked` without seq increment; guard fallback now enforces OFF based on state even without seq edge.
- Unlock restore is robust through PAM + root-guard handoff, avoiding permission/race issues seen in earlier iterations.

## Known Limits
1. Enforcement loop is 1s polling, so transitions are fast but not truly instantaneous.
2. Lock event capture depends on logind DBus signal availability.
3. User unlock watcher depends on session DBus lock/unlock signals; desktop stacks that do not emit ScreenSaver `ActiveChanged` may still rely on login restore path.
4. On systems where logind does not emit `Unlock`, PAM fallback is required for consistent lock-screen unlock restore.
5. If another tool forces radios independently, behavior can conflict.

## Troubleshooting
- `status` shows PARTIAL:
```bash
./gdm_network_lockdown.sh revert
./gdm_network_lockdown.sh lock
```
- If only the polkit file appears missing, verify directly:
```bash
sudo test -f /etc/polkit-1/rules.d/00-gdm-network-lockdown.rules && echo RULE_EXISTS || echo RULE_MISSING
```
On some systems, `/etc/polkit-1/rules.d` is root-only (for example mode `750`), which can cause non-root file checks to misreport.
- Inspect service logs:
```bash
journalctl -u prelogin-lockwatch.service -b --no-pager | tail -n 80
journalctl -u prelogin-radio-guard.service -b --no-pager | tail -n 80
```

## Recommended Publication Bundle
- `gdm_network_lockdown.sh`
- `gdm_network_lockdown_revert_audit.md`
