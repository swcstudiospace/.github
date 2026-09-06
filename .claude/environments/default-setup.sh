#!/usr/bin/env bash
# =============================================================================
# SWC Studio - "Default" Claude Code cloud environment: setup script
#
# Paste this into the Setup script section of the Default environment at
# https://claude.ai/code -> Environments -> Default -> Setup script.
#
# It gives every cloud session an SSH connection to the SWC VPS:
#     ssh vps            # interactive / ad-hoc commands
#     vps "uptime"       # wrapper that handles password or key auth
#
# Required environment variables (set them in the SAME environment settings
# page, under Environment variables - they are stored as secrets there and
# never committed to this repo):
#     VPS_SSH_PASSWORD   root password for the VPS  (required on first run)
# Optional overrides:
#     VPS_HOST           default 187.77.130.10
#     VPS_USER           default root
#     VPS_PORT           default 22
#
# On the first successful password login the script installs a per-session
# SSH key on the VPS, so later commands in the session use key auth. Nothing
# in this file needs to change if the password is rotated - only the secret.
# =============================================================================
set -uo pipefail

VPS_HOST="${VPS_HOST:-187.77.130.10}"
VPS_USER="${VPS_USER:-root}"
VPS_PORT="${VPS_PORT:-22}"

log() { printf '[vps-setup] %s\n' "$*"; }

if [ -z "${VPS_SSH_PASSWORD:-}" ]; then
  log "VPS_SSH_PASSWORD is not set - skipping VPS SSH setup."
  log "Add it as a secret environment variable on the Default environment."
  exit 0
fi

# -----------------------------------------------------------------------------
# 1. SSH client + sshpass (the cloud image ships without them)
# -----------------------------------------------------------------------------
if ! command -v ssh >/dev/null 2>&1 || ! command -v sshpass >/dev/null 2>&1; then
  log "Installing openssh-client and sshpass..."
  export DEBIAN_FRONTEND=noninteractive
  if command -v apt-get >/dev/null 2>&1; then
    (apt-get update -qq && apt-get install -y -qq openssh-client sshpass) >/dev/null 2>&1 \
      || (sudo apt-get update -qq && sudo apt-get install -y -qq openssh-client sshpass) >/dev/null 2>&1 \
      || log "WARNING: package install failed; ssh may be unavailable."
  fi
fi

if ! command -v ssh >/dev/null 2>&1; then
  log "ssh is not available - cannot configure the VPS connection."
  exit 0
fi

# -----------------------------------------------------------------------------
# 2. ProxyCommand helper: tunnel SSH through the session's HTTPS egress proxy.
#    Cloud sessions have no direct outbound TCP; only CONNECT via $HTTPS_PROXY.
# -----------------------------------------------------------------------------
mkdir -p "$HOME/.ssh" "$HOME/.local/bin"
chmod 700 "$HOME/.ssh"

cat > "$HOME/.local/bin/ssh-https-proxy" <<'PY'
#!/usr/bin/env python3
"""ssh ProxyCommand: open an HTTP CONNECT tunnel through $HTTPS_PROXY.
Falls back to a direct TCP connection when no proxy is configured."""
import os, select, socket, sys
from urllib.parse import urlparse

host, port = sys.argv[1], int(sys.argv[2])
proxy = os.environ.get("HTTPS_PROXY") or os.environ.get("https_proxy")

def direct():
    return socket.create_connection((host, port), timeout=20)

if proxy:
    p = urlparse(proxy if "://" in proxy else "http://" + proxy)
    s = socket.create_connection((p.hostname, p.port or 3128), timeout=20)
    s.sendall(f"CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n".encode())
    buf = b""
    while b"\r\n\r\n" not in buf:
        chunk = s.recv(4096)
        if not chunk:
            break
        buf += chunk
    status = buf.split(b"\r\n", 1)[0].decode(errors="replace")
    if " 200" not in status:
        sys.stderr.write(f"ssh-https-proxy: CONNECT {host}:{port} refused: {status}\n")
        s.close()
        try:
            s = direct()
        except OSError as e:
            sys.stderr.write(f"ssh-https-proxy: direct connect failed: {e}\n")
            sys.exit(1)
else:
    s = direct()

s.setblocking(False)
stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
while True:
    r, _, _ = select.select([s, stdin], [], [])
    if s in r:
        data = s.recv(65536)
        if not data:
            break
        stdout.write(data); stdout.flush()
    if stdin in r:
        data = os.read(stdin.fileno(), 65536)
        if not data:
            break
        s.sendall(data)
PY
chmod +x "$HOME/.local/bin/ssh-https-proxy"

# -----------------------------------------------------------------------------
# 3. ssh config: host alias "vps"
# -----------------------------------------------------------------------------
KEY="$HOME/.ssh/id_ed25519_vps"
[ -f "$KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "claude-cloud-session" -f "$KEY"

# Remove any previous managed block, then append a fresh one.
if [ -f "$HOME/.ssh/config" ]; then
  sed -i '/^# >>> swc-vps >>>$/,/^# <<< swc-vps <<<$/d' "$HOME/.ssh/config"
fi
cat >> "$HOME/.ssh/config" <<CFG
# >>> swc-vps >>>
Host vps ${VPS_HOST}
    HostName ${VPS_HOST}
    User ${VPS_USER}
    Port ${VPS_PORT}
    IdentityFile ${KEY}
    IdentitiesOnly yes
    PreferredAuthentications publickey,password
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ${HOME}/.ssh/known_hosts
    ServerAliveInterval 30
    ServerAliveCountMax 3
    ConnectTimeout 20
    ProxyCommand ${HOME}/.local/bin/ssh-https-proxy %h %p
# <<< swc-vps <<<
CFG
chmod 600 "$HOME/.ssh/config"

# -----------------------------------------------------------------------------
# 4. `vps` wrapper: key auth if installed, otherwise password via sshpass.
#    The password is read from the environment (sshpass -e); it is never
#    written to disk or shown in `ps`.
# -----------------------------------------------------------------------------
cat > "$HOME/.local/bin/vps" <<'SH'
#!/usr/bin/env bash
# Usage: vps [command...]      e.g.  vps uptime   |  vps   (interactive shell)
if ssh -o BatchMode=yes -o ConnectTimeout=10 vps true 2>/dev/null; then
  exec ssh vps "$@"
elif [ -n "${VPS_SSH_PASSWORD:-}" ] && command -v sshpass >/dev/null 2>&1; then
  SSHPASS="$VPS_SSH_PASSWORD" exec sshpass -e ssh -o PreferredAuthentications=password -o PubkeyAuthentication=no vps "$@"
else
  echo "vps: no key on the server and VPS_SSH_PASSWORD is not set" >&2
  exit 1
fi
SH
chmod +x "$HOME/.local/bin/vps"

case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)
  export PATH="$HOME/.local/bin:$PATH"
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc" ;;
esac

# -----------------------------------------------------------------------------
# 5. First contact: install this session's public key so the password is only
#    needed once, then verify.
# -----------------------------------------------------------------------------
if command -v sshpass >/dev/null 2>&1; then
  log "Installing session SSH key on ${VPS_USER}@${VPS_HOST}..."
  if SSHPASS="$VPS_SSH_PASSWORD" sshpass -e ssh-copy-id -i "$KEY.pub" \
       -o PreferredAuthentications=password -o PubkeyAuthentication=no vps >/dev/null 2>&1; then
    log "Key installed."
  else
    log "WARNING: could not install key (password login or egress to port ${VPS_PORT} may be blocked)."
  fi
fi

if out="$("$HOME/.local/bin/vps" 'hostname && uptime' 2>&1)"; then
  log "Connected to VPS:"
  printf '%s\n' "$out" | sed 's/^/[vps-setup]   /'
else
  log "WARNING: VPS connection test failed:"
  printf '%s\n' "$out" | sed 's/^/[vps-setup]   /'
  log "If the message is a refused CONNECT, the environment's network policy must allow ${VPS_HOST}:${VPS_PORT}."
fi

log "Done. Use:  vps <command>   or   ssh vps"
