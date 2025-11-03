# colima-system

Run Colima as a headless system daemon on macOS via launchd. Provides a stable `/var/run/docker.sock` for Docker clients.

## Requirements
- macOS (root required)
- Homebrew installed and configured
- `colima` (installed via Homebrew)
- `envsubst` (installed via Homebrew, from gettext package)

## Install
```bash
# prerequisites
brew install colima gettext

# install (as root)
sudo /bin/sh /path/to/repo/setup.sh
```

## Add user to `docker` group (macOS)

Add your macOS user to the `docker` group so you can use `/var/run/docker.sock` without sudo:

```bash
# add current user to the 'docker' group
sudo dseditgroup -o edit -a "$USER" -t user docker

# verify membership
id -Gn | tr ' ' '\n' | grep -x docker || echo "not a member yet"

# re-login or restart your session for the change to take effect
# (a full log out/in is the most reliable)
```

Notes:
- Group membership applies to new login sessions only.
- Remove a user later with:
  ```bash
  sudo dseditgroup -o edit -d "$USER" -t user docker
  ```

## Use
```bash
docker ps           # should work system-wide
sudo launchctl print system/colima.daemon
sudo launchctl print system/colima.socket.permissions
```

## Uninstall
```bash
sudo launchctl bootout system/colima.socket.permissions || true
sudo launchctl bootout system/colima.daemon || true
sudo rm -f /Library/LaunchDaemons/colima.socket.permissions.plist
sudo rm -f /Library/LaunchDaemons/colima.daemon.plist
sudo rm -f /var/run/docker.sock
```

## Notes
- Creates hidden `colima` user and `docker` group.
- Docker socket is group-writable by `docker`; add users cautiously.
- This setup does not install any Docker client tools. Docker CLI is optional; install it only if you need client commands (e.g. `brew install docker`).
