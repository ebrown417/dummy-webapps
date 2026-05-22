#!/usr/bin/env bash
# =============================================================================
# Enterprise Demo Suite — setup.sh
# Deploys HR Portal, CRM, IT Service Desk, and Employee Portal via Docker/Traefik
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Color helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}=== $* ===${NC}\n"; }

# ---------------------------------------------------------------------------
# Determine script directory (the enterprise-demo folder)
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================================
# STEP 1 — DEPENDENCY CHECKS
# =============================================================================
header "Step 1: Dependency Checks"

# --- Root / sudo check -------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    warn "This script is not running as root. Package installations may fail."
    echo -n "Continue anyway? [y/N] "
    read -r CONTINUE_NONROOT
    if [[ ! "${CONTINUE_NONROOT,,}" =~ ^y ]]; then
        echo "Please re-run with: sudo $0"
        exit 1
    fi
fi

SUDO=""
if [[ $EUID -ne 0 ]]; then
    SUDO="sudo"
fi

# --- Distro detection --------------------------------------------------------
detect_distro() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        DISTRO_ID="${ID:-unknown}"
        DISTRO_ID_LIKE="${ID_LIKE:-}"
    elif [[ -f /etc/redhat-release ]]; then
        DISTRO_ID="rhel"
        DISTRO_ID_LIKE="rhel"
    else
        DISTRO_ID="unknown"
        DISTRO_ID_LIKE=""
    fi

    # Normalise to family
    if echo "${DISTRO_ID} ${DISTRO_ID_LIKE}" | grep -qiE 'ubuntu|debian'; then
        DISTRO_FAMILY="debian"
        PKG_MANAGER="apt-get"
    elif echo "${DISTRO_ID} ${DISTRO_ID_LIKE}" | grep -qiE 'rhel|centos|fedora|rocky|alma'; then
        DISTRO_FAMILY="rhel"
        if command -v dnf &>/dev/null; then
            PKG_MANAGER="dnf"
        else
            PKG_MANAGER="yum"
        fi
    else
        DISTRO_FAMILY="unknown"
        PKG_MANAGER=""
    fi
}

detect_distro
info "Detected distro family: ${DISTRO_FAMILY} (${DISTRO_ID})"

# --- Helper: install packages ------------------------------------------------
pkg_install() {
    local pkgs=("$@")
    if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
        $SUDO apt-get install -y "${pkgs[@]}" || die "apt-get install failed for: ${pkgs[*]}"
    elif [[ "${DISTRO_FAMILY}" == "rhel" ]]; then
        $SUDO "${PKG_MANAGER}" install -y "${pkgs[@]}" || die "${PKG_MANAGER} install failed for: ${pkgs[*]}"
    else
        die "Unsupported distro '${DISTRO_ID}'. Please install manually: ${pkgs[*]}"
    fi
}

# --- curl check --------------------------------------------------------------
check_curl() {
    if command -v curl &>/dev/null; then
        success "curl is installed."
    else
        warn "curl not found. Installing..."
        if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
            $SUDO apt-get update -y && pkg_install curl
        else
            pkg_install curl
        fi
        command -v curl &>/dev/null || die "curl installation failed."
        success "curl installed."
    fi
}

# --- Docker check / install --------------------------------------------------
install_docker_debian() {
    info "Installing Docker Engine on Debian/Ubuntu..."
    $SUDO apt-get update -y
    $SUDO apt-get install -y ca-certificates curl gnupg lsb-release
    $SUDO install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" | \
        $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    $SUDO chmod a+r /etc/apt/keyrings/docker.gpg
    echo \
        "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${DISTRO_ID} \
$(lsb_release -cs) stable" | \
        $SUDO tee /etc/apt/sources.list.d/docker.list > /dev/null
    $SUDO apt-get update -y
    $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
}

install_docker_rhel() {
    info "Installing Docker Engine on RHEL/CentOS/Fedora/Rocky/Alma..."
    $SUDO "${PKG_MANAGER}" install -y yum-utils 2>/dev/null || true
    if command -v dnf &>/dev/null; then
        $SUDO dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        $SUDO dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    else
        $SUDO yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        $SUDO yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    fi
}

check_docker() {
    if command -v docker &>/dev/null && docker info &>/dev/null 2>&1; then
        success "Docker is installed and running."
        return 0
    fi

    if command -v docker &>/dev/null; then
        warn "Docker is installed but the daemon is not running."
        echo -n "Attempt to start Docker daemon? [Y/n] "
        read -r START_DOCKER
        if [[ ! "${START_DOCKER,,}" =~ ^n ]]; then
            $SUDO systemctl start docker && $SUDO systemctl enable docker || die "Failed to start Docker daemon."
            docker info &>/dev/null || die "Docker daemon did not start successfully."
            success "Docker daemon started."
            return 0
        fi
    fi

    warn "Docker Engine not found."
    if [[ "${DISTRO_FAMILY}" == "unknown" ]]; then
        error "Cannot auto-install on unsupported distro '${DISTRO_ID}'."
        echo "Please install Docker manually: https://docs.docker.com/engine/install/"
        exit 1
    fi

    echo -n "Auto-install Docker Engine via official repos? [Y/n] "
    read -r INSTALL_DOCKER
    if [[ "${INSTALL_DOCKER,,}" =~ ^n ]]; then
        echo ""
        echo "Manual Docker installation instructions:"
        echo "  Debian/Ubuntu: https://docs.docker.com/engine/install/ubuntu/"
        echo "  RHEL/CentOS:   https://docs.docker.com/engine/install/centos/"
        echo "  Fedora:        https://docs.docker.com/engine/install/fedora/"
        echo ""
        exit 0
    fi

    if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
        install_docker_debian || die "Docker installation failed."
    elif [[ "${DISTRO_FAMILY}" == "rhel" ]]; then
        install_docker_rhel || die "Docker installation failed."
    fi

    $SUDO systemctl start docker && $SUDO systemctl enable docker || die "Failed to start Docker after install."
    docker info &>/dev/null || die "Docker installed but daemon not responding."
    success "Docker installed and started."
}

# --- Docker Compose check / install ------------------------------------------
check_docker_compose() {
    if docker compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
        success "Docker Compose (plugin) is available."
        return 0
    elif command -v docker-compose &>/dev/null; then
        COMPOSE_CMD="docker-compose"
        success "docker-compose is available."
        return 0
    fi

    warn "Docker Compose not found. Installing docker-compose-plugin..."
    if [[ "${DISTRO_FAMILY}" == "debian" ]]; then
        pkg_install docker-compose-plugin
    elif [[ "${DISTRO_FAMILY}" == "rhel" ]]; then
        pkg_install docker-compose-plugin
    else
        die "Cannot auto-install docker-compose on unsupported distro. Please install manually."
    fi

    docker compose version &>/dev/null 2>&1 || die "docker-compose-plugin install failed."
    COMPOSE_CMD="docker compose"
    success "Docker Compose plugin installed."
}

check_curl
check_docker
check_docker_compose

echo ""
success "✓ All dependencies satisfied"

# =============================================================================
# STEP 2 — INTERACTIVE CONFIGURATION
# =============================================================================
header "Step 2: Configuration"

# 2a. Org name ----------------------------------------------------------------
while true; do
    echo -n "Enter your organization name (e.g., ACME Corp): "
    read -r ORG_NAME
    if [[ -n "${ORG_NAME}" ]]; then
        break
    fi
    warn "Organization name cannot be empty."
done

# 2b. Domain construction -----------------------------------------------------
while true; do
    echo ""
    echo -n "Zone/subdomain (e.g., int, home, lab, internal): "
    read -r ZONE
    echo -n "Domain name (e.g., acmecorp, mycompany): "
    read -r DOMAIN
    echo -n "TLD (e.g., com, local, lan): "
    read -r TLD

    if [[ -z "${ZONE}" || -z "${DOMAIN}" || -z "${TLD}" ]]; then
        warn "All three parts are required. Please try again."
        continue
    fi

    BASE_FQDN="${ZONE}.${DOMAIN}.${TLD}"

    echo ""
    echo "Your apps will be accessible at:"
    echo "  http://portal.${BASE_FQDN}"
    echo "  http://hr.${BASE_FQDN}"
    echo "  http://crm.${BASE_FQDN}"
    echo "  http://servicedesk.${BASE_FQDN}"
    echo ""
    echo -n "Confirm these URLs? [Y/n] "
    read -r CONFIRM_URLS
    if [[ ! "${CONFIRM_URLS,,}" =~ ^n ]]; then
        break
    fi
done

# 2c. Host IP -----------------------------------------------------------------
DETECTED_IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}' 2>/dev/null || hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo "Detected host IP: ${DETECTED_IP}"
echo -n "Use this IP? Press Enter to accept, or type a different IP: "
read -r USER_IP
if [[ -n "${USER_IP}" ]]; then
    HOST_IP="${USER_IP}"
else
    HOST_IP="${DETECTED_IP}"
fi
success "Using host IP: ${HOST_IP}"

# 2d. Logo file ---------------------------------------------------------------
echo ""
while true; do
    echo -n "Path to your logo image (png, jpg, jpeg, svg, gif): "
    read -r LOGO_PATH

    if [[ ! -f "${LOGO_PATH}" ]]; then
        warn "File not found: ${LOGO_PATH}"
        continue
    fi

    LOGO_EXT="${LOGO_PATH##*.}"
    LOGO_EXT_LOWER="${LOGO_EXT,,}"
    if [[ ! "${LOGO_EXT_LOWER}" =~ ^(png|jpg|jpeg|svg|gif)$ ]]; then
        warn "Unsupported file type: .${LOGO_EXT}. Supported: png, jpg, jpeg, svg, gif"
        continue
    fi

    LOGO_FILE="logo.${LOGO_EXT_LOWER}"
    break
done

# =============================================================================
# STEP 3 — DNS SUMMARY
# =============================================================================
header "Step 3: DNS Records Required"

PAD_IP="${HOST_IP}"
printf '\n'
printf '╔══════════════════════════════════════════════════════════════════╗\n'
printf '║                      DNS RECORDS REQUIRED                       ║\n'
printf '╠══════════════════════════════════════════════════════════════════╣\n'
printf '║                                                                  ║\n'
printf '║  Create the following A records on your DNS server:              ║\n'
printf '║                                                                  ║\n'
printf "║  %-26s →  %-28s║\n" "hr.${BASE_FQDN}"          "${PAD_IP}"
printf "║  %-26s →  %-28s║\n" "crm.${BASE_FQDN}"         "${PAD_IP}"
printf "║  %-26s →  %-28s║\n" "servicedesk.${BASE_FQDN}" "${PAD_IP}"
printf "║  %-26s →  %-28s║\n" "portal.${BASE_FQDN}"      "${PAD_IP}"
printf '║                                                                  ║\n'
printf '║  Alternatively, create a wildcard record:                        ║\n'
printf '║                                                                  ║\n'
printf "║  %-26s →  %-28s║\n" "*.${BASE_FQDN}"           "${PAD_IP}"
printf '║                                                                  ║\n'
printf '╚══════════════════════════════════════════════════════════════════╝\n'
printf '\n'

echo -n "Press Enter to continue..."
read -r

# =============================================================================
# STEP 4 — FILE GENERATION AND DEPLOYMENT
# =============================================================================
header "Step 4: Generating Files and Deploying"

cd "${SCRIPT_DIR}"

# Copy logo asset
info "Copying logo..."
mkdir -p assets
cp "${LOGO_PATH}" "assets/${LOGO_FILE}" || die "Failed to copy logo from ${LOGO_PATH}"
success "Logo saved as assets/${LOGO_FILE}"

# Create directory structure
mkdir -p traefik apps/portal/assets apps/hr/assets apps/crm/assets apps/servicedesk/assets

# ---------------------------------------------------------------------------
# traefik/traefik.yml
# ---------------------------------------------------------------------------
info "Writing traefik/traefik.yml..."
cat > traefik/traefik.yml << 'TRAEFIKEOF'
api:
  dashboard: false
  insecure: false
entryPoints:
  web:
    address: ":80"
providers:
  docker:
    exposedByDefault: false
log:
  level: INFO
TRAEFIKEOF
success "traefik/traefik.yml written."

# ---------------------------------------------------------------------------
# docker-compose.yml  (backtick-safe via printf)
# ---------------------------------------------------------------------------
info "Writing docker-compose.yml..."
cat > docker-compose.yml << COMPOSEEOF
version: "3.8"

networks:
  enterprise-net:
    driver: bridge

services:

  traefik:
    image: traefik:latest
    container_name: enterprise_traefik
    restart: unless-stopped
    ports:
      - "80:80"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
      - ./traefik/traefik.yml:/etc/traefik/traefik.yml:ro
    networks:
      - enterprise-net

  portal:
    image: nginx:alpine
    container_name: enterprise_portal
    restart: unless-stopped
    volumes:
      - ./apps/portal:/usr/share/nginx/html:ro
      - ./assets:/usr/share/nginx/html/assets:ro
    networks:
      - enterprise-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.portal.rule=Host(\`portal.${BASE_FQDN}\`)"
      - "traefik.http.routers.portal.entrypoints=web"
      - "traefik.http.services.portal.loadbalancer.server.port=80"

  hr:
    image: nginx:alpine
    container_name: enterprise_hr
    restart: unless-stopped
    volumes:
      - ./apps/hr:/usr/share/nginx/html:ro
      - ./assets:/usr/share/nginx/html/assets:ro
    networks:
      - enterprise-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.hr.rule=Host(\`hr.${BASE_FQDN}\`)"
      - "traefik.http.routers.hr.entrypoints=web"
      - "traefik.http.services.hr.loadbalancer.server.port=80"

  crm:
    image: nginx:alpine
    container_name: enterprise_crm
    restart: unless-stopped
    volumes:
      - ./apps/crm:/usr/share/nginx/html:ro
      - ./assets:/usr/share/nginx/html/assets:ro
    networks:
      - enterprise-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.crm.rule=Host(\`crm.${BASE_FQDN}\`)"
      - "traefik.http.routers.crm.entrypoints=web"
      - "traefik.http.services.crm.loadbalancer.server.port=80"

  servicedesk:
    image: nginx:alpine
    container_name: enterprise_servicedesk
    restart: unless-stopped
    volumes:
      - ./apps/servicedesk:/usr/share/nginx/html:ro
      - ./assets:/usr/share/nginx/html/assets:ro
    networks:
      - enterprise-net
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.servicedesk.rule=Host(\`servicedesk.${BASE_FQDN}\`)"
      - "traefik.http.routers.servicedesk.entrypoints=web"
      - "traefik.http.services.servicedesk.loadbalancer.server.port=80"
COMPOSEEOF
success "docker-compose.yml written."

# ---------------------------------------------------------------------------
# apps/portal/index.html
# ---------------------------------------------------------------------------
info "Writing apps/portal/index.html..."
cat > apps/portal/index.html << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${ORG_NAME} — Employee Portal</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
           background: #f0f4f8; color: #1e293b; min-height: 100vh;
           display: flex; flex-direction: column; }

    /* Header */
    header { background: #1a3c5e; color: #fff; padding: 0 2rem; height: 64px;
             display: flex; align-items: center; justify-content: space-between;
             box-shadow: 0 2px 8px rgba(0,0,0,.3); position: sticky; top: 0; z-index: 100; }
    .header-left { display: flex; align-items: center; gap: 1rem; }
    .header-left img { height: 40px; width: auto; object-fit: contain; }
    .header-left .brand { display: flex; flex-direction: column; }
    .header-left .brand-name { font-size: 1.1rem; font-weight: 700; letter-spacing: .3px; }
    .header-left .brand-sub { font-size: .75rem; color: #93c5fd; letter-spacing: 1px; text-transform: uppercase; }
    .header-right { font-size: .85rem; color: #93c5fd; }

    /* Nav */
    nav { background: #15304d; border-bottom: 1px solid #0f2138; }
    nav ul { display: flex; list-style: none; padding: 0 2rem; gap: 0; }
    nav ul li a { display: block; padding: .75rem 1.25rem; color: #cbd5e1; font-size: .88rem;
                  text-decoration: none; transition: background .15s, color .15s; }
    nav ul li a:hover, nav ul li a.active { background: #1a3c5e; color: #fff; }

    /* Layout */
    .page-body { display: flex; flex: 1; max-width: 1280px; margin: 0 auto; width: 100%;
                 padding: 2rem 1.5rem; gap: 1.5rem; }
    .main-col { flex: 1; display: flex; flex-direction: column; gap: 1.5rem; }
    .sidebar { width: 300px; flex-shrink: 0; display: flex; flex-direction: column; gap: 1rem; }

    /* Hero */
    .hero { background: linear-gradient(135deg, #1a3c5e 0%, #2563eb 100%);
            border-radius: 12px; padding: 2.5rem 2rem; color: #fff; }
    .hero h1 { font-size: 1.75rem; font-weight: 700; margin-bottom: .5rem; }
    .hero p { color: #bfdbfe; font-size: 1rem; line-height: 1.6; }

    /* App Cards */
    .section-title { font-size: 1rem; font-weight: 700; color: #1e293b;
                     margin-bottom: 1rem; text-transform: uppercase; letter-spacing: .5px; }
    .app-grid { display: grid; grid-template-columns: repeat(2, 1fr); gap: 1rem; }
    .app-card { background: #fff; border-radius: 10px; padding: 1.25rem;
                border: 1px solid #e2e8f0; text-decoration: none; color: inherit;
                display: flex; flex-direction: column; gap: .6rem;
                transition: box-shadow .2s, transform .2s; }
    .app-card:hover { box-shadow: 0 8px 24px rgba(0,0,0,.12); transform: translateY(-2px); }
    .app-icon { width: 48px; height: 48px; border-radius: 10px;
                display: flex; align-items: center; justify-content: center;
                font-size: 1.4rem; }
    .app-icon.purple { background: #ede9fe; }
    .app-icon.blue   { background: #dbeafe; }
    .app-icon.teal   { background: #ccfbf1; }
    .app-icon.amber  { background: #fef3c7; }
    .app-card h3 { font-size: .95rem; font-weight: 700; color: #1e293b; }
    .app-card p  { font-size: .82rem; color: #64748b; line-height: 1.5; }
    .app-card .arrow { font-size: .8rem; color: #2563eb; font-weight: 600; margin-top: auto; }

    /* Sidebar cards */
    .sidebar-card { background: #fff; border-radius: 10px; border: 1px solid #e2e8f0;
                    padding: 1.25rem; }
    .sidebar-card h3 { font-size: .9rem; font-weight: 700; color: #1e293b;
                       margin-bottom: 1rem; padding-bottom: .6rem;
                       border-bottom: 2px solid #e2e8f0; text-transform: uppercase;
                       letter-spacing: .4px; }
    .announce-item { padding: .7rem 0; border-bottom: 1px solid #f1f5f9; }
    .announce-item:last-child { border-bottom: none; padding-bottom: 0; }
    .announce-item .tag { display: inline-block; font-size: .68rem; font-weight: 700;
                          padding: .15rem .5rem; border-radius: 4px; margin-bottom: .3rem;
                          text-transform: uppercase; letter-spacing: .4px; }
    .tag-info { background: #dbeafe; color: #1d4ed8; }
    .tag-alert { background: #fef3c7; color: #92400e; }
    .tag-hr { background: #ede9fe; color: #6d28d9; }
    .announce-item p { font-size: .83rem; color: #334155; line-height: 1.5; }
    .announce-date { font-size: .75rem; color: #94a3b8; margin-top: .25rem; }

    .quick-links { display: flex; flex-direction: column; gap: .4rem; }
    .quick-link { display: flex; align-items: center; gap: .6rem; padding: .55rem .75rem;
                  border-radius: 6px; text-decoration: none; color: #334155;
                  font-size: .85rem; transition: background .15s; }
    .quick-link:hover { background: #f1f5f9; }
    .quick-link span.ql-icon { font-size: 1rem; }

    /* Footer */
    footer { background: #1a3c5e; color: #93c5fd; text-align: center;
             padding: 1rem 2rem; font-size: .8rem; margin-top: auto; }
  </style>
</head>
<body>

<header>
  <div class="header-left">
    <img src="assets/${LOGO_FILE}" alt="${ORG_NAME} Logo" />
    <div class="brand">
      <span class="brand-name">${ORG_NAME}</span>
      <span class="brand-sub">Employee Portal</span>
    </div>
  </div>
  <div class="header-right">Internal Use Only</div>
</header>

<nav>
  <ul>
    <li><a href="#" class="active">Home</a></li>
    <li><a href="#">Apps</a></li>
    <li><a href="http://servicedesk.${BASE_FQDN}">IT Support</a></li>
    <li><a href="http://hr.${BASE_FQDN}">Directory</a></li>
    <li><a href="#">Help</a></li>
  </ul>
</nav>

<div class="page-body">
  <div class="main-col">

    <div class="hero">
      <h1>Welcome to the ${ORG_NAME} Employee Portal</h1>
      <p>Your central hub for HR, CRM, IT Support, and company resources. Access all internal tools from one place.</p>
    </div>

    <div>
      <p class="section-title">Applications</p>
      <div class="app-grid">

        <a class="app-card" href="http://hr.${BASE_FQDN}">
          <div class="app-icon purple">👤</div>
          <h3>HR Portal</h3>
          <p>Manage time off, view pay stubs, update benefits, and access HR resources.</p>
          <span class="arrow">Open HR Portal →</span>
        </a>

        <a class="app-card" href="http://crm.${BASE_FQDN}">
          <div class="app-icon blue">📊</div>
          <h3>CRM Dashboard</h3>
          <p>Track deals, manage contacts, view pipeline performance, and forecast revenue.</p>
          <span class="arrow">Open CRM →</span>
        </a>

        <a class="app-card" href="http://servicedesk.${BASE_FQDN}">
          <div class="app-icon teal">🎫</div>
          <h3>IT Service Desk</h3>
          <p>Submit and track IT tickets, access the knowledge base, and request new equipment.</p>
          <span class="arrow">Open Service Desk →</span>
        </a>

        <a class="app-card" href="http://hr.${BASE_FQDN}">
          <div class="app-icon amber">📋</div>
          <h3>Employee Directory</h3>
          <p>Find colleagues, view org charts, and access team contact information.</p>
          <span class="arrow">Open Directory →</span>
        </a>

      </div>
    </div>

  </div><!-- /.main-col -->

  <aside class="sidebar">

    <div class="sidebar-card">
      <h3>Announcements</h3>
      <div class="announce-item">
        <span class="tag tag-alert">Action Required</span>
        <p>Open enrollment for benefits begins May 15. Update your selections by May 31.</p>
        <div class="announce-date">May 10, 2025</div>
      </div>
      <div class="announce-item">
        <span class="tag tag-hr">HR</span>
        <p>Q2 performance reviews are now open. Complete your self-assessment by June 30.</p>
        <div class="announce-date">May 1, 2025</div>
      </div>
      <div class="announce-item">
        <span class="tag tag-info">IT</span>
        <p>Scheduled maintenance this Saturday 2–4 AM. Email and VPN may be intermittently unavailable.</p>
        <div class="announce-date">Apr 28, 2025</div>
      </div>
    </div>

    <div class="sidebar-card">
      <h3>Quick Links</h3>
      <div class="quick-links">
        <a class="quick-link" href="http://hr.${BASE_FQDN}"><span class="ql-icon">🗓️</span> Request Time Off</a>
        <a class="quick-link" href="http://servicedesk.${BASE_FQDN}"><span class="ql-icon">🔑</span> Reset Password</a>
        <a class="quick-link" href="http://servicedesk.${BASE_FQDN}"><span class="ql-icon">🖥️</span> Order Equipment</a>
        <a class="quick-link" href="http://hr.${BASE_FQDN}"><span class="ql-icon">💰</span> View Pay Stubs</a>
        <a class="quick-link" href="http://crm.${BASE_FQDN}"><span class="ql-icon">📈</span> Sales Dashboard</a>
      </div>
    </div>

  </aside>
</div><!-- /.page-body -->

<footer>© 2025 ${ORG_NAME}. Internal use only.</footer>

</body>
</html>
HTMLEOF
success "apps/portal/index.html written."

# ---------------------------------------------------------------------------
# apps/hr/index.html
# ---------------------------------------------------------------------------
info "Writing apps/hr/index.html..."
cat > apps/hr/index.html << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${ORG_NAME} — HR Portal</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
           background: #f5f3ff; color: #1e293b; min-height: 100vh;
           display: flex; flex-direction: column; }

    /* Header */
    header { background: #4f46e5; color: #fff; padding: 0 2rem; height: 64px;
             display: flex; align-items: center; justify-content: space-between;
             box-shadow: 0 2px 8px rgba(0,0,0,.25); position: sticky; top: 0; z-index: 100; }
    .header-left { display: flex; align-items: center; gap: 1rem; }
    .header-left img { height: 40px; width: auto; object-fit: contain; }
    .brand-name { font-size: 1.1rem; font-weight: 700; }
    .brand-sub  { font-size: .75rem; color: #c7d2fe; letter-spacing: 1px; text-transform: uppercase; }
    .header-right { display: flex; align-items: center; gap: .75rem; }
    .avatar { width: 34px; height: 34px; border-radius: 50%; background: #818cf8;
              display: flex; align-items: center; justify-content: center;
              font-weight: 700; font-size: .85rem; }

    /* Top nav */
    nav { background: #4338ca; border-bottom: 1px solid #3730a3; overflow-x: auto; }
    nav ul { display: flex; list-style: none; padding: 0 2rem; white-space: nowrap; }
    nav ul li a { display: block; padding: .75rem 1.1rem; color: #c7d2fe; font-size: .87rem;
                  text-decoration: none; transition: background .15s, color .15s; border-bottom: 3px solid transparent; }
    nav ul li a:hover { color: #fff; background: rgba(255,255,255,.08); }
    nav ul li a.active { color: #fff; border-bottom-color: #a5b4fc; }

    /* Layout */
    .layout { display: flex; flex: 1; max-width: 1280px; margin: 0 auto; width: 100%; padding: 1.5rem; gap: 1.25rem; }

    /* Sidebar */
    .sidebar { width: 220px; flex-shrink: 0; background: #fff; border-radius: 10px;
               border: 1px solid #e0e7ff; padding: 1rem 0; display: flex; flex-direction: column;
               align-self: flex-start; }
    .sidebar-section { padding: .4rem 0; }
    .sidebar-label { font-size: .68rem; font-weight: 700; color: #818cf8; padding: .3rem 1.2rem .1rem;
                     text-transform: uppercase; letter-spacing: .6px; }
    .sidebar-link { display: flex; align-items: center; gap: .65rem; padding: .55rem 1.2rem;
                    color: #475569; font-size: .85rem; text-decoration: none; transition: background .15s; }
    .sidebar-link:hover, .sidebar-link.active { background: #ede9fe; color: #4f46e5; }
    .sidebar-link .s-icon { font-size: .95rem; width: 20px; text-align: center; }

    /* Main */
    .main { flex: 1; display: flex; flex-direction: column; gap: 1.25rem; }

    /* Welcome banner */
    .welcome { background: linear-gradient(135deg, #4f46e5 0%, #7c3aed 100%);
               color: #fff; border-radius: 10px; padding: 1.5rem 1.75rem;
               display: flex; justify-content: space-between; align-items: center; }
    .welcome h2 { font-size: 1.3rem; font-weight: 700; margin-bottom: .25rem; }
    .welcome p { font-size: .87rem; color: #c7d2fe; }
    .welcome .date { font-size: .8rem; color: #a5b4fc; }

    /* Stats row */
    .stats-row { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; }
    .stat-card { background: #fff; border-radius: 10px; border: 1px solid #e0e7ff;
                 padding: 1.1rem 1.25rem; display: flex; flex-direction: column; gap: .3rem; }
    .stat-label { font-size: .75rem; color: #6366f1; font-weight: 600; text-transform: uppercase; letter-spacing: .4px; }
    .stat-value { font-size: 1.6rem; font-weight: 700; color: #1e293b; }
    .stat-note  { font-size: .78rem; color: #64748b; }

    /* Two-col grid */
    .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 1.25rem; }

    /* Cards */
    .card { background: #fff; border-radius: 10px; border: 1px solid #e0e7ff; padding: 1.25rem; }
    .card-title { font-size: .85rem; font-weight: 700; color: #4338ca; text-transform: uppercase;
                  letter-spacing: .5px; margin-bottom: 1rem; padding-bottom: .6rem;
                  border-bottom: 2px solid #e0e7ff; }

    /* Announce */
    .ann-item { display: flex; gap: .75rem; padding: .6rem 0; border-bottom: 1px solid #f1f5f9; }
    .ann-item:last-child { border-bottom: none; padding-bottom: 0; }
    .ann-dot { width: 8px; height: 8px; border-radius: 50%; background: #818cf8; margin-top: 5px; flex-shrink: 0; }
    .ann-title { font-size: .87rem; font-weight: 600; color: #1e293b; }
    .ann-date  { font-size: .75rem; color: #94a3b8; }

    /* Quick actions */
    .action-btn { display: flex; align-items: center; gap: .75rem; width: 100%; padding: .85rem 1rem;
                  border-radius: 8px; border: 1.5px solid #e0e7ff; background: #fff;
                  color: #4f46e5; font-size: .9rem; font-weight: 600; cursor: pointer;
                  text-decoration: none; transition: background .15s, border-color .15s; margin-bottom: .6rem; }
    .action-btn:hover { background: #ede9fe; border-color: #a5b4fc; }
    .action-btn .a-icon { font-size: 1.1rem; }
    .action-btn:last-child { margin-bottom: 0; }

    /* Birthdays */
    .bday-row { display: flex; align-items: center; gap: .75rem; padding: .55rem 0;
                border-bottom: 1px solid #f1f5f9; }
    .bday-row:last-child { border-bottom: none; }
    .bday-avatar { width: 32px; height: 32px; border-radius: 50%; background: #ede9fe;
                   display: flex; align-items: center; justify-content: center; font-size: .8rem; }
    .bday-name { font-size: .87rem; font-weight: 600; color: #1e293b; }
    .bday-sub  { font-size: .76rem; color: #94a3b8; }
    .bday-tag  { margin-left: auto; font-size: .72rem; padding: .2rem .55rem; border-radius: 4px;
                 font-weight: 700; }
    .tag-today { background: #fef3c7; color: #b45309; }
    .tag-soon  { background: #dbeafe; color: #1d4ed8; }

    /* Login widget */
    .login-card { background: #fff; border-radius: 10px; border: 1px solid #e0e7ff; padding: 1.5rem; }
    .login-card h3 { font-size: .9rem; font-weight: 700; color: #4338ca; margin-bottom: 1.1rem;
                     text-transform: uppercase; letter-spacing: .4px; }
    .form-group { margin-bottom: .85rem; }
    .form-group label { display: block; font-size: .8rem; font-weight: 600; color: #475569;
                        margin-bottom: .3rem; }
    .form-group input { width: 100%; padding: .6rem .8rem; border: 1.5px solid #e0e7ff;
                        border-radius: 6px; font-size: .87rem; color: #1e293b;
                        outline: none; transition: border-color .15s; }
    .form-group input:focus { border-color: #6366f1; }
    .btn-primary { width: 100%; padding: .7rem; background: #4f46e5; color: #fff; border: none;
                   border-radius: 6px; font-size: .9rem; font-weight: 700; cursor: pointer;
                   transition: background .15s; }
    .btn-primary:hover { background: #4338ca; }
    .login-note { font-size: .75rem; color: #94a3b8; text-align: center; margin-top: .6rem; }

    /* Footer */
    footer { background: #4f46e5; color: #c7d2fe; text-align: center;
             padding: 1rem 2rem; font-size: .8rem; margin-top: auto; }
  </style>
</head>
<body>

<header>
  <div class="header-left">
    <img src="assets/${LOGO_FILE}" alt="${ORG_NAME} Logo" />
    <div>
      <div class="brand-name">${ORG_NAME}</div>
      <div class="brand-sub">HR Portal</div>
    </div>
  </div>
  <div class="header-right">
    <span style="font-size:.85rem;color:#c7d2fe;">Jamie Williams</span>
    <div class="avatar">JW</div>
  </div>
</header>

<nav>
  <ul>
    <li><a href="#" class="active">Dashboard</a></li>
    <li><a href="#">My Info</a></li>
    <li><a href="#">Benefits</a></li>
    <li><a href="#">Time Off</a></li>
    <li><a href="#">Payroll</a></li>
    <li><a href="#">Team Directory</a></li>
    <li><a href="#">Performance</a></li>
    <li><a href="http://portal.${BASE_FQDN}" style="margin-left:auto;">← Back to Portal</a></li>
  </ul>
</nav>

<div class="layout">

  <!-- Sidebar -->
  <aside class="sidebar">
    <div class="sidebar-section">
      <div class="sidebar-label">My HR</div>
      <a class="sidebar-link active" href="#"><span class="s-icon">🏠</span> Dashboard</a>
      <a class="sidebar-link" href="#"><span class="s-icon">👤</span> My Profile</a>
      <a class="sidebar-link" href="#"><span class="s-icon">📄</span> Documents</a>
      <a class="sidebar-link" href="#"><span class="s-icon">⏰</span> Time Off</a>
      <a class="sidebar-link" href="#"><span class="s-icon">💳</span> Payroll</a>
    </div>
    <div class="sidebar-section">
      <div class="sidebar-label">Company</div>
      <a class="sidebar-link" href="#"><span class="s-icon">🏢</span> Org Chart</a>
      <a class="sidebar-link" href="#"><span class="s-icon">📋</span> Policies</a>
      <a class="sidebar-link" href="#"><span class="s-icon">🎯</span> Goals</a>
      <a class="sidebar-link" href="#"><span class="s-icon">📊</span> Reports</a>
    </div>
  </aside>

  <!-- Main content -->
  <main class="main">

    <div class="welcome">
      <div>
        <h2>Welcome back, Jamie 👋</h2>
        <p>Here's what's on your plate today.</p>
      </div>
      <div class="date">Friday, May 22, 2026</div>
    </div>

    <div class="stats-row">
      <div class="stat-card">
        <div class="stat-label">PTO Balance</div>
        <div class="stat-value">12</div>
        <div class="stat-note">Days remaining this year</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Next Payday</div>
        <div class="stat-value">Jun 1</div>
        <div class="stat-note">Direct deposit — checking</div>
      </div>
      <div class="stat-card">
        <div class="stat-label">Open Enrollment</div>
        <div class="stat-value">30</div>
        <div class="stat-note">Days left to update benefits</div>
      </div>
    </div>

    <div class="two-col">

      <div class="card">
        <div class="card-title">Recent Announcements</div>
        <div class="ann-item">
          <div class="ann-dot" style="background:#f59e0b;"></div>
          <div>
            <div class="ann-title">Open enrollment begins May 15</div>
            <div class="ann-date">Posted May 10, 2025 · HR Team</div>
          </div>
        </div>
        <div class="ann-item">
          <div class="ann-dot"></div>
          <div>
            <div class="ann-title">Q2 performance reviews due June 30</div>
            <div class="ann-date">Posted May 1, 2025 · People Ops</div>
          </div>
        </div>
        <div class="ann-item">
          <div class="ann-dot" style="background:#34d399;"></div>
          <div>
            <div class="ann-title">New EAP benefits effective June 1</div>
            <div class="ann-date">Posted Apr 25, 2025 · Benefits Team</div>
          </div>
        </div>
      </div>

      <div class="card">
        <div class="card-title">Quick Actions</div>
        <a class="action-btn" href="#"><span class="a-icon">🗓️</span> Request Time Off</a>
        <a class="action-btn" href="#"><span class="a-icon">💰</span> View Pay Stubs</a>
        <a class="action-btn" href="#"><span class="a-icon">🛡️</span> Update Benefits</a>
        <a class="action-btn" href="#"><span class="a-icon">📝</span> Submit Expense Report</a>
      </div>

    </div><!-- /.two-col -->

    <div class="two-col">

      <div class="card">
        <div class="card-title">🎂 Birthdays &amp; Anniversaries</div>
        <div class="bday-row">
          <div class="bday-avatar">🎂</div>
          <div>
            <div class="bday-name">Alex Chen</div>
            <div class="bday-sub">Engineering · Birthday</div>
          </div>
          <span class="bday-tag tag-today">Today!</span>
        </div>
        <div class="bday-row">
          <div class="bday-avatar">🎉</div>
          <div>
            <div class="bday-name">Maria Torres</div>
            <div class="bday-sub">Marketing · 5-Year Anniversary</div>
          </div>
          <span class="bday-tag tag-soon">May 24</span>
        </div>
        <div class="bday-row">
          <div class="bday-avatar">🎂</div>
          <div>
            <div class="bday-name">Ryan Patel</div>
            <div class="bday-sub">Sales · Birthday</div>
          </div>
          <span class="bday-tag tag-soon">May 27</span>
        </div>
      </div>

      <div class="login-card">
        <h3>🔒 Employee Sign In</h3>
        <div class="form-group">
          <label for="hr-email">Corporate Email</label>
          <input type="email" id="hr-email" placeholder="you@${DOMAIN}.${TLD}" />
        </div>
        <div class="form-group">
          <label for="hr-pass">Password</label>
          <input type="password" id="hr-pass" placeholder="••••••••" />
        </div>
        <button class="btn-primary">Sign In</button>
        <div class="login-note">Forgot password? Contact IT Service Desk</div>
      </div>

    </div><!-- /.two-col -->

  </main>

</div><!-- /.layout -->

<footer>© 2025 ${ORG_NAME}. Internal use only.</footer>

</body>
</html>
HTMLEOF
success "apps/hr/index.html written."

# ---------------------------------------------------------------------------
# apps/crm/index.html
# ---------------------------------------------------------------------------
info "Writing apps/crm/index.html..."
cat > apps/crm/index.html << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${ORG_NAME} — CRM</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
           background: #f0f4f8; color: #1e293b; min-height: 100vh; display: flex; flex-direction: column; }

    /* Header */
    header { background: #0070d2; color: #fff; padding: 0 2rem; height: 64px;
             display: flex; align-items: center; justify-content: space-between;
             box-shadow: 0 2px 8px rgba(0,0,0,.25); position: sticky; top: 0; z-index: 100; }
    .header-left { display: flex; align-items: center; gap: 1rem; }
    .header-left img { height: 40px; width: auto; object-fit: contain; }
    .brand-name { font-size: 1.1rem; font-weight: 700; }
    .brand-sub  { font-size: .75rem; color: #7dd3fc; letter-spacing: 1px; text-transform: uppercase; }
    .header-right { display: flex; align-items: center; gap: .75rem; font-size: .85rem; color: #bae6fd; }
    .avatar { width: 34px; height: 34px; border-radius: 50%; background: #0284c7;
              display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: .85rem; }

    /* Nav */
    nav { background: #005fb3; border-bottom: 1px solid #004d99; overflow-x: auto; }
    nav ul { display: flex; list-style: none; padding: 0 2rem; white-space: nowrap; }
    nav ul li a { display: block; padding: .75rem 1.1rem; color: #bae6fd; font-size: .87rem;
                  text-decoration: none; transition: background .15s, color .15s;
                  border-bottom: 3px solid transparent; }
    nav ul li a:hover { color: #fff; background: rgba(255,255,255,.1); }
    nav ul li a.active { color: #fff; border-bottom-color: #7dd3fc; }

    /* Layout */
    .layout { max-width: 1280px; margin: 0 auto; width: 100%; padding: 1.5rem; display: flex; flex-direction: column; gap: 1.25rem; flex: 1; }

    /* Stats row */
    .stats-row { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; }
    .stat-card { background: #fff; border-radius: 10px; border: 1px solid #e2e8f0;
                 padding: 1.1rem 1.25rem; }
    .stat-label { font-size: .73rem; font-weight: 700; color: #0070d2; text-transform: uppercase; letter-spacing: .4px; margin-bottom: .35rem; }
    .stat-value { font-size: 1.8rem; font-weight: 800; color: #1e293b; margin-bottom: .2rem; }
    .stat-delta { font-size: .78rem; }
    .delta-up   { color: #16a34a; }
    .delta-down { color: #dc2626; }

    /* Two-col */
    .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 1.25rem; }

    /* Cards */
    .card { background: #fff; border-radius: 10px; border: 1px solid #e2e8f0; padding: 1.25rem; }
    .card-title { font-size: .85rem; font-weight: 700; color: #0070d2; text-transform: uppercase;
                  letter-spacing: .5px; margin-bottom: 1rem; padding-bottom: .6rem;
                  border-bottom: 2px solid #e2e8f0; display: flex; justify-content: space-between; align-items: center; }
    .card-title span { font-size: .75rem; color: #64748b; font-weight: 500; text-transform: none; letter-spacing: 0; }

    /* Activity feed */
    .activity-item { display: flex; gap: .75rem; padding: .65rem 0; border-bottom: 1px solid #f1f5f9; align-items: flex-start; }
    .activity-item:last-child { border-bottom: none; padding-bottom: 0; }
    .act-icon { width: 34px; height: 34px; border-radius: 50%; display: flex; align-items: center;
                justify-content: center; font-size: .9rem; flex-shrink: 0; }
    .act-green  { background: #dcfce7; }
    .act-blue   { background: #dbeafe; }
    .act-yellow { background: #fef3c7; }
    .act-purple { background: #ede9fe; }
    .act-red    { background: #fee2e2; }
    .act-body   { flex: 1; }
    .act-title  { font-size: .87rem; font-weight: 600; color: #1e293b; margin-bottom: .15rem; }
    .act-time   { font-size: .75rem; color: #94a3b8; }

    /* Table */
    table { width: 100%; border-collapse: collapse; font-size: .85rem; }
    thead th { text-align: left; padding: .5rem .75rem; color: #64748b; font-weight: 600;
               font-size: .75rem; text-transform: uppercase; letter-spacing: .4px;
               border-bottom: 2px solid #e2e8f0; }
    tbody td { padding: .65rem .75rem; border-bottom: 1px solid #f1f5f9; color: #334155; vertical-align: middle; }
    tbody tr:last-child td { border-bottom: none; }
    tbody tr:hover td { background: #f8fafc; }
    .badge { display: inline-block; font-size: .72rem; font-weight: 700; padding: .2rem .55rem;
             border-radius: 20px; text-transform: uppercase; letter-spacing: .3px; }
    .badge-blue   { background: #dbeafe; color: #1d4ed8; }
    .badge-yellow { background: #fef3c7; color: #b45309; }
    .badge-green  { background: #dcfce7; color: #166534; }
    .badge-purple { background: #ede9fe; color: #6d28d9; }
    .badge-red    { background: #fee2e2; color: #991b1b; }

    /* Pipeline */
    .pipeline { display: flex; flex-direction: column; gap: .65rem; }
    .pipeline-row { display: flex; align-items: center; gap: .75rem; }
    .pipeline-label { width: 120px; font-size: .82rem; color: #475569; flex-shrink: 0; }
    .pipeline-bar-wrap { flex: 1; background: #f1f5f9; border-radius: 20px; height: 20px; overflow: hidden; }
    .pipeline-bar { height: 100%; border-radius: 20px; display: flex; align-items: center;
                    padding-left: .5rem; font-size: .72rem; font-weight: 700; color: #fff; }
    .pipeline-count { width: 40px; text-align: right; font-size: .82rem; font-weight: 700; color: #1e293b; }

    /* Footer */
    footer { background: #0070d2; color: #bae6fd; text-align: center;
             padding: 1rem 2rem; font-size: .8rem; margin-top: auto; }
  </style>
</head>
<body>

<header>
  <div class="header-left">
    <img src="assets/${LOGO_FILE}" alt="${ORG_NAME} Logo" />
    <div>
      <div class="brand-name">${ORG_NAME}</div>
      <div class="brand-sub">CRM</div>
    </div>
  </div>
  <div class="header-right">
    <span>Taylor Brooks</span>
    <div class="avatar">TB</div>
  </div>
</header>

<nav>
  <ul>
    <li><a href="#" class="active">Home</a></li>
    <li><a href="#">Contacts</a></li>
    <li><a href="#">Accounts</a></li>
    <li><a href="#">Opportunities</a></li>
    <li><a href="#">Reports</a></li>
    <li><a href="#">Forecasting</a></li>
    <li><a href="#">Dashboards</a></li>
    <li><a href="http://portal.${BASE_FQDN}" style="margin-left:auto;">← Back to Portal</a></li>
  </ul>
</nav>

<div class="layout">

  <!-- Stats -->
  <div class="stats-row">
    <div class="stat-card">
      <div class="stat-label">Open Deals</div>
      <div class="stat-value">142</div>
      <div class="stat-delta delta-up">▲ 8 from last month</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Pipeline Value</div>
      <div class="stat-value">\$1.24M</div>
      <div class="stat-delta delta-up">▲ \$128K from last month</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Won This Month</div>
      <div class="stat-value">18</div>
      <div class="stat-delta delta-down">▼ 3 from last month</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Win Rate</div>
      <div class="stat-value">64%</div>
      <div class="stat-delta delta-up">▲ 2% from last month</div>
    </div>
  </div>

  <!-- Activity + Top Deals -->
  <div class="two-col">

    <div class="card">
      <div class="card-title">Recent Activity <span>Last 48 hours</span></div>
      <div class="activity-item">
        <div class="act-icon act-green">🏆</div>
        <div class="act-body">
          <div class="act-title">Deal closed: Apex Technologies — \$45,000</div>
          <div class="act-time">2 hours ago · Sam Rivera</div>
        </div>
      </div>
      <div class="activity-item">
        <div class="act-icon act-blue">👤</div>
        <div class="act-body">
          <div class="act-title">New contact: Sarah Johnson at Nexus Corp</div>
          <div class="act-time">4 hours ago · Dana Kim</div>
        </div>
      </div>
      <div class="activity-item">
        <div class="act-icon act-yellow">📅</div>
        <div class="act-body">
          <div class="act-title">Meeting scheduled: Pinnacle Group — Q2 Review</div>
          <div class="act-time">Yesterday · Taylor Brooks</div>
        </div>
      </div>
      <div class="activity-item">
        <div class="act-icon act-purple">📝</div>
        <div class="act-body">
          <div class="act-title">Proposal sent: Vertex Solutions — \$82,500</div>
          <div class="act-time">Yesterday · Morgan Osei</div>
        </div>
      </div>
      <div class="activity-item">
        <div class="act-icon act-red">⚠️</div>
        <div class="act-body">
          <div class="act-title">Deal at risk: Orion Dynamics — contract review delayed</div>
          <div class="act-time">2 days ago · Sam Rivera</div>
        </div>
      </div>
    </div>

    <div class="card">
      <div class="card-title">Top Deals <span>By pipeline value</span></div>
      <table>
        <thead>
          <tr>
            <th>Account</th>
            <th>Value</th>
            <th>Stage</th>
            <th>Close Date</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td><strong>Orion Dynamics</strong></td>
            <td>\$210,000</td>
            <td><span class="badge badge-yellow">Negotiation</span></td>
            <td>Jun 15</td>
          </tr>
          <tr>
            <td><strong>Vertex Solutions</strong></td>
            <td>\$182,500</td>
            <td><span class="badge badge-purple">Proposal</span></td>
            <td>Jun 30</td>
          </tr>
          <tr>
            <td><strong>Pinnacle Group</strong></td>
            <td>\$135,000</td>
            <td><span class="badge badge-blue">Qualification</span></td>
            <td>Jul 10</td>
          </tr>
          <tr>
            <td><strong>Nexus Corp</strong></td>
            <td>\$97,000</td>
            <td><span class="badge badge-purple">Proposal</span></td>
            <td>Jul 22</td>
          </tr>
          <tr>
            <td><strong>Apex Technologies</strong></td>
            <td>\$45,000</td>
            <td><span class="badge badge-green">Closed Won</span></td>
            <td>May 20</td>
          </tr>
        </tbody>
      </table>
    </div>

  </div><!-- /.two-col -->

  <!-- Pipeline -->
  <div class="card">
    <div class="card-title">Pipeline by Stage</div>
    <div class="pipeline">
      <div class="pipeline-row">
        <div class="pipeline-label">Prospecting</div>
        <div class="pipeline-bar-wrap"><div class="pipeline-bar" style="width:85%;background:#0070d2;">85%</div></div>
        <div class="pipeline-count">48</div>
      </div>
      <div class="pipeline-row">
        <div class="pipeline-label">Qualification</div>
        <div class="pipeline-bar-wrap"><div class="pipeline-bar" style="width:65%;background:#2563eb;">65%</div></div>
        <div class="pipeline-count">36</div>
      </div>
      <div class="pipeline-row">
        <div class="pipeline-label">Proposal</div>
        <div class="pipeline-bar-wrap"><div class="pipeline-bar" style="width:45%;background:#7c3aed;">45%</div></div>
        <div class="pipeline-count">26</div>
      </div>
      <div class="pipeline-row">
        <div class="pipeline-label">Negotiation</div>
        <div class="pipeline-bar-wrap"><div class="pipeline-bar" style="width:28%;background:#d97706;">28%</div></div>
        <div class="pipeline-count">14</div>
      </div>
      <div class="pipeline-row">
        <div class="pipeline-label">Closed Won</div>
        <div class="pipeline-bar-wrap"><div class="pipeline-bar" style="width:18%;background:#16a34a;">18%</div></div>
        <div class="pipeline-count">18</div>
      </div>
    </div>
  </div>

</div><!-- /.layout -->

<footer>© 2025 ${ORG_NAME}. Internal use only.</footer>

</body>
</html>
HTMLEOF
success "apps/crm/index.html written."

# ---------------------------------------------------------------------------
# apps/servicedesk/index.html
# ---------------------------------------------------------------------------
info "Writing apps/servicedesk/index.html..."
cat > apps/servicedesk/index.html << HTMLEOF
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>${ORG_NAME} — IT Service Desk</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
           background: #f0fdfb; color: #1e293b; min-height: 100vh; display: flex; flex-direction: column; }

    /* Header */
    header { background: #0f766e; color: #fff; padding: 0 2rem; height: 64px;
             display: flex; align-items: center; justify-content: space-between;
             box-shadow: 0 2px 8px rgba(0,0,0,.25); position: sticky; top: 0; z-index: 100; }
    .header-left { display: flex; align-items: center; gap: 1rem; }
    .header-left img { height: 40px; width: auto; object-fit: contain; }
    .brand-name { font-size: 1.1rem; font-weight: 700; }
    .brand-sub  { font-size: .75rem; color: #99f6e4; letter-spacing: 1px; text-transform: uppercase; }
    .header-right { display: flex; align-items: center; gap: .75rem; font-size: .85rem; color: #99f6e4; }
    .avatar { width: 34px; height: 34px; border-radius: 50%; background: #0d9488;
              display: flex; align-items: center; justify-content: center; font-weight: 700; font-size: .85rem; }

    /* Nav */
    nav { background: #0d5c56; border-bottom: 1px solid #0a4a45; overflow-x: auto; }
    nav ul { display: flex; list-style: none; padding: 0 2rem; white-space: nowrap; }
    nav ul li a { display: block; padding: .75rem 1.1rem; color: #99f6e4; font-size: .87rem;
                  text-decoration: none; transition: background .15s, color .15s;
                  border-bottom: 3px solid transparent; }
    nav ul li a:hover { color: #fff; background: rgba(255,255,255,.1); }
    nav ul li a.active { color: #fff; border-bottom-color: #2dd4bf; }

    /* Layout */
    .layout { max-width: 1280px; margin: 0 auto; width: 100%;
              padding: 1.5rem; display: flex; flex-direction: column; gap: 1.25rem; flex: 1; }

    /* Stats */
    .stats-row { display: grid; grid-template-columns: repeat(4, 1fr); gap: 1rem; }
    .stat-card { background: #fff; border-radius: 10px; border: 1px solid #ccfbf1;
                 padding: 1.1rem 1.25rem; }
    .stat-label { font-size: .73rem; font-weight: 700; color: #0f766e; text-transform: uppercase;
                  letter-spacing: .4px; margin-bottom: .35rem; }
    .stat-value { font-size: 1.8rem; font-weight: 800; color: #1e293b; margin-bottom: .2rem; }
    .stat-note  { font-size: .78rem; color: #64748b; }

    /* Two col */
    .two-col { display: grid; grid-template-columns: 1fr 1fr; gap: 1.25rem; }

    /* Cards */
    .card { background: #fff; border-radius: 10px; border: 1px solid #ccfbf1; padding: 1.25rem; }
    .card-title { font-size: .85rem; font-weight: 700; color: #0f766e; text-transform: uppercase;
                  letter-spacing: .5px; margin-bottom: 1rem; padding-bottom: .6rem;
                  border-bottom: 2px solid #ccfbf1; }

    /* Form */
    .form-group { margin-bottom: .9rem; }
    .form-group label { display: block; font-size: .8rem; font-weight: 600;
                        color: #475569; margin-bottom: .3rem; }
    .form-group input,
    .form-group select,
    .form-group textarea { width: 100%; padding: .6rem .8rem; border: 1.5px solid #ccfbf1;
                            border-radius: 6px; font-size: .87rem; color: #1e293b;
                            outline: none; transition: border-color .15s;
                            font-family: inherit; background: #fff; }
    .form-group input:focus,
    .form-group select:focus,
    .form-group textarea:focus { border-color: #0d9488; }
    .form-group textarea { resize: vertical; min-height: 90px; }
    .btn-submit { width: 100%; padding: .75rem; background: #0f766e; color: #fff; border: none;
                  border-radius: 6px; font-size: .9rem; font-weight: 700; cursor: pointer;
                  transition: background .15s; }
    .btn-submit:hover { background: #0d6660; }

    /* Ticket table */
    table { width: 100%; border-collapse: collapse; font-size: .84rem; }
    thead th { text-align: left; padding: .5rem .75rem; color: #64748b; font-weight: 600;
               font-size: .75rem; text-transform: uppercase; letter-spacing: .4px;
               border-bottom: 2px solid #e2e8f0; }
    tbody td { padding: .65rem .75rem; border-bottom: 1px solid #f1f5f9; color: #334155; vertical-align: middle; }
    tbody tr:last-child td { border-bottom: none; }
    tbody tr:hover td { background: #f0fdfb; }

    .badge { display: inline-block; font-size: .72rem; font-weight: 700; padding: .2rem .55rem;
             border-radius: 20px; text-transform: uppercase; letter-spacing: .3px; }
    .badge-open     { background: #dbeafe; color: #1d4ed8; }
    .badge-progress { background: #fef3c7; color: #b45309; }
    .badge-resolved { background: #dcfce7; color: #166534; }
    .badge-closed   { background: #f1f5f9; color: #64748b; }
    .badge-critical { background: #fee2e2; color: #991b1b; }

    /* KB links */
    .kb-grid { display: flex; flex-direction: column; gap: .4rem; }
    .kb-link { display: flex; align-items: center; gap: .65rem; padding: .6rem .75rem;
               border-radius: 6px; text-decoration: none; color: #334155; font-size: .87rem;
               background: #f0fdfb; border: 1px solid #ccfbf1; transition: background .15s; }
    .kb-link:hover { background: #ccfbf1; }
    .kb-icon { font-size: 1rem; }
    .kb-link-arrow { margin-left: auto; color: #0d9488; font-size: .8rem; }

    /* Footer */
    footer { background: #0f766e; color: #99f6e4; text-align: center;
             padding: 1rem 2rem; font-size: .8rem; margin-top: auto; }
  </style>
</head>
<body>

<header>
  <div class="header-left">
    <img src="assets/${LOGO_FILE}" alt="${ORG_NAME} Logo" />
    <div>
      <div class="brand-name">${ORG_NAME}</div>
      <div class="brand-sub">IT Service Desk</div>
    </div>
  </div>
  <div class="header-right">
    <span>Chris Nakamura</span>
    <div class="avatar">CN</div>
  </div>
</header>

<nav>
  <ul>
    <li><a href="#" class="active">My Tickets</a></li>
    <li><a href="#">New Request</a></li>
    <li><a href="#">Knowledge Base</a></li>
    <li><a href="#">Asset Inventory</a></li>
    <li><a href="#">Reports</a></li>
    <li><a href="#">Admin</a></li>
    <li><a href="http://portal.${BASE_FQDN}" style="margin-left:auto;">← Back to Portal</a></li>
  </ul>
</nav>

<div class="layout">

  <!-- Stats -->
  <div class="stats-row">
    <div class="stat-card">
      <div class="stat-label">Open Tickets</div>
      <div class="stat-value">23</div>
      <div class="stat-note">Across all categories</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">In Progress</div>
      <div class="stat-value">8</div>
      <div class="stat-note">Assigned to technicians</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Resolved Today</div>
      <div class="stat-value">12</div>
      <div class="stat-note">Since midnight</div>
    </div>
    <div class="stat-card">
      <div class="stat-label">Avg Response</div>
      <div class="stat-value">2.4h</div>
      <div class="stat-note">Last 7 days</div>
    </div>
  </div>

  <!-- Submit + My Tickets -->
  <div class="two-col">

    <div class="card">
      <div class="card-title">🎫 Submit a Ticket</div>
      <div class="form-group">
        <label for="sd-subject">Subject</label>
        <input type="text" id="sd-subject" placeholder="Brief description of the issue" />
      </div>
      <div class="form-group">
        <label for="sd-category">Category</label>
        <select id="sd-category">
          <option value="">— Select a category —</option>
          <option>Hardware</option>
          <option>Software</option>
          <option>Network</option>
          <option>Access</option>
          <option>Other</option>
        </select>
      </div>
      <div class="form-group">
        <label for="sd-priority">Priority</label>
        <select id="sd-priority">
          <option value="">— Select priority —</option>
          <option>Low</option>
          <option>Medium</option>
          <option>High</option>
          <option>Critical</option>
        </select>
      </div>
      <div class="form-group">
        <label for="sd-desc">Description</label>
        <textarea id="sd-desc" placeholder="Please describe the issue in detail. Include any error messages, steps to reproduce, and business impact."></textarea>
      </div>
      <button class="btn-submit">Submit Ticket</button>
    </div>

    <div class="card">
      <div class="card-title">📋 My Recent Tickets</div>
      <table>
        <thead>
          <tr>
            <th>Ticket #</th>
            <th>Title</th>
            <th>Status</th>
            <th>Date</th>
          </tr>
        </thead>
        <tbody>
          <tr>
            <td style="font-family:monospace;font-size:.82rem;color:#0f766e;">INC0012847</td>
            <td>Laptop screen flickering</td>
            <td><span class="badge badge-progress">In Progress</span></td>
            <td>May 21</td>
          </tr>
          <tr>
            <td style="font-family:monospace;font-size:.82rem;color:#0f766e;">INC0012801</td>
            <td>Unable to connect to VPN</td>
            <td><span class="badge badge-resolved">Resolved</span></td>
            <td>May 19</td>
          </tr>
          <tr>
            <td style="font-family:monospace;font-size:.82rem;color:#0f766e;">INC0012766</td>
            <td>Outlook not syncing calendar</td>
            <td><span class="badge badge-resolved">Resolved</span></td>
            <td>May 15</td>
          </tr>
          <tr>
            <td style="font-family:monospace;font-size:.82rem;color:#0f766e;">INC0012740</td>
            <td>Request new monitor</td>
            <td><span class="badge badge-open">Open</span></td>
            <td>May 12</td>
          </tr>
          <tr>
            <td style="font-family:monospace;font-size:.82rem;color:#0f766e;">INC0012698</td>
            <td>Printer driver install</td>
            <td><span class="badge badge-closed">Closed</span></td>
            <td>May 8</td>
          </tr>
        </tbody>
      </table>
    </div>

  </div><!-- /.two-col -->

  <!-- Knowledge Base -->
  <div class="card">
    <div class="card-title">📚 Knowledge Base — Quick Answers</div>
    <div class="kb-grid">
      <a class="kb-link" href="#">
        <span class="kb-icon">🔐</span>
        VPN Setup Guide — Windows, Mac, and Linux
        <span class="kb-link-arrow">→</span>
      </a>
      <a class="kb-link" href="#">
        <span class="kb-icon">🔑</span>
        Password Reset Instructions — Self-Service Portal
        <span class="kb-link-arrow">→</span>
      </a>
      <a class="kb-link" href="#">
        <span class="kb-icon">🆕</span>
        New Employee Onboarding Checklist — IT Setup
        <span class="kb-link-arrow">→</span>
      </a>
      <a class="kb-link" href="#">
        <span class="kb-icon">🖨️</span>
        Printer Setup and Troubleshooting Guide
        <span class="kb-link-arrow">→</span>
      </a>
      <a class="kb-link" href="#">
        <span class="kb-icon">📧</span>
        Email Configuration — Outlook, Apple Mail, Mobile
        <span class="kb-link-arrow">→</span>
      </a>
      <a class="kb-link" href="#">
        <span class="kb-icon">💻</span>
        Software Approved List and Installation Requests
        <span class="kb-link-arrow">→</span>
      </a>
    </div>
  </div>

</div><!-- /.layout -->

<footer>© 2025 ${ORG_NAME}. Internal use only.</footer>

</body>
</html>
HTMLEOF
success "apps/servicedesk/index.html written."

# ---------------------------------------------------------------------------
# Deploy
# ---------------------------------------------------------------------------
header "Deploying with Docker Compose"

cd "${SCRIPT_DIR}"

# Idempotency: bring down existing containers
if ${COMPOSE_CMD} ps -q 2>/dev/null | grep -q .; then
    info "Stopping existing containers..."
    ${COMPOSE_CMD} down
fi

info "Pulling latest images and starting services..."
${COMPOSE_CMD} up -d || die "docker compose up failed."

echo ""
echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║         ✓  Enterprise Demo Suite is Running!                    ║${NC}"
echo -e "${GREEN}${BOLD}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}${BOLD}║                                                                  ║${NC}"
printf "${GREEN}${BOLD}║${NC}  %-18s  ${CYAN}http://portal.${BASE_FQDN}${NC}\n" "Portal:"
printf "${GREEN}${BOLD}║${NC}  %-18s  ${CYAN}http://hr.${BASE_FQDN}${NC}\n" "HR Portal:"
printf "${GREEN}${BOLD}║${NC}  %-18s  ${CYAN}http://crm.${BASE_FQDN}${NC}\n" "CRM:"
printf "${GREEN}${BOLD}║${NC}  %-18s  ${CYAN}http://servicedesk.${BASE_FQDN}${NC}\n" "Service Desk:"
echo -e "${GREEN}${BOLD}║                                                                  ║${NC}"
echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
info "Make sure the DNS records listed earlier are configured."
info "Run '${COMPOSE_CMD} logs -f' to follow container logs."
info "Run '${COMPOSE_CMD} down' to stop all services."
