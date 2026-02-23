# Runtime Architecture

```text
Lock/Unlock Sources
  ├─ logind system DBus: org.freedesktop.login1.Session Lock/Unlock
  ├─ user-session DBus watcher (best effort)
  └─ PAM open_session on successful unlock/login

             (state=locked|unlocked, seq)
                     /run/prelogin-radio-lock.session
                                 |
                                 v
                    prelogin-radio-guard.service
                    /usr/local/sbin/prelogin-radio-guard.sh
                                 |
            +--------------------+--------------------+
            |                                         |
         OFF path                                   ON path
 nmcli radio wifi/wwan off                nmcli networking on
 rfkill block bluetooth                   rfkill unblock wlan/bluetooth
                                          nmcli radio wifi/wwan on
```

## Persistent Components installed by `lock`
- `/etc/systemd/system/prelogin-lockwatch.service`
- `/usr/local/sbin/prelogin-lockwatch.sh`
- `/etc/systemd/system/prelogin-radio-guard.service`
- `/usr/local/sbin/prelogin-radio-guard.sh`
- `/etc/polkit-1/rules.d/00-gdm-network-lockdown.rules`
- `/usr/local/sbin/prelogin-pam-unlock-restore.sh`
- PAM hook line on available files (`cosmic-greeter`, `gdm-password`, etc.) with `.prelogin-lockdown.bak` backups
