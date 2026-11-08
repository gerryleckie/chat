#!/usr/bin/env bash
# Install Paperclip (npm: paperclipai) on the G2 glasses VPS (46.250.235.158)
# without touching the glasses stack (OpenClaw gateway :19000, OcuClaw, g2-api).
#
# Run as root on the VPS, e.g. from ~/Desktop/G2 on the Mac:
#   scp paperclip/install-g2.sh root@46.250.235.158:/root/ -i ~/.ssh/g2_vps_ed25519
#   ./bin/vps 'bash /root/install-g2.sh'            # step 1: preflight only
#   ./bin/vps 'bash /root/install-g2.sh --install'  # step 2: actually install
#
# Isolation choices:
#   - separate unprivileged user `paperclip` (not `openclaw`, not root)
#   - bound to 127.0.0.1 only; reach it via SSH tunnel or Tailscale
#   - systemd MemoryMax/CPUQuota so it can't starve the glasses services
#   - no Docker
set -euo pipefail

PORT="${PAPERCLIP_PORT:-3100}"
PC_USER=paperclip
MODE="${1:-preflight}"

say() { printf '\n== %s\n' "$*"; }

say "Preflight on $(hostname)"
free -h
df -h /
echo "CPUs: $(nproc)"
echo "Load: $(cut -d' ' -f1-3 /proc/loadavg)"

say "Glasses services (must stay healthy)"
systemctl list-units --type=service --state=running --no-pager | grep -iE 'openclaw|ocuclaw|g2|tailscale' || echo "(none matched)"

say "Port $PORT"
if ss -tlnp | grep -q ":$PORT "; then
  echo "Port $PORT is already in use:"; ss -tlnp | grep ":$PORT "
  echo "Re-run with PAPERCLIP_PORT=<free port>"; exit 1
fi
echo "free"

say "Node.js"
if command -v node >/dev/null; then node -v; else echo "node not installed"; fi

avail_mb=$(awk '/MemAvailable/ {print int($2/1024)}' /proc/meminfo)
disk_gb=$(df -BG --output=avail / | tail -1 | tr -dc 0-9)
echo "Available RAM: ${avail_mb} MB, free disk: ${disk_gb} GB"
if [ "$avail_mb" -lt 1500 ] || [ "$disk_gb" -lt 8 ]; then
  echo "NOT ENOUGH ROOM: need ~1.5 GB free RAM and ~8 GB disk. Stopping."; exit 1
fi

if [ "$MODE" != "--install" ]; then
  say "Preflight OK. Re-run with --install to install."; exit 0
fi

say "Ensuring Node 20+"
major=$(node -v 2>/dev/null | sed 's/v\([0-9]*\).*/\1/' || echo 0)
if [ "${major:-0}" -lt 20 ]; then
  echo "Node 20+ required (found: ${major:-none})."
  echo "OpenClaw also uses Node here, so upgrade deliberately; not changing it automatically."
  exit 1
fi

say "Creating user $PC_USER"
id "$PC_USER" >/dev/null 2>&1 || useradd --system --create-home --shell /bin/bash "$PC_USER"

say "Installing agent CLIs for $PC_USER (Claude Code first, Codex as fallback)"
# User-local npm prefix so we never touch the global Node that OpenClaw uses.
sudo -u "$PC_USER" -H bash -lc '
  mkdir -p ~/.npm-global ~/.config
  npm config set prefix ~/.npm-global
  grep -q npm-global ~/.profile 2>/dev/null || echo "export PATH=\$HOME/.npm-global/bin:\$PATH" >> ~/.profile
  export PATH=$HOME/.npm-global/bin:$PATH
  npm install -g @anthropic-ai/claude-code @openai/codex
  claude --version; codex --version
'

# Subscription auth, not API billing. Paperclip's claude_local adapter runs the
# `claude` CLI; it bills your Claude subscription when CLAUDE_CODE_OAUTH_TOKEN is
# set and ANTHROPIC_API_KEY is NOT set.
ENV_FILE=/home/$PC_USER/.config/paperclip-agents.env
if [ ! -f "$ENV_FILE" ]; then
  cat >"$ENV_FILE" <<'EOF'
# Filled in by you after install (see the steps printed at the end).
# Claude subscription token from `claude setup-token`:
CLAUDE_CODE_OAUTH_TOKEN=
EOF
fi
chown "$PC_USER:$PC_USER" "$ENV_FILE"; chmod 600 "$ENV_FILE"

say "Onboarding Paperclip as $PC_USER (interactive prompts may appear)"
sudo -u "$PC_USER" -H bash -lc "cd ~ && npx --yes paperclipai onboard"

say "Installing systemd unit"
cat >/etc/systemd/system/paperclip.service <<EOF
[Unit]
Description=Paperclip (paperclipai)
After=network-online.target
Wants=network-online.target

[Service]
User=$PC_USER
WorkingDirectory=/home/$PC_USER
Environment=HOST=127.0.0.1
Environment=PORT=$PORT
Environment=PATH=/home/$PC_USER/.npm-global/bin:/usr/local/bin:/usr/bin:/bin
# Subscription token for Claude Code; Codex uses ~/.codex/auth.json from `codex login`.
EnvironmentFile=-/home/$PC_USER/.config/paperclip-agents.env
# Never let an API key sneak in and switch Claude to pay-per-token billing.
UnsetEnvironment=ANTHROPIC_API_KEY OPENAI_API_KEY
ExecStart=/usr/bin/env npx --yes paperclipai run
Restart=on-failure
RestartSec=5
MemoryMax=2G
CPUQuota=150%
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now paperclip
sleep 8

say "Status"
systemctl --no-pager status paperclip | head -15
ss -tlnp | grep ":$PORT " || echo "WARNING: nothing listening on $PORT yet; check: journalctl -u paperclip -n 50"
curl -s -o /dev/null -w "HTTP %{http_code} from http://127.0.0.1:$PORT\n" "http://127.0.0.1:$PORT/" || true

say "Glasses services after install"
systemctl list-units --type=service --state=running --no-pager | grep -iE 'openclaw|ocuclaw|g2|tailscale' || true

cat <<EOF

Done. Now connect your subscriptions (run these yourself; they ask you to log in):

  1) Claude subscription (preferred):
       sudo -u $PC_USER -i claude setup-token
     Log in with your Claude account in the browser link it shows, then put the
     token it prints into $ENV_FILE as CLAUDE_CODE_OAUTH_TOKEN=... and run:
       systemctl restart paperclip
     Check:  sudo -u $PC_USER -i bash -lc 'set -a; . $ENV_FILE; claude -p "say ok"'

  2) Codex / ChatGPT subscription (fallback):
       sudo -u $PC_USER -i codex login      # use --device-auth if no browser
     Check:  sudo -u $PC_USER -i codex exec "say ok"

  In Paperclip, give agents the "Claude Code" (claude_local) adapter; use the
  "Codex" (codex_local) adapter for any agent you want on ChatGPT instead.

Open it from the Mac with an SSH tunnel:
  ssh -i ~/.ssh/g2_vps_ed25519 -N -L $PORT:127.0.0.1:$PORT root@46.250.235.158
  then browse http://localhost:$PORT

Undo completely:
  systemctl disable --now paperclip; rm /etc/systemd/system/paperclip.service
  userdel -r $PC_USER
EOF
