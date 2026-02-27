#!/usr/bin/env bash
set -euo pipefail

# gdm_network_lockdown.sh
# Goal:
# - At login screen (gdm only): force Wi-Fi/WWAN OFF, Bluetooth blocked, and lock controls.
# - At lock screen: force Wi-Fi/WWAN OFF + Bluetooth blocked (via logind Lock/Unlock signals).
# - After real user unlock/login: restore normal controls and auto-bring radios back ON.
# - Revert cleanly removes every file this script created.
# Commands are intentionally minimal:
#   lock   -> enable behavior
#   revert -> disable behavior and fully clean up
#   status -> inspect current state

RULE_FILE="/etc/polkit-1/rules.d/00-gdm-network-lockdown.rules"
GUARD_SCRIPT="/usr/local/sbin/prelogin-radio-guard.sh"
GUARD_UNIT="/etc/systemd/system/prelogin-radio-guard.service"
WATCH_SCRIPT="/usr/local/sbin/prelogin-lockwatch.sh"
WATCH_UNIT="/etc/systemd/system/prelogin-lockwatch.service"
LOCK_STATE_FILE="/run/prelogin-radio-lock.session"
UNLOCK_REQUEST_FILE="/tmp/prelogin-radio-unlock.request"
unlock_grace_until=0
GUARD_LOG_FILE="/run/prelogin-guard.log"

log_guard() {
  [[ "${PRELOGIN_RADIO_DEBUG:-0}" == "1" ]] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$GUARD_LOG_FILE" 2>/dev/null || true
}

write_unlocked_override() {
  local cur_seq=0 tmp
  if [[ -r "$LOCK_STATE_FILE" ]]; then
    cur_seq="$(sed -n 's/^seq=//p' "$LOCK_STATE_FILE" 2>/dev/null | head -n1 || true)"
  fi
  [[ "$cur_seq" =~ ^[0-9]+$ ]] || cur_seq=0
  tmp="$(mktemp /run/prelogin-radio-lock.session.XXXXXX)"
  {
    printf 'state=unlocked\n'
    printf 'seq=%s\n' "$((cur_seq + 1))"
    printf 'ts=%s\n' "$(date +%s)"
  } > "$tmp"
  mv -f "$tmp" "$LOCK_STATE_FILE"
  chmod 644 "$LOCK_STATE_FILE" >/dev/null 2>&1 || true
}
GUARD_UNIT_NAME="prelogin-radio-guard.service"
WATCH_UNIT_NAME="prelogin-lockwatch.service"
USER_AUTOSTART_DIR="${HOME}/.config/autostart"
USER_LOGIN_RESTORE_HOOK="${HOME}/.local/bin/prelogin-login-radio-restore.sh"
USER_LOGIN_RESTORE_DESKTOP="${USER_AUTOSTART_DIR}/prelogin-login-radio-restore.desktop"
USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
USER_LOGIN_RESTORE_UNIT="${USER_SYSTEMD_DIR}/prelogin-login-radio-restore.service"
USER_UNLOCK_WATCH_HOOK="${HOME}/.local/bin/prelogin-unlock-radio-watch.sh"
USER_UNLOCK_WATCH_UNIT="${USER_SYSTEMD_DIR}/prelogin-unlock-radio-watch.service"
PAM_UNLOCK_RESTORE_HOOK="/usr/local/sbin/prelogin-pam-unlock-restore.sh"
PAM_HOOK_LINE_SESSION="session optional pam_exec.so quiet /usr/local/sbin/prelogin-pam-unlock-restore.sh"
PAM_HOOK_LINE_AUTH="auth optional pam_exec.so quiet /usr/local/sbin/prelogin-pam-unlock-restore.sh"
PAM_TARGET_CANDIDATES="/etc/pam.d/cosmic-greeter /etc/pam.d/gdm-password /etc/pam.d/gdm-fingerprint /etc/pam.d/gdm-smartcard-sssd-or-password /etc/pam.d/gdm-smartcard-pkcs11-exclusive /etc/pam.d/gdm-smartcard-sssd-exclusive"
POLICY_STATE_DIR="${HOME}/.local/state/prelogin-radio-lockdown"
WIFI_POLICY_BACKUP_FILE="${POLICY_STATE_DIR}/wifi_policy_backup.env"
MANAGE_WIFI_POLICY="${PRELOGIN_MANAGE_WIFI_POLICY:-0}"

pam_backup_path() {
  local pam_file="$1"
  printf '%s.prelogin-lockdown.bak\n' "$pam_file"
}

list_existing_pam_targets() {
  local p
  for p in $PAM_TARGET_CANDIDATES; do
    [[ -f "$p" ]] && printf '%s\n' "$p"
  done
}

active_wifi_profile_name() {
  nmcli -t -f NAME,TYPE connection show --active 2>/dev/null | awk -F: '$2=="802-11-wireless"{print $1; exit}'
}

wifi_profile_exists() {
  local profile="$1"
  nmcli connection show "$profile" >/dev/null 2>&1
}

wifi_profile_autoconnect() {
  local profile="$1"
  nmcli -g connection.autoconnect connection show "$profile" 2>/dev/null || true
}

wifi_profile_permissions() {
  local profile="$1"
  nmcli -g connection.permissions connection show "$profile" 2>/dev/null || true
}

apply_wifi_profile_policy() {
  local profile="$1"
  local permissions="$2"
  local autoconnect="$3"
  nmcli connection modify "$profile" connection.permissions "$permissions" connection.autoconnect "$autoconnect" >/dev/null 2>&1 || \
    sudo nmcli connection modify "$profile" connection.permissions "$permissions" connection.autoconnect "$autoconnect" >/dev/null 2>&1
}

parse_policy_args() {
  POLICY_PROFILE=""
  POLICY_USER="$USER"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        POLICY_PROFILE="${2:-}"
        shift 2
        ;;
      --user)
        POLICY_USER="${2:-}"
        shift 2
        ;;
      *)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    esac
  done
}

parse_revert_args() {
  REVERT_MODE="strict"
  REVERT_GREETER_AUTOCONNECT=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict)
        REVERT_MODE="strict"
        shift
        ;;
      --smart)
        REVERT_MODE="smart"
        shift
        ;;
      --greeter-autoconnect)
        REVERT_GREETER_AUTOCONNECT=1
        shift
        ;;
      *)
        echo "Unknown option for revert: $1" >&2
        usage
        exit 1
        ;;
    esac
  done

  if [[ "$REVERT_GREETER_AUTOCONNECT" == "1" && "$REVERT_MODE" != "smart" ]]; then
    echo "--greeter-autoconnect requires --smart." >&2
    usage
    exit 1
  fi
}

resolve_policy_profile() {
  local profile="$1"
  if [[ -z "$profile" ]]; then
    profile="$(active_wifi_profile_name || true)"
  fi
  printf '%s\n' "$profile"
}

backup_wifi_policy_once() {
  local profile ac perm
  mkdir -p "$POLICY_STATE_DIR"
  [[ -f "$WIFI_POLICY_BACKUP_FILE" ]] && return 0

  profile="$(active_wifi_profile_name || true)"
  [[ -n "$profile" ]] || return 0

  ac="$(nmcli -g connection.autoconnect connection show "$profile" 2>/dev/null || true)"
  perm="$(nmcli -g connection.permissions connection show "$profile" 2>/dev/null || true)"

  {
    printf 'PROFILE_NAME=%s\n' "$profile"
    printf 'PROFILE_AUTOCONNECT=%s\n' "$ac"
    printf 'PROFILE_PERMISSIONS=%s\n' "$perm"
  } > "$WIFI_POLICY_BACKUP_FILE"
  chmod 600 "$WIFI_POLICY_BACKUP_FILE" 2>/dev/null || true
}

apply_wifi_policy_for_greeter() {
  local profile
  backup_wifi_policy_once

  if [[ -f "$WIFI_POLICY_BACKUP_FILE" ]]; then
    profile="$(sed -n 's/^PROFILE_NAME=//p' "$WIFI_POLICY_BACKUP_FILE" | head -n1)"
  else
    profile="$(active_wifi_profile_name || true)"
  fi
  [[ -n "$profile" ]] || return 0

  apply_wifi_profile_policy "$profile" "" "yes" || true
}

restore_wifi_policy_backup() {
  local profile ac perm
  [[ -f "$WIFI_POLICY_BACKUP_FILE" ]] || return 0

  profile="$(sed -n 's/^PROFILE_NAME=//p' "$WIFI_POLICY_BACKUP_FILE" | head -n1)"
  ac="$(sed -n 's/^PROFILE_AUTOCONNECT=//p' "$WIFI_POLICY_BACKUP_FILE" | head -n1)"
  perm="$(sed -n 's/^PROFILE_PERMISSIONS=//p' "$WIFI_POLICY_BACKUP_FILE" | head -n1)"

  if [[ -n "$profile" ]] && nmcli connection show "$profile" >/dev/null 2>&1; then
    apply_wifi_profile_policy "$profile" "$perm" "$ac" || true
  fi

  rm -f "$WIFI_POLICY_BACKUP_FILE"
}

set_wifi_profile_autoconnect() {
  local profile="$1"
  local autoconnect="$2"
  nmcli connection modify "$profile" connection.autoconnect "$autoconnect" >/dev/null 2>&1 || \
    sudo nmcli connection modify "$profile" connection.autoconnect "$autoconnect" >/dev/null 2>&1
}

last_used_wifi_profile_name() {
  nmcli -t -f NAME,TYPE,TIMESTAMP connection show 2>/dev/null | awk -F: '
    $2=="802-11-wireless" {
      ts=$3
      gsub(/[^0-9]/, "", ts)
      if (ts == "") ts=0
      if (ts >= best_ts) {
        best_ts=ts
        best=$1
      }
    }
    END {
      if (best != "")
        print best
    }
  '
}

candidate_wifi_profiles_for_smart_revert() {
  local profile
  if [[ -f "$WIFI_POLICY_BACKUP_FILE" ]]; then
    profile="$(sed -n 's/^PROFILE_NAME=//p' "$WIFI_POLICY_BACKUP_FILE" | head -n1)"
    if [[ -n "$profile" ]] && wifi_profile_exists "$profile"; then
      printf '%s\n' "$profile"
    fi
  fi

  profile="$(active_wifi_profile_name || true)"
  if [[ -n "$profile" ]] && wifi_profile_exists "$profile"; then
    printf '%s\n' "$profile"
  fi

  profile="$(last_used_wifi_profile_name || true)"
  if [[ -n "$profile" ]] && wifi_profile_exists "$profile"; then
    printf '%s\n' "$profile"
  fi
}

apply_smart_revert_policy() {
  local profile current_perm updated=0

  echo "Revert mode: smart"
  if [[ "$REVERT_GREETER_AUTOCONNECT" == "1" ]]; then
    echo "Policy target: greeter-capable autoconnect (permissions=\"\")."
  else
    echo "Policy target: autoconnect=yes with existing permissions unchanged."
  fi
  echo "Policy changes:"

  while IFS= read -r profile; do
    [[ -n "$profile" ]] || continue

    if [[ "$REVERT_GREETER_AUTOCONNECT" == "1" ]]; then
      if apply_wifi_profile_policy "$profile" "" "yes"; then
        echo "  - $profile: autoconnect=yes, permissions=\"\""
        updated=1
      else
        echo "  - $profile: FAILED (could not set autoconnect=yes permissions=\"\")"
      fi
    else
      current_perm="$(wifi_profile_permissions "$profile")"
      [[ -z "$current_perm" ]] && current_perm="(all users)"
      if set_wifi_profile_autoconnect "$profile" "yes"; then
        echo "  - $profile: autoconnect=yes, permissions unchanged ($current_perm)"
        updated=1
      else
        echo "  - $profile: FAILED (could not set autoconnect=yes)"
      fi
    fi
  done < <(candidate_wifi_profiles_for_smart_revert | awk '!seen[$0]++')

  if [[ "$updated" -eq 0 ]]; then
    echo "  - none: no candidate Wi-Fi profiles found to update"
  fi
}

policy_status_rule() {
  local profile ac perm
  parse_policy_args "$@"
  profile="$(resolve_policy_profile "$POLICY_PROFILE")"
  if [[ -z "$profile" ]]; then
    echo "No active Wi-Fi profile found. Pass one with --profile \"<name>\"."
    return 1
  fi
  if ! wifi_profile_exists "$profile"; then
    echo "Wi-Fi profile not found: $profile"
    return 1
  fi

  ac="$(wifi_profile_autoconnect "$profile")"
  perm="$(wifi_profile_permissions "$profile")"
  [[ -z "$perm" ]] && perm="(all users)"

  echo "Wi-Fi profile policy"
  echo "  profile     : $profile"
  echo "  autoconnect : $ac"
  echo "  permissions : $perm"
}

policy_greeter_rule() {
  local profile
  parse_policy_args "$@"
  profile="$(resolve_policy_profile "$POLICY_PROFILE")"
  if [[ -z "$profile" ]]; then
    echo "No active Wi-Fi profile found. Pass one with --profile \"<name>\"."
    return 1
  fi
  if ! wifi_profile_exists "$profile"; then
    echo "Wi-Fi profile not found: $profile"
    return 1
  fi

  apply_wifi_profile_policy "$profile" "" "yes"
  echo "Applied greeter-friendly policy to profile: $profile"
  policy_status_rule --profile "$profile"
}

policy_user_only_rule() {
  local profile user
  parse_policy_args "$@"
  profile="$(resolve_policy_profile "$POLICY_PROFILE")"
  user="${POLICY_USER:-$USER}"
  if [[ -z "$profile" ]]; then
    echo "No active Wi-Fi profile found. Pass one with --profile \"<name>\"."
    return 1
  fi
  if ! wifi_profile_exists "$profile"; then
    echo "Wi-Fi profile not found: $profile"
    return 1
  fi
  if [[ -z "$user" ]]; then
    echo "Invalid user. Pass one with --user <name>."
    return 1
  fi

  apply_wifi_profile_policy "$profile" "user:${user}" "yes"
  echo "Applied user-only policy to profile: $profile (user: $user)"
  policy_status_rule --profile "$profile"
}

write_polkit_rule() {
  sudo mkdir -p /etc/polkit-1/rules.d
  sudo tee "$RULE_FILE" >/dev/null <<'POLKIT_EOF'
polkit.addRule(function(action, subject) {
    var isGreeterUser =
        subject.user == "gdm" ||
        subject.user == "Debian-gdm" ||
        subject.user == "gdm3" ||
        subject.uid == 111;

    if (!isGreeterUser)
        return polkit.Result.NOT_HANDLED;

    var blocked = [
        "org.freedesktop.NetworkManager.enable-disable-network",
        "org.freedesktop.NetworkManager.enable-disable-wifi",
        "org.freedesktop.NetworkManager.enable-disable-wwan",
        "org.freedesktop.NetworkManager.enable-disable-wimax",
        "org.freedesktop.NetworkManager.sleep-wake",
        "org.freedesktop.NetworkManager.network-control",
        "org.freedesktop.NetworkManager.wifi.scan",
        "org.freedesktop.NetworkManager.settings.modify.system",
        "org.freedesktop.NetworkManager.settings.modify.own",
        "org.freedesktop.NetworkManager.wifi.share.protected",
        "org.freedesktop.NetworkManager.wifi.share.open"
    ];

    if (blocked.indexOf(action.id) >= 0)
        return polkit.Result.NO;

    if (action.id.indexOf("org.freedesktop.NetworkManager.") === 0)
        return polkit.Result.NO;

    return polkit.Result.NOT_HANDLED;
});
POLKIT_EOF
  sudo chmod 644 "$RULE_FILE"
}

write_guard_script() {
  sudo mkdir -p /usr/local/sbin
  sudo tee "$GUARD_SCRIPT" >/dev/null <<'GUARD_EOF'
#!/usr/bin/env bash
set -euo pipefail

LOCK_STATE_FILE="/run/prelogin-radio-lock.session"
UNLOCK_REQUEST_FILE="/tmp/prelogin-radio-unlock.request"
GUARD_LOG_FILE="/run/prelogin-guard.log"
unlock_grace_until=0

log_guard() {
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$GUARD_LOG_FILE" 2>/dev/null || true
}

write_unlocked_override() {
  local cur_seq=0 tmp
  if [[ -r "$LOCK_STATE_FILE" ]]; then
    cur_seq="$(sed -n 's/^seq=//p' "$LOCK_STATE_FILE" 2>/dev/null | head -n1 || true)"
  fi
  [[ "$cur_seq" =~ ^[0-9]+$ ]] || cur_seq=0
  tmp="$(mktemp /run/prelogin-radio-lock.session.XXXXXX)"
  {
    printf 'state=unlocked\n'
    printf 'seq=%s\n' "$((cur_seq + 1))"
    printf 'ts=%s\n' "$(date +%s)"
  } > "$tmp"
  mv -f "$tmp" "$LOCK_STATE_FILE"
  chmod 644 "$LOCK_STATE_FILE" >/dev/null 2>&1 || true
}

have_real_graphical_user() {
  local sid user active
  while read -r sid _; do
    user="$(loginctl show-session "$sid" -p Name --value 2>/dev/null || true)"
    active="$(loginctl show-session "$sid" -p Active --value 2>/dev/null || true)"

    # Important: require Active=yes, not merely State=online.
    # Type can be inconsistent across desktop stacks; do not over-filter on it.
    if [[ -n "$user" && "$user" != "gdm" && "$user" != "Debian-gdm" && "$user" != "gdm3" && "$active" == "yes" ]]; then
      return 0
    fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null)

  return 1
}

read_lock_state() {
  lock_state="unlocked"
  lock_seq=0

  [[ -r "$LOCK_STATE_FILE" ]] || return 0

  while IFS='=' read -r k v; do
    case "$k" in
      state) lock_state="$v" ;;
      seq) lock_seq="$v" ;;
      *) ;;
    esac
  done < "$LOCK_STATE_FILE"

  [[ "$lock_seq" =~ ^[0-9]+$ ]] || lock_seq=0
}

force_restricted() {
  log_guard "action=force_restricted"
  /usr/bin/nmcli radio wifi off >/dev/null 2>&1 || true
  /usr/bin/nmcli radio wwan off >/dev/null 2>&1 || true
  /usr/sbin/rfkill block bluetooth >/dev/null 2>&1 || true
}

force_user_ready_once() {
  log_guard "action=force_user_ready_once"
  # Clear global networking/airplane-mode state first, then restore radios.
  /usr/bin/nmcli networking on >/dev/null 2>&1 || true
  /usr/sbin/rfkill unblock wlan >/dev/null 2>&1 || true
  /usr/sbin/rfkill unblock bluetooth >/dev/null 2>&1 || true
  /usr/bin/nmcli radio wifi on >/dev/null 2>&1 || true
  /usr/bin/nmcli radio wwan on >/dev/null 2>&1 || true
}

state="unknown"
last_seen_seq=-1

while true; do
  read_lock_state
  log_guard "tick state=$state lock_state=$lock_state seq=$lock_seq last=$last_seen_seq"

  if ! have_real_graphical_user; then
    # GREETER: enforce OFF continuously. Consume current seq so stale lock
    # events do not trigger on next login transition.
    force_restricted
    state="GREETER"
    last_seen_seq="$lock_seq"
  else
    # Root-safe unlock handoff: PAM hook writes this request file when unlock
    # auth succeeds but cannot safely perform privileged restore operations.
    if [[ -f "$UNLOCK_REQUEST_FILE" ]]; then
      log_guard "event=unlock_request_consumed"
      write_unlocked_override
      force_user_ready_once
      state="USER_READY"
      read_lock_state
      last_seen_seq="$lock_seq"
      unlock_grace_until="$(( $(date +%s) + 8 ))"
      rm -f "$UNLOCK_REQUEST_FILE" >/dev/null 2>&1 || true
      sleep 1
      continue
    fi

    # USER session exists.
    if [[ "$state" == "unknown" || "$state" == "GREETER" ]]; then
      # GREETER -> USER_READY
      log_guard "transition=GREETER_to_USER_READY"
      force_user_ready_once
      state="USER_READY"
      last_seen_seq="$lock_seq"
    elif [[ "$lock_seq" -ne "$last_seen_seq" ]]; then
      # Event-driven transition from lockwatch.
      if [[ "$lock_state" == "locked" ]]; then
        # Some desktops emit a stale lock edge around unlock auth.
        if (( $(date +%s) < unlock_grace_until )); then
          log_guard "event=stale_locked_edge_ignored seq=$lock_seq"
          last_seen_seq="$lock_seq"
          sleep 1
          continue
        fi
        # USER_READY -> LOCKED
        log_guard "transition=USER_READY_to_LOCKED seq=$lock_seq"
        force_restricted
        state="LOCKED"
      else
        # LOCKED -> USER_READY
        log_guard "transition=LOCKED_to_USER_READY seq=$lock_seq"
        force_user_ready_once
        state="USER_READY"
      fi
      last_seen_seq="$lock_seq"
    elif [[ "$state" == "USER_READY" && "$lock_state" == "locked" ]]; then
      # Some paths flip state to locked without a seq bump; enforce OFF anyway.
      log_guard "transition=USER_READY_to_LOCKED_state_fallback seq=$lock_seq"
      force_restricted
      state="LOCKED"
      last_seen_seq="$lock_seq"
    elif [[ "$state" == "LOCKED" && "$lock_state" != "locked" ]]; then
      # Fallback when unlock signal sequence was missed but current lock state
      # is already unlocked: restore once and continue in USER_READY.
      log_guard "transition=LOCKED_to_USER_READY_fallback seq=$lock_seq"
      force_user_ready_once
      state="USER_READY"
      last_seen_seq="$lock_seq"
    fi
  fi

  sleep 1
done
GUARD_EOF
  sudo chmod 755 "$GUARD_SCRIPT"
}

write_watch_script() {
  sudo mkdir -p /usr/local/sbin
  sudo tee "$WATCH_SCRIPT" >/dev/null <<'WATCH_EOF'
#!/usr/bin/env bash
set -euo pipefail

LOCK_STATE_FILE="/run/prelogin-radio-lock.session"
seq=0

decode_session_token() {
  local token="$1"
  local escaped=""
  local sid=""
  escaped="$(printf '%s' "$token" | sed 's/../\\\\x&/g')"
  sid="$(printf '%b' "$escaped" 2>/dev/null || true)"
  printf '%s\n' "$sid"
}

write_state() {
  local new_state="$1"
  local tmp
  seq=$((seq + 1))
  tmp="$(mktemp /run/prelogin-radio-lock.session.XXXXXX)"
  {
    printf 'state=%s\n' "$new_state"
    printf 'seq=%s\n' "$seq"
    printf 'ts=%s\n' "$(date +%s)"
  } > "$tmp"
  mv -f "$tmp" "$LOCK_STATE_FILE"
  chmod 644 "$LOCK_STATE_FILE" >/dev/null 2>&1 || true
}

# Initialize explicit unlocked state so guard can parse deterministic fields.
{
  printf 'state=unlocked\n'
  printf 'seq=0\n'
  printf 'ts=%s\n' "$(date +%s)"
} > "$LOCK_STATE_FILE"
chmod 644 "$LOCK_STATE_FILE" >/dev/null 2>&1 || true

# Track lock/unlock directly from logind Session signals.
while true; do
  dbus-monitor --system \
    "type='signal',interface='org.freedesktop.login1.Session',member='Lock'" \
    "type='signal',interface='org.freedesktop.login1.Session',member='Unlock'" 2>/dev/null |
  while IFS= read -r line; do
    case "$line" in
      *"member=Lock"*)
        token="$(printf '%s\n' "$line" | sed -n 's#.*path=/org/freedesktop/login1/session/_\([0-9A-Fa-f]\+\);.*#\1#p')"
        decode_session_token "$token" >/dev/null 2>&1 || true
        write_state "locked"
        ;;
      *"member=Unlock"*)
        token="$(printf '%s\n' "$line" | sed -n 's#.*path=/org/freedesktop/login1/session/_\([0-9A-Fa-f]\+\);.*#\1#p')"
        decode_session_token "$token" >/dev/null 2>&1 || true
        write_state "unlocked"
        ;;
      *)
        ;;
    esac
  done

  # If dbus-monitor exits, retry immediately.
  sleep 1
done
WATCH_EOF
  sudo chmod 755 "$WATCH_SCRIPT"
}

write_guard_unit() {
  sudo mkdir -p /etc/systemd/system
  sudo tee "$GUARD_UNIT" >/dev/null <<'UNIT_EOF'
[Unit]
Description=Enforce prelogin/lockscreen radio policy
After=NetworkManager.service bluetooth.service display-manager.service prelogin-lockwatch.service
Wants=NetworkManager.service bluetooth.service prelogin-lockwatch.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/prelogin-radio-guard.sh
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT_EOF
  sudo chmod 644 "$GUARD_UNIT"
}

write_watch_unit() {
  sudo mkdir -p /etc/systemd/system
  sudo tee "$WATCH_UNIT" >/dev/null <<'UNIT_EOF'
[Unit]
Description=Watch logind lock/unlock signals and track lock state
After=dbus.service systemd-logind.service
Wants=systemd-logind.service

[Service]
Type=simple
ExecStart=/usr/local/sbin/prelogin-lockwatch.sh
Restart=always
RestartSec=1

[Install]
WantedBy=multi-user.target
UNIT_EOF
  sudo chmod 644 "$WATCH_UNIT"
}

write_user_login_restore_hook() {
  mkdir -p "${HOME}/.local/bin" "$USER_SYSTEMD_DIR" "$USER_AUTOSTART_DIR"

  cat > "$USER_LOGIN_RESTORE_HOOK" <<'HOOK_EOF'
#!/usr/bin/env bash
set -euo pipefail

# One-shot user-session restore to cover cases where lock/unlock signal timing
# does not trigger guard-side restore quickly enough.
/usr/bin/nmcli networking on >/dev/null 2>&1 || true
/usr/sbin/rfkill unblock wlan >/dev/null 2>&1 || true
/usr/bin/nmcli radio wifi on >/dev/null 2>&1 || true
/usr/bin/nmcli radio wwan on >/dev/null 2>&1 || true
HOOK_EOF
  chmod 755 "$USER_LOGIN_RESTORE_HOOK"

  cat > "$USER_LOGIN_RESTORE_DESKTOP" <<DESKTOP_EOF
[Desktop Entry]
Type=Application
Name=Prelogin Radio Restore
Comment=Restore network radios once after user login
Exec=${USER_LOGIN_RESTORE_HOOK}
Terminal=false
X-GNOME-Autostart-enabled=true
DESKTOP_EOF
  chmod 644 "$USER_LOGIN_RESTORE_DESKTOP"
}

write_user_login_restore_unit() {
  mkdir -p "$USER_SYSTEMD_DIR"
  cat > "$USER_LOGIN_RESTORE_UNIT" <<UNIT_EOF
[Unit]
Description=Prelogin radio restore on user login
After=graphical-session.target

[Service]
Type=oneshot
ExecStart=${USER_LOGIN_RESTORE_HOOK}

[Install]
WantedBy=default.target
UNIT_EOF
  chmod 644 "$USER_LOGIN_RESTORE_UNIT"
}

write_user_unlock_watch_hook() {
  mkdir -p "${HOME}/.local/bin"
  cat > "$USER_UNLOCK_WATCH_HOOK" <<'WATCH_HOOK_EOF'
#!/usr/bin/env bash
set -euo pipefail

restore_radios() {
  /usr/bin/nmcli networking on >/dev/null 2>&1 || true
  /usr/sbin/rfkill unblock wlan >/dev/null 2>&1 || true
  /usr/sbin/rfkill unblock bluetooth >/dev/null 2>&1 || true
  /usr/bin/nmcli radio wifi on >/dev/null 2>&1 || true
  /usr/bin/nmcli radio wwan on >/dev/null 2>&1 || true
}

# User-session lock/unlock watcher.
# This complements system logind lockwatch when unlock signals are missed.
while true; do
  dbus-monitor --session \
    "type='signal',interface='org.freedesktop.ScreenSaver',member='ActiveChanged'" \
    "type='signal',interface='org.gnome.ScreenSaver',member='ActiveChanged'" 2>/dev/null |
  while IFS= read -r line; do
    case "$line" in
      *"boolean false"*)
        # Unlocked in user session.
        restore_radios
        ;;
      *)
        ;;
    esac
  done
  sleep 1
done
WATCH_HOOK_EOF
  chmod 755 "$USER_UNLOCK_WATCH_HOOK"
}

write_user_unlock_watch_unit() {
  mkdir -p "$USER_SYSTEMD_DIR"
  cat > "$USER_UNLOCK_WATCH_UNIT" <<UNIT_EOF
[Unit]
Description=Watch user-session unlock and restore radios
After=graphical-session.target
PartOf=graphical-session.target

[Service]
Type=simple
ExecStart=${USER_UNLOCK_WATCH_HOOK}
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
UNIT_EOF
  chmod 644 "$USER_UNLOCK_WATCH_UNIT"
}

write_pam_unlock_restore_hook() {
  sudo mkdir -p /usr/local/sbin
  sudo tee "$PAM_UNLOCK_RESTORE_HOOK" >/dev/null <<'PAM_HOOK_EOF'
#!/usr/bin/env bash
set -euo pipefail

LOCK_STATE_FILE="/run/prelogin-radio-lock.session"
LOG_FILE="/tmp/prelogin-pam-radio-restore.log"
UNLOCK_REQUEST_FILE="/tmp/prelogin-radio-unlock.request"

log() {
  [[ "${PRELOGIN_RADIO_DEBUG:-0}" == "1" ]] || return 0
  printf '%s %s\n' "$(date '+%F %T')" "$*" >> "$LOG_FILE" 2>/dev/null || true
}

# Only act on post-auth phases.
# COSMIC lock-unlock appears as PAM_TYPE=auth in cosmic-greeter on this host.
have_real_graphical_user() {
  local sid user active
  while read -r sid _; do
    user="$(loginctl show-session "$sid" -p Name --value 2>/dev/null || true)"
    active="$(loginctl show-session "$sid" -p Active --value 2>/dev/null || true)"
    if [[ -n "$user" && "$user" != "gdm" && "$user" != "Debian-gdm" && "$user" != "gdm3" && "$active" == "yes" ]]; then
      return 0
    fi
  done < <(loginctl list-sessions --no-legend 2>/dev/null)
  return 1
}

case "${PAM_TYPE:-}" in
  open_session|setcred)
    ;;
  auth)
    if have_real_graphical_user; then
      log "auth-accept: PAM_SERVICE=${PAM_SERVICE:-unset} PAM_USER=${PAM_USER:-unset}"
    else
      log "auth-skip-no-active-user: PAM_SERVICE=${PAM_SERVICE:-unset} PAM_USER=${PAM_USER:-unset}"
      exit 0
    fi
    ;;
  *)
    log "skip: PAM_TYPE=${PAM_TYPE:-unset} PAM_SERVICE=${PAM_SERVICE:-unset} PAM_USER=${PAM_USER:-unset}"
    exit 0
    ;;
esac

# Ignore greeter/system identities.
case "${PAM_USER:-}" in
  ""|gdm|Debian-gdm|gdm3|root)
    log "skip-user: PAM_USER=${PAM_USER:-unset} PAM_SERVICE=${PAM_SERVICE:-unset}"
    exit 0
    ;;
esac

read_state() {
  lock_state="unknown"
  lock_seq=0
  [[ -r "$LOCK_STATE_FILE" ]] || return 0
  while IFS='=' read -r k v; do
    case "$k" in
      state) lock_state="$v" ;;
      seq) lock_seq="$v" ;;
      *) ;;
    esac
  done < "$LOCK_STATE_FILE"
  [[ "$lock_seq" =~ ^[0-9]+$ ]] || lock_seq=0
}

write_unlocked_state() {
  local tmp next
  next=$((lock_seq + 1))
  tmp="$(mktemp /run/prelogin-radio-lock.session.XXXXXX)"
  {
    printf 'state=unlocked\n'
    printf 'seq=%s\n' "$next"
    printf 'ts=%s\n' "$(date +%s)"
  } > "$tmp"
  mv -f "$tmp" "$LOCK_STATE_FILE"
  chmod 644 "$LOCK_STATE_FILE" >/dev/null 2>&1 || true
}

restore_radios() {
  /usr/bin/nmcli networking on >/dev/null 2>&1 || true
  /usr/sbin/rfkill unblock wlan >/dev/null 2>&1 || true
  /usr/sbin/rfkill unblock bluetooth >/dev/null 2>&1 || true
  /usr/bin/nmcli radio wifi on >/dev/null 2>&1 || true
  /usr/bin/nmcli radio wwan on >/dev/null 2>&1 || true
}

request_root_restore() {
  # PAM in cosmic-greeter may run without permissions required to update
  # /run lock state or rfkill/NM radios. Handoff to root guard via request file.
  printf 'request_ts=%s\npam_service=%s\npam_user=%s\npam_type=%s\n' \
    "$(date +%s)" "${PAM_SERVICE:-unset}" "${PAM_USER:-unset}" "${PAM_TYPE:-unset}" \
    > "$UNLOCK_REQUEST_FILE" 2>/dev/null || true
}

read_state
# Only intervene when lock policy had forced radios off.
if [[ "$lock_state" == "locked" ]]; then
  log "restore-trigger: user=${PAM_USER:-unset} service=${PAM_SERVICE:-unset} state=$lock_state seq=$lock_seq"
  request_root_restore
  # Best effort direct restore (may fail under greeter perms).
  if write_unlocked_state && restore_radios; then
    log "restore-done-direct: user=${PAM_USER:-unset} service=${PAM_SERVICE:-unset}"
  else
    log "restore-deferred-to-guard: user=${PAM_USER:-unset} service=${PAM_SERVICE:-unset}"
  fi
else
  log "no-restore: user=${PAM_USER:-unset} service=${PAM_SERVICE:-unset} state=$lock_state seq=$lock_seq"
fi
PAM_HOOK_EOF
  sudo chmod 755 "$PAM_UNLOCK_RESTORE_HOOK"
}

install_pam_hook() {
  local pam_file backup
  while IFS= read -r pam_file; do
    backup="$(pam_backup_path "$pam_file")"
    if ! sudo test -f "$backup"; then
      sudo cp -a "$pam_file" "$backup"
    fi
    if ! sudo grep -Fq "$PAM_HOOK_LINE_SESSION" "$pam_file"; then
      sudo sh -c "printf '\n%s\n' '$PAM_HOOK_LINE_SESSION' >> '$pam_file'"
    fi
    if ! sudo grep -Fq "$PAM_HOOK_LINE_AUTH" "$pam_file"; then
      sudo sh -c "printf '\n%s\n' '$PAM_HOOK_LINE_AUTH' >> '$pam_file'"
    fi
  done < <(list_existing_pam_targets)
}

remove_pam_hook() {
  local pam_file backup
  for pam_file in $PAM_TARGET_CANDIDATES; do
    backup="$(pam_backup_path "$pam_file")"
    if sudo test -f "$backup"; then
      sudo cp -a "$backup" "$pam_file"
      sudo rm -f "$backup"
    elif sudo test -f "$pam_file"; then
      sudo sed -i "\#${PAM_HOOK_LINE_SESSION//\//\\/}#d" "$pam_file"
      sudo sed -i "\#${PAM_HOOK_LINE_AUTH//\//\\/}#d" "$pam_file"
    fi
  done
  sudo rm -f "$PAM_UNLOCK_RESTORE_HOOK"
}

lock_rule() {
  if [[ "$MANAGE_WIFI_POLICY" == "1" ]]; then
    apply_wifi_policy_for_greeter
  fi
  write_polkit_rule
  write_guard_script
  write_watch_script
  write_guard_unit
  write_watch_unit
  write_user_login_restore_hook
  write_user_login_restore_unit
  write_user_unlock_watch_hook
  write_user_unlock_watch_unit
  write_pam_unlock_restore_hook
  install_pam_hook

  sudo systemctl daemon-reload
  sudo systemctl enable --now "$WATCH_UNIT_NAME"
  sudo systemctl enable --now "$GUARD_UNIT_NAME"
  sudo systemctl restart "$WATCH_UNIT_NAME" "$GUARD_UNIT_NAME"
  sudo systemctl restart polkit
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  systemctl --user enable --now prelogin-login-radio-restore.service >/dev/null 2>&1 || true
  systemctl --user enable --now prelogin-unlock-radio-watch.service >/dev/null 2>&1 || true

  echo "Locked: login screen controls blocked; lock/logout force radios OFF."
  echo "Unlock/login re-enables radios once per unlock/login event; user can toggle normally afterward."
}

unlock_rule() {
  parse_revert_args "$@"
  sudo systemctl disable --now "$GUARD_UNIT_NAME" "$WATCH_UNIT_NAME" 2>/dev/null || true

  sudo rm -f "$RULE_FILE" "$GUARD_SCRIPT" "$GUARD_UNIT" "$WATCH_SCRIPT" "$WATCH_UNIT" "$LOCK_STATE_FILE"
  remove_pam_hook
  systemctl --user disable --now prelogin-login-radio-restore.service >/dev/null 2>&1 || true
  systemctl --user disable --now prelogin-unlock-radio-watch.service >/dev/null 2>&1 || true
  systemctl --user daemon-reload >/dev/null 2>&1 || true
  rm -f "$USER_LOGIN_RESTORE_HOOK" "$USER_LOGIN_RESTORE_UNIT" "$USER_LOGIN_RESTORE_DESKTOP" "$USER_UNLOCK_WATCH_HOOK" "$USER_UNLOCK_WATCH_UNIT"

  sudo systemctl daemon-reload
  sudo systemctl restart polkit

  # Return to normal usable state immediately after unlock.
  nmcli radio wifi on >/dev/null 2>&1 || true
  nmcli radio wwan on >/dev/null 2>&1 || true
  rfkill unblock bluetooth >/dev/null 2>&1 || true

  echo "Unlocked: removed all lockdown files/services and restored normal radio behavior."
  if [[ "$REVERT_MODE" == "smart" ]]; then
    apply_smart_revert_policy
  else
    echo "Revert mode: strict (Wi-Fi profile policy unchanged)."
  fi
  rm -f "$WIFI_POLICY_BACKUP_FILE"
}

status_rule() {
  local present=0
  local total=5
  local rule_note=""

  file_present() {
    local path="$1"
    if [[ -f "$path" ]]; then
      return 0
    fi
    if sudo test -f "$path" 2>/dev/null; then
      return 0
    fi
    return 1
  }

  echo "Scope: greeter + lock screen + unlock transition"

  file_present "$RULE_FILE" && present=$((present + 1))
  file_present "$GUARD_SCRIPT" && present=$((present + 1))
  file_present "$GUARD_UNIT" && present=$((present + 1))
  file_present "$WATCH_SCRIPT" && present=$((present + 1))
  file_present "$WATCH_UNIT" && present=$((present + 1))

  if [[ "$present" -eq "$total" ]]; then
    echo "Status: LOCKED (all required files present)"
  elif [[ "$present" -eq 0 ]]; then
    echo "Status: UNLOCKED (no lockdown files present)"
  else
    echo "Status: PARTIAL (incomplete install: $present/$total files)"
  fi

  echo
  echo "Files:"
  if [[ -f "$RULE_FILE" ]]; then
    echo "  - $RULE_FILE"
  elif sudo test -f "$RULE_FILE" 2>/dev/null; then
    echo "  - $RULE_FILE (present; root-only directory)"
    rule_note="yes"
  else
    echo "  - MISSING: $RULE_FILE"
  fi
  file_present "$GUARD_SCRIPT" && echo "  - $GUARD_SCRIPT" || echo "  - MISSING: $GUARD_SCRIPT"
  file_present "$GUARD_UNIT" && echo "  - $GUARD_UNIT" || echo "  - MISSING: $GUARD_UNIT"
  file_present "$WATCH_SCRIPT" && echo "  - $WATCH_SCRIPT" || echo "  - MISSING: $WATCH_SCRIPT"
  file_present "$WATCH_UNIT" && echo "  - $WATCH_UNIT" || echo "  - MISSING: $WATCH_UNIT"
  [[ -f "$USER_LOGIN_RESTORE_HOOK" ]] && echo "  - $USER_LOGIN_RESTORE_HOOK" || echo "  - MISSING (user hook): $USER_LOGIN_RESTORE_HOOK"
  [[ -f "$USER_LOGIN_RESTORE_UNIT" ]] && echo "  - $USER_LOGIN_RESTORE_UNIT" || echo "  - MISSING (user hook): $USER_LOGIN_RESTORE_UNIT"
  [[ -f "$USER_LOGIN_RESTORE_DESKTOP" ]] && echo "  - $USER_LOGIN_RESTORE_DESKTOP (legacy fallback)" || true
  [[ -f "$USER_UNLOCK_WATCH_HOOK" ]] && echo "  - $USER_UNLOCK_WATCH_HOOK" || echo "  - MISSING (user unlock hook): $USER_UNLOCK_WATCH_HOOK"
  [[ -f "$USER_UNLOCK_WATCH_UNIT" ]] && echo "  - $USER_UNLOCK_WATCH_UNIT" || echo "  - MISSING (user unlock hook): $USER_UNLOCK_WATCH_UNIT"
  file_present "$PAM_UNLOCK_RESTORE_HOOK" && echo "  - $PAM_UNLOCK_RESTORE_HOOK" || echo "  - MISSING (pam hook): $PAM_UNLOCK_RESTORE_HOOK"
  if [[ "$MANAGE_WIFI_POLICY" == "1" ]]; then
    [[ -f "$WIFI_POLICY_BACKUP_FILE" ]] && echo "  - $WIFI_POLICY_BACKUP_FILE (wifi policy backup)" || echo "  - MISSING (wifi policy backup): $WIFI_POLICY_BACKUP_FILE"
  else
    echo "  - Wi-Fi policy management: disabled (set PRELOGIN_MANAGE_WIFI_POLICY=1 to enable backup/restore)"
  fi
  while IFS= read -r pam_file; do
    backup="$(pam_backup_path "$pam_file")"
    file_present "$backup" && echo "  - $backup (backup for full revert)" || true
  done < <(list_existing_pam_targets)

  echo
  echo "Services:"
  printf '  %-34s enabled=%s active=%s\n' "$WATCH_UNIT_NAME" "$(systemctl is-enabled "$WATCH_UNIT_NAME" 2>/dev/null || echo no)" "$(systemctl is-active "$WATCH_UNIT_NAME" 2>/dev/null || echo no)"
  printf '  %-34s enabled=%s active=%s\n' "$GUARD_UNIT_NAME" "$(systemctl is-enabled "$GUARD_UNIT_NAME" 2>/dev/null || echo no)" "$(systemctl is-active "$GUARD_UNIT_NAME" 2>/dev/null || echo no)"
  printf '  %-34s enabled=%s active=%s\n' "prelogin-login-radio-restore.service (user)" "$(systemctl --user is-enabled prelogin-login-radio-restore.service 2>/dev/null || echo no)" "$(systemctl --user is-active prelogin-login-radio-restore.service 2>/dev/null || echo no)"
  printf '  %-34s enabled=%s active=%s\n' "prelogin-unlock-radio-watch.service (user)" "$(systemctl --user is-enabled prelogin-unlock-radio-watch.service 2>/dev/null || echo no)" "$(systemctl --user is-active prelogin-unlock-radio-watch.service 2>/dev/null || echo no)"

  echo
  echo "Current radios:"
  nmcli radio 2>/dev/null || true
  rfkill list 2>/dev/null | sed -n '1,40p' || true

  echo
  if [[ -s "$LOCK_STATE_FILE" ]]; then
    echo "Watcher state file:"
    sed -n '1,5p' "$LOCK_STATE_FILE" 2>/dev/null | sed 's/^/  /'
  else
    echo "Watcher state file: absent"
  fi

  if [[ "$rule_note" == "yes" ]]; then
    echo
    echo "Note: $RULE_FILE exists under a root-only directory; this is normal on some systems."
  fi

  if [[ "$present" -ne 0 && "$present" -ne "$total" ]]; then
    echo
    echo "Hint: run './gdm_network_lockdown.sh revert' then './gdm_network_lockdown.sh lock' to repair."
  fi
}

usage() {
  cat <<'USAGE_EOF'
Usage:
  ./gdm_network_lockdown.sh lock
  ./gdm_network_lockdown.sh revert [--strict|--smart [--greeter-autoconnect]]
  ./gdm_network_lockdown.sh status
  ./gdm_network_lockdown.sh policy-status [--profile "<wifi profile>"]
  ./gdm_network_lockdown.sh policy-greeter [--profile "<wifi profile>"]
  ./gdm_network_lockdown.sh policy-user-only [--profile "<wifi profile>"] [--user <username>]

Notes:
  lock   : enforce greeter + lock-screen radio lockdown and block gdm toggles.
  revert : strict (default) or smart policy recovery mode, then remove lockdown files/services.
  policy-status    : show Wi-Fi profile autoconnect/permissions.
  policy-greeter   : set selected profile to autoconnect=yes and permissions="" (all users/greeter-capable).
  policy-user-only : set selected profile to autoconnect=yes and permissions="user:<username>".

Flags:
  --strict            : revert without changing Wi-Fi profile policy (default).
  --smart             : revert and set autoconnect=yes on candidate Wi-Fi profile(s).
  --greeter-autoconnect : with --smart, also set permissions="" for greeter-capable autoconnect.
  --profile "<name>" : target Wi-Fi profile by name (supports spaces).
  --user <name>      : username for policy-user-only (defaults to current user).

Env Flags:
  PRELOGIN_RADIO_DEBUG=1        enable debug logs for guard/PAM helpers.
  PRELOGIN_MANAGE_WIFI_POLICY=1 enable backup snapshot of active Wi-Fi profile policy during lock.
USAGE_EOF
}

cmd="${1:-}"
shift || true
case "$cmd" in
  lock) lock_rule "$@" ;;
  revert) unlock_rule "$@" ;;
  status) status_rule "$@" ;;
  policy-status) policy_status_rule "$@" ;;
  policy-greeter) policy_greeter_rule "$@" ;;
  policy-user-only) policy_user_only_rule "$@" ;;
  *) usage; exit 1 ;;
esac
