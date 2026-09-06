# .github
Software Engineering Firm - Our mission is to makes Australian Enterprises great again, 1 Kube Cluster at a time

## Claude Code cloud sessions → SWC VPS (SSH)

Sessions in the **Default** cloud environment connect to the SWC VPS over SSH.
The setup lives in [`.claude/environments/default-setup.sh`](.claude/environments/default-setup.sh).

**Configure once** at claude.ai/code → Environments → *Default*:

1. **Setup script** – paste the contents of `.claude/environments/default-setup.sh`.
2. **Environment variables** (stored as secrets, never in this repo):

   | Variable | Value |
   |---|---|
   | `VPS_SSH_PASSWORD` | root password for the VPS |
   | `VPS_HOST` | optional, defaults to `187.77.130.10` |
   | `VPS_USER` | optional, defaults to `root` |
   | `VPS_PORT` | optional, defaults to `22` |

3. **Network policy** – the destination `187.77.130.10:22` must be reachable
   from the environment (add it to the allowed destinations if the policy is
   not *unrestricted*).

**Use in a session:**

```bash
vps uptime          # run a command on the VPS
ssh vps             # open a shell (host alias "vps")
```

The script installs `openssh-client`/`sshpass`, tunnels SSH through the
session's HTTPS egress proxy, and on first login installs a per-session key on
the VPS so the password is only used once per session.
