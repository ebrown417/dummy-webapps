# dummy-webapps

A single Bash script (`setup.sh`) that scaffolds a fake "enterprise suite" — Employee Portal, HR, CRM, and IT Service Desk — and serves it locally on Docker via Traefik.

Useful for demos, screenshots, lab environments, and anywhere you want plausible-looking internal web apps without writing four mock sites by hand.

## What it generates

Four static nginx sites, each with branded HTML pages, routed by Traefik under your own internal domain:

| App           | URL                                       |
| ------------- | ----------------------------------------- |
| Portal        | `http://portal.<your-zone>.<your-domain>` |
| HR            | `http://hr.<your-zone>.<your-domain>`     |
| CRM           | `http://crm.<your-zone>.<your-domain>`    |
| Service Desk  | `http://servicedesk.<your-zone>.<your-domain>` |

All pages share a logo you provide and use the org name you provide.

## Requirements

- Linux host (Debian/Ubuntu or RHEL/CentOS/Fedora/Rocky/Alma)
- `sudo` / root — the script installs Docker + Compose if they're missing
- A logo file (`.png`, `.jpg`, `.jpeg`, `.svg`, or `.gif`)
- DNS pointing your chosen hostnames to the host (or local `/etc/hosts` entries — the script prints the records you need)

## Usage

```bash
git clone https://github.com/ebrown417/dummy-webapps.git
cd dummy-webapps
sudo ./setup.sh
```

The script will interactively ask for:

1. **Organization name** — shown in headers and titles (e.g., `ACME Corp`)
2. **Zone / Domain / TLD** — assembled into `<zone>.<domain>.<tld>` (e.g., `int.acmecorp.lan`)
3. **Host IP** — autodetected from the default route; override if needed
4. **Path to a logo file** — copied into each site

After confirmation, it:

1. Installs Docker Engine + Compose plugin if missing
2. Writes `docker-compose.yml`, `traefik/traefik.yml`, and the four `apps/*/index.html` files
3. Runs `docker compose up -d`
4. Prints the URLs and the DNS records you need

## DNS

The script tells you exactly what to add. You have two options:

- **Real DNS** — add an A record for `*.<your-zone>.<your-domain>.<tld>` pointing at the host IP
- **Local only** — add entries to `/etc/hosts` on each machine that will browse the demo

## Teardown

```bash
cd dummy-webapps
sudo docker compose down
```

Add `-v` to also drop any volumes (there are none by default).

## Notes

- All sites are read-only static HTML — no databases, no auth, no real functionality
- Traefik listens on port 80 only (no TLS by default)
- Re-running the script will overwrite the generated files and redeploy the stack
