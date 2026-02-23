# COSMIC Contribution Dev Setup

Last verified: 2026-02-23

This is a practical setup to prototype an upstream COSMIC feature from a Pop!_OS machine.

## Scope
This project is currently a shell/PAM/systemd proof-of-concept. Upstream COSMIC work should move logic into native Rust components.

Likely target repos:
- `pop-os/cosmic-session`
- `pop-os/cosmic-greeter`
- `pop-os/cosmic-settings`
- `pop-os/cosmic-epoch` (meta/build integration)

## 1) Install baseline dependencies
```bash
sudo apt update
sudo apt install -y \
  build-essential \
  dbus \
  git \
  libdbus-1-dev \
  libdisplay-info-dev \
  libflatpak-dev \
  libpam0g-dev \
  libpipewire-0.3-dev \
  libpixman-1-dev \
  libpulse-dev \
  libseat-dev \
  libssl-dev \
  libsystemd-dev \
  libwayland-dev \
  libxkbcommon-dev \
  lld \
  mold \
  rustup \
  udev

rustup toolchain install stable
cargo install just
```

## 2) Build COSMIC sysext test environment
```bash
git clone --recurse-submodules https://github.com/pop-os/cosmic-epoch
cd cosmic-epoch
just sysext
```

Install extension for testing:
```bash
sudo mkdir -p /var/lib/extensions
sudo cp -a cosmic-sysext /var/lib/extensions/
sudo systemctl enable --now systemd-sysext
sudo systemd-sysext refresh
```

Then log out and choose COSMIC in your display manager session selector.

## 3) Fast local contribution loop
1. Pick one component repo for each change.
2. Implement minimal behavior.
3. Build/test that repo.
4. Run acceptance matrix (below).
5. Repeat.

## 4) Acceptance matrix for this feature
Desired toggle concept: `Disable radios on lock/logout`.

Validate all transitions:
1. Reboot while feature enabled.
2. Greeter before login: radios OFF.
3. Login: radios ON.
4. Lock/unlock x3: OFF on lock, ON on unlock.
5. Logout/login x3: OFF on logout/greeter, ON on login.
6. Reboot again: same behavior persists.

Useful checks:
```bash
cat /run/prelogin-radio-lock.session
nmcli radio
rfkill list | sed -n '1,40p'
```

## 5) Upstream-first workflow
1. Open feature proposal issue (include behavior matrix + logs + rationale).
2. Ask maintainers which repo should host implementation.
3. Implement native Rust changes there.
4. Add tests + docs.
5. Submit PR.

## References
- https://github.com/pop-os/cosmic-epoch
- https://github.com/pop-os/cosmic-session
- https://github.com/pop-os/cosmic-greeter
- https://github.com/pop-os/cosmic-settings
- https://chat.pop-os.org
