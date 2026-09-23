# 🛰️ Hermes Stack on a free VM (Oracle Always Free ARM)

This is the same stack as the Hugging Face Space — **Hermes Agent + 9Router +
OmniRouter behind Caddy** — but hosted on a plain Linux VM instead of a Space,
because HF now requires a paid plan for Docker Spaces (only *static* Spaces are
free). **Datasets are still free**, so hourly backups keep going to a private HF
dataset, exactly like before.

```
browser ──► Caddy (80/443) ──┬──► router:20128      9Router dashboard + /v1 API
                             ├──► hermes:9119       agent dashboard  (/hermes/)
                             ├──► hermes:8642       agent OpenAI API (/hermes-api/v1)
                             └──► /healthz          keep-alive / monitoring
hermes ──► router:20128 ──► omnirouter:8080         keyless free models
Telegram ◄──polling── hermes gateway
backup ──► private HF dataset (latest.tar.gz + 72 hourly snapshots)
```

## 1. Create the free VM (Oracle Cloud)

Oracle Cloud "Always Free" is the only free tier with enough RAM for this stack
(4 OCPU / 24 GB ARM). Signup asks for a card for identity verification — nothing
is charged if you stay inside the free limits.

1. Sign up at <https://signup.cloud.oracle.com> → choose a **home region** near you
   (ARM capacity varies by region; if you get "out of capacity", retry later or
   try another region).
2. **Compute → Instances → Create instance**
   - Shape: **Ampere / `VM.Standard.A1.Flex`**, 4 OCPU, 24 GB RAM (all Always Free)
   - Image: **Ubuntu 24.04** (ARM build) — or Oracle Linux 9
   - Add your **SSH public key**, download the private key
   - Networking: public IPv4 address enabled
3. **Open the ports** in the VCN security list: add ingress rules
   `0.0.0.0/0 → TCP 80` and `0.0.0.0/0 → TCP 443`.
   (`bootstrap.sh` fixes the VM's *local* firewall, but it cannot touch the
   cloud-level security list — that is the #1 reason "nothing loads".)

> GCP's free `e2-micro` (1 GB RAM) is **too small** for this stack — the images
> alone are ~1.2 GB and 9Router + Hermes need real memory. GCP works only if you
> pay for a bigger instance. Any 4 GB+ VPS you already own is fine too.

## 2. Install

```bash
ssh ubuntu@<vm-public-ip>          # Oracle Linux: ssh opc@<ip>  (then: sudo bash)

sudo apt-get update && sudo apt-get install -y git curl   # Ubuntu/Debian
# Oracle Linux: sudo dnf install -y git curl

git clone https://github.com/armantalat/hermes-stack.git
cd hermes-stack/vps
cp .env.example .env      # optional: edit first, or let bootstrap ask
bash bootstrap.sh
```

`bootstrap.sh` will: install Docker + compose, open the local firewall, generate
all passwords, create + verify your **private HF backup dataset**, restore a
previous backup if one exists, render the agent config, build the images, start
everything, validate the Caddyfile and wait for `/healthz`.

It prints the URLs at the end and saves every generated credential to
`~/.hermes-stack-credentials.txt` (mode 600).

## 3. Finish in the web UI (2 minutes)

1. Open `http://<vm-ip>/` → log in with **any username** + `ROUTER_INITIAL_PASSWORD`.
   Then **API keys → create a key equal to `NINEROUTER_API_KEY`** (the agent sends
   exactly that key) and connect a free provider in the dashboard.
2. Copy an exact model id from the router's **Models** tab into `.env`
   (`HERMES_MODEL=...`), then `bash bootstrap.sh --reconfigure`.
   Without this the agent has no model and looks "broken".
3. Send `/start` to your Telegram bot. Only ids in `TELEGRAM_ALLOWED_USERS` are answered.
4. Agent dashboard: `http://<vm-ip>/hermes/` (basic auth from `.env`).
   Agent API: `http://<vm-ip>/hermes-api/v1` with `Authorization: Bearer $HERMES_API_KEY`.

## HTTPS with a real domain (optional, automatic)

Point an `A` record at the VM, set `SITE_ADDRESS=ai.example.com` in `.env`, then
`bash bootstrap.sh --reconfigure` → Caddy fetches a Let's Encrypt certificate
itself. `AUTH_COOKIE_SECURE` is switched on automatically when you do this
(leaving it on over plain HTTP breaks the router dashboard login).

## Day-2 commands

| What | Command |
|---|---|
| status | `docker compose ps` |
| logs | `docker compose logs -f hermes router omnirouter` |
| apply .env changes | `bash bootstrap.sh --reconfigure` |
| stop / start | `bash bootstrap.sh --down` / `bash bootstrap.sh` |
| backup now | `docker compose exec backup python /kit/backup.py` |
| restore | stop hermes, empty `./data/hermes`, run bootstrap again |
| update images | `docker compose pull && bash bootstrap.sh --reconfigure` |

Data lives in `./data/{hermes,9router,omnirouter}` — copy that folder and you have
a full backup of the whole stack.

## Differences vs the HF Space version

| | HF Space | this bundle |
|---|---|---|
| cost | needs PRO now | free VM (Oracle Always Free) |
| front proxy | Caddy on :7860 | Caddy on :80/:443 |
| upstreams | `127.0.0.1:PORT` | compose service names (`router`, `hermes`, …) |
| supervision | custom supervisor + backoff | docker `restart: unless-stopped` |
| architecture | amd64 only (HF builds it) | **amd64 + arm64** (build-arg driven) |
| agent binds | 127.0.0.1 | 0.0.0.0 (container network; only Caddy is exposed) |
| backups | hourly → private HF dataset | same (datasets stay free) |
