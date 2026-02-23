# Online Research (Related Approaches)

## Summary
No widely adopted single turnkey script was found for this exact COSMIC/Pop!_OS behavior. The common building blocks used by others match our approach:
- lock-state observation via `systemd-logind` DBus (`Lock`/`Unlock`)
- radio control via NetworkManager (`nmcli`) and rfkill
- PAM hook (`pam_exec`) for auth/session-open events

## References
1. systemd-logind DBus and session semantics (Lock/Unlock behavior context)
- https://www.freedesktop.org/software/systemd/man/latest/org.freedesktop.login1.html

2. `pam_exec` module for running script during PAM stacks
- https://man7.org/linux/man-pages/man8/pam_exec.8.html

3. Ask Ubuntu discussion using PAM hook patterns with GDM (`gdm-password`) 
- https://askubuntu.com/questions/1500954/using-pam-exec-to-run-script-after-fingerprint-authentication

4. NetworkManager CLI (`nmcli`) docs
- https://networkmanager.pages.freedesktop.org/NetworkManager/NetworkManager/nmcli.html

## Practical inference
For COSMIC specifically, Unlock signal reliability can vary. A robust design combines:
- state machine + logind watcher
- auth/session-open restore (PAM)
- explicit revert with backups
