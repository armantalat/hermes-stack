#!/usr/bin/env bash
# ============================================================
#  Hermes Stack — bootstrap for a plain Linux VM.
#  Built for Oracle Cloud "Always Free" Ampere ARM (4 OCPU / 24 GB),
#  works on any Debian/Ubuntu/Oracle Linux/RHEL box with >= 4 GB RAM.
#
#  Usage:
#    bash bootstrap.sh                 # install docker, configure, start
#    bash bootstrap.sh --reconfigure   # re-render config from .env + restart
#    bash bootstrap.sh --no-install    # do not install docker (assume present)
#    bash bootstrap.sh --down          # stop everything
# ============================================================
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE"

RECONFIGURE=0; NO_INSTALL=0; DOWN=0
for a in "$@"; do
  case "$a" in
    --reconfigure) RECONFIGURE=1 ;;
    --no-install)  NO_INSTALL=1 ;;
    --down)        DOWN=1 ;;
    -h|--help)     sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a" >&2; exit 2 ;;
  esac
done

c_g=$'\033[32m'; c_y=$'\033[33m'; c_r=$'\033[31m'; c_d=$'\033[2m'; c_0=$'\033[0m'
say(){ printf '%s\n' "$*"; }
ok(){ printf '%s✓%s %s\n' "$c_g" "$c_0" "$*"; }
warn(){ printf '%s!%s %s\n' "$c_y" "$c_0" "$*"; }
die(){ printf '%s✗%s %s\n' "$c_r" "$c_0" "$*" >&2; exit 1; }
have(){ command -v "$1" >/dev/null 2>&1; }

gen_secret(){ # $1 = length
  local n="${1:-32}"
  if have openssl; then
    openssl rand -base64 64 | tr -dc 'A-Za-z0-9' | head -c "$n"
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$n" || true
  fi
  printf '\n'
}

esc_sed(){ printf '%s' "$1" | sed -e 's/[&|\\]/\\&/g'; }

set_env(){ # set_env KEY VALUE  (upsert into .env + export)
  local k="$1" v="$2"
  if grep -qE "^${k}=" .env; then
    sed -i "s|^${k}=.*|${k}=$(esc_sed "$v")|" .env
  else
    printf '%s=%s\n' "$k" "$v" >> .env
  fi
  export "$k=$v"
}
get_env(){ grep -E "^$1=" .env 2>/dev/null | head -1 | cut -d= -f2- || true; }

ask(){ # ask VAR "label" [silent] [default]
  local __v="$1" __label="$2" __silent="${3:-}" __def="${4:-}" __val="${!1:-}"
  if [ -z "$__val" ] && [ -t 0 ]; then
    if [ -n "$__silent" ]; then
      read -r -s -p "$__label${__def:+ [$__def]}: " __val || true; printf '\n'
    else
      read -r -p "$__label${__def:+ [$__def]}: " __val || true
    fi
    [ -z "$__val" ] && __val="$__def"
  fi
  [ -n "$__val" ] && set_env "$__v" "$__val"
  printf -v "$__v" '%s' "${__val:-${__def}}"
}

# ---------------------------------------------------------------- .env
if [ ! -f .env ]; then
  cp .env.example .env
  ok "created .env from .env.example"
fi
set -a; . ./.env; set +a

# normalise SITE_ADDRESS (accept a pasted URL) and derive cookie security
case "${SITE_ADDRESS:-:80}" in
  http://*)  SITE_ADDRESS="${SITE_ADDRESS#http://}" ;;
  https://*) SITE_ADDRESS="${SITE_ADDRESS#https://}" ;;
esac
SITE_ADDRESS="${SITE_ADDRESS:-:80}"
case "$SITE_ADDRESS" in
  */*) die "SITE_ADDRESS must be ':80' or a bare domain like ai.example.com (no path)" ;;
esac
set_env SITE_ADDRESS "$SITE_ADDRESS"
if [ "${SITE_ADDRESS#:}" = "$SITE_ADDRESS" ]; then
  set_env AUTH_COOKIE_SECURE "true"    # real HTTPS in front -> secure cookies
  BASE_URL="https://${SITE_ADDRESS}"
else
  set_env AUTH_COOKIE_SECURE "false"   # plain HTTP -> secure cookies would break login
  IP="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
  [ -z "$IP" ] && IP="localhost"
  BASE_URL="http://${IP}"
  [ "${SITE_ADDRESS#:}" != "80" ] && BASE_URL="${BASE_URL}:${SITE_ADDRESS#:}"
fi
ok "site address: ${SITE_ADDRESS}  (agent dashboard will be at ${BASE_URL}/hermes/)"

# ------------------------------------------------- first-run credentials
fill(){ # fill KEY VALUE — only when the current value is blank
  local k="$1" v="$2"
  if [ -z "$(get_env "$k")" ]; then set_env "$k" "$v"; ok "generated ${k}"; fi
}
fill DASHBOARD_USERNAME        "admin"
fill DASHBOARD_PASSWORD        "$(gen_secret 24)"
fill HERMES_API_KEY            "hs-$(gen_secret 40)"
fill NINEROUTER_API_KEY        "$(gen_secret 40)"
fill ROUTER_INITIAL_PASSWORD   "$(gen_secret 20)"
fill OMNI_ROUTER_KEY           "sk-omni-$(gen_secret 48)"
fill OMNI_ADMIN_PASSWORD       "$(gen_secret 24)"
fill BACKUP_INTERVAL           "3600"

# --------------------------------------------------------- optional inputs
ask HF_TOKEN "Hugging Face WRITE token (blank = no off-VM backups)" silent
if [ -n "${HF_TOKEN:-}" ]; then
  HF_WHO="$(curl -fsS --max-time 30 -H "Authorization: Bearer ${HF_TOKEN}" \
            https://huggingface.co/api/whoami-v2 2>/dev/null || true)"
  if printf '%s' "$HF_WHO" | grep -q '"name"'; then
    HF_HANDLE="$(printf '%s' "$HF_WHO" | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' | head -1)"
    ok "Hugging Face token OK (${HF_HANDLE})"
    ask HF_USERNAME "HF username" "" "${HF_HANDLE:-}"
    ask BACKUP_REPO "Backup dataset repo" "" "${HF_USERNAME:-armtlr}/hermes-backup"
  else
    warn "HF token not valid — backups disabled (re-run: bash bootstrap.sh --reconfigure)"
    set_env HF_TOKEN ""
  fi
fi

ask TELEGRAM_BOT_TOKEN "Telegram bot token (blank = no Telegram)" silent
if [ -n "${TELEGRAM_BOT_TOKEN:-}" ]; then
  TG_ME="$(curl -fsS --max-time 20 "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" 2>/dev/null || true)"
  if printf '%s' "$TG_ME" | grep -q '"ok":true'; then
    ok "Telegram bot @$(printf '%s' "$TG_ME" | sed -n 's/.*"username":"\([^"]*\)".*/\1/p' | head -1)"
  else
    warn "Telegram token not valid — the bot stays off"
    set_env TELEGRAM_BOT_TOKEN ""
  fi
fi
ask HERMES_TIMEZONE "Agent timezone" "" "${HERMES_TIMEZONE:-UTC}"
if [ -z "${HERMES_MODEL:-}" ]; then
  warn "HERMES_MODEL is empty — the agent will have no model until you set it"
  say "  after the router dashboard is up: copy a model id from its Models tab, put it in .env,"
  say "  then run:  bash bootstrap.sh --reconfigure"
fi
# ------------------------------------------------------------- docker
if [ "$(id -u)" = "0" ]; then SUDO=""; else SUDO="sudo"; fi
dc(){ $SUDO docker compose "$@"; }

if ! have docker; then
  [ "$NO_INSTALL" = 1 ] && die "docker is not installed and --no-install was passed"
  ok "installing docker (get.docker.com)…"
  curl -fsSL https://get.docker.com -o /tmp/get-docker.sh || die "could not download the docker installer"
  $SUDO sh /tmp/get-docker.sh
  $SUDO systemctl enable --now docker 2>/dev/null || true
  rm -f /tmp/get-docker.sh
fi
if ! $SUDO docker info >/dev/null 2>&1; then
  $SUDO systemctl start docker 2>/dev/null || true
  $SUDO docker info >/dev/null 2>&1 || die "the docker daemon is not running"
fi
$SUDO docker compose version >/dev/null 2>&1 || die "docker compose plugin is missing (install docker-compose-plugin)"
ok "docker ready"

if [ "$DOWN" = 1 ]; then
  dc down
  ok "stopped — data kept in ./data"
  exit 0
fi

# ------------------------------------------------------------ firewall
open_port(){ # open_port 80
  local p="$1"
  if have ufw && $SUDO ufw status 2>/dev/null | grep -q "Status: active"; then
    $SUDO ufw allow "${p}/tcp" >/dev/null 2>&1 || true
  fi
  if have firewall-cmd && $SUDO firewall-cmd --state >/dev/null 2>&1; then
    $SUDO firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
  fi
  if have iptables; then
    if ! $SUDO iptables -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1; then
      $SUDO iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
    fi
  fi
}
open_port "${HTTP_PORT:-80}"
open_port "${HTTPS_PORT:-443}"
if have firewall-cmd; then $SUDO firewall-cmd --reload >/dev/null 2>&1 || true; fi
if have netfilter-persistent; then $SUDO netfilter-persistent save >/dev/null 2>&1 || true; fi
ok "local firewall opened for ${HTTP_PORT:-80}/${HTTPS_PORT:-443} (open these in your cloud console too!)"

# ------------------------------------------ Hugging Face backup dataset
if [ -n "${HF_TOKEN:-}" ] && [ -n "${BACKUP_REPO:-}" ]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
          -H "Authorization: Bearer ${HF_TOKEN}" \
          "https://huggingface.co/api/datasets/${BACKUP_REPO}" || echo 000)"
  if [ "$CODE" = "200" ]; then
    ok "backup dataset ready: ${BACKUP_REPO}"
  else
    RESP="$(curl -s --max-time 30 -X POST https://huggingface.co/api/repos/create \
            -H "Authorization: Bearer ${HF_TOKEN}" -H 'Content-Type: application/json' \
            -d "{\"type\":\"dataset\",\"name\":\"${BACKUP_REPO#*/}\",\"private\":true}" || true)"
    case "$RESP" in
      *'"url"'*|*'already'*|*'exists'*) ok "backup dataset created (private): ${BACKUP_REPO}" ;;
      *) warn "could not create ${BACKUP_REPO} — check token/name (${RESP:0:110})" ;;
    esac
  fi
fi

# ------------------------------------------------------------- restore
if [ ! -f ./data/hermes/config.yaml ] && [ -n "${HF_TOKEN:-}" ] && [ -n "${BACKUP_REPO:-}" ]; then
  say "${c_d}looking for an existing backup to restore…${c_0}"
  mkdir -p ./data/hermes
  if $SUDO docker run --rm -e HF_TOKEN -e BACKUP_REPO \
       -v "$HERE/kit:/kit:ro" -v "$HERE/data/hermes:/opt/data" python:3.12-slim \
       sh -c 'pip install -q "huggingface_hub>=0.30" && python /kit/restore.py'; then
    ok "restored state from ${BACKUP_REPO}"
  else
    warn "no usable backup — starting fresh"
  fi
fi

# --------------------------------------------------- render agent config
say ""
say "── rendering agent config from .env ──"
bash kit/render-config.sh
# ------------------------------------------------------ build and start
say ""
say "── building and starting containers ──"
dc build || die "image build failed (check internet access to github.com and docker.io)"
dc up -d

if dc exec -T caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null 2>&1; then
  ok "Caddyfile is valid"
else
  warn "Caddyfile validation reported a problem — see: docker compose logs caddy"
fi

say "${c_d}waiting for the front door (first start pulls ~1.2 GB of images)…${c_0}"
CODE=000
for _ in $(seq 1 40); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://127.0.0.1:${HTTP_PORT:-80}/healthz" || echo 000)"
  [ "$CODE" = "200" ] && break
  sleep 5
done
if [ "$CODE" = "200" ]; then
  ok "/healthz answered 200 — the stack is up"
else
  warn "/healthz is not answering yet — watch: docker compose logs -f hermes router"
fi
dc ps

# ------------------------------------------------------------- summary
CREDS="$HOME/.hermes-stack-credentials.txt"
{
  printf 'Hermes Stack (VM) credentials — %s\n' "$(date -u '+%F %T UTC')"
  printf '\n== URLs ==\n'
  printf 'router dashboard : %s/\n' "$BASE_URL"
  printf 'router API (/v1) : %s/v1\n' "$BASE_URL"
  printf 'agent dashboard  : %s/hermes/\n' "$BASE_URL"
  printf 'agent API        : %s/hermes-api/v1\n' "$BASE_URL"
  printf 'health           : %s/healthz\n' "$BASE_URL"
  printf 'backups          : https://huggingface.co/datasets/%s\n' "${BACKUP_REPO:-<disabled>}"
  printf '\n== Values ==\n'
  printf 'ROUTER_INITIAL_PASSWORD  router dashboard login (any username) : %s\n' "$(get_env ROUTER_INITIAL_PASSWORD)"
  printf 'NINEROUTER_API_KEY       create the SAME key in the dashboard  : %s\n' "$(get_env NINEROUTER_API_KEY)"
  printf 'DASHBOARD_USERNAME       /hermes/ basic auth                  : %s\n' "$(get_env DASHBOARD_USERNAME)"
  printf 'DASHBOARD_PASSWORD       /hermes/ basic auth                  : %s\n' "$(get_env DASHBOARD_PASSWORD)"
  printf 'HERMES_API_KEY           /hermes-api/v1 bearer key            : %s\n' "$(get_env HERMES_API_KEY)"
  printf 'OMNI_ROUTER_KEY          keyless-models router key            : %s\n' "$(get_env OMNI_ROUTER_KEY)"
  printf 'OMNI_ADMIN_PASSWORD      keyless-models dashboard             : %s\n' "$(get_env OMNI_ADMIN_PASSWORD)"
} > "$CREDS"
chmod 600 "$CREDS"

say ""
ok "done — credentials saved to $CREDS"
say ""
say "Next 4 steps:"
say "  1. open ${BASE_URL}/  → log in with any username + ROUTER_INITIAL_PASSWORD,"
say "     create an API key equal to NINEROUTER_API_KEY, connect a free provider."
say "  2. copy an exact model id from the router's Models tab into .env (HERMES_MODEL),"
say "     then run:  bash bootstrap.sh --reconfigure"
say "  3. send /start to your Telegram bot (only TELEGRAM_ALLOWED_USERS may use it)."
say "  4. open ${HTTP_PORT:-80} and ${HTTPS_PORT:-443} for 0.0.0.0/0 in your cloud"
say "     provider's security list / ingress rules, or nothing can reach this VM."


