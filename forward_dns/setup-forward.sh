#!/usr/bin/env bash

set -euo pipefail
# -e          : exit on error
# -u          : treat unset variable as error
# -o pipefail : if a pipe fails, whole program fails

# colours
RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
YELLOW=$(tput setaf 3)
CYAN=$(tput setaf 6)
BOLD=$(tput bold)
NC=$(tput sgr0)

info()    { echo "${CYAN}[*]${NC} $*"; }
success() { echo "${GREEN}[+]${NC} $*"; }
warn()    { echo "${YELLOW}[!]${NC} $*"; }
die()     { echo "${RED}[-] ERROR:${NC} $*" >&2; exit 1; }

# ---------- root check -------------------------------------------------------
[[ $EUID -ne 0 ]] && die "Run this script as root (sudo)."

# ---------- user input -------------------------------------------------------

# compulsory — no default
read -rp "Server IP: " SERVER_IP
[[ -z "${SERVER_IP}" ]] && die "Server IP is required."

# verify IP actually exists on this machine
if ! ip addr show | grep -q "${SERVER_IP}"; then
    die "IP ${SERVER_IP} not found on any interface of this machine."
fi

# optional — sensible defaults
read -rp "Domain name [dns-local]: " DOMAIN
DOMAIN="${DOMAIN:-dns-local}"

read -rp "DNS forwarder [8.8.8.8]: " FORWARDER
FORWARDER="${FORWARDER:-8.8.8.8}"

read -rp "Nameserver hostname [ns1]: " NS_HOST
NS_HOST="${NS_HOST:-ns1}"

ZONE_FILE="/etc/bind/db.${DOMAIN}"

# ---------- install ----------------------------------------------------------
info "Updating package index..."
apt-get update -qq

info "Installing BIND9..."
apt-get install -y -qq bind9 bind9utils bind9-doc dnsutils

if ! command -v named &>/dev/null; then
    die "BIND9 installation failed — 'named' not found."
fi
success "BIND9 installed successfully."

# ---------- write config files -----------------------------------------------

# named.conf.options: global options - forwarders, recursion, listen address
info "Writing named.conf.options..."
cat > /etc/bind/named.conf.options << EOF
options {
    directory "/var/cache/bind";

    forwarders {
        ${FORWARDER};
    };

    dnssec-validation auto;
    listen-on { ${SERVER_IP}; };
    allow-query { any; };
    recursion yes;
};
EOF

# named.conf.local: append forward zone — do not overwrite existing declarations
# guards against wiping reverse zone if setup-reverse.sh was run first
info "Updating named.conf.local..."
if grep -q "\"${DOMAIN}\"" /etc/bind/named.conf.local 2>/dev/null; then
    warn "Zone ${DOMAIN} already declared in named.conf.local, skipping."
else
    cat >> /etc/bind/named.conf.local << EOF

zone "${DOMAIN}" {
    type master;
    file "${ZONE_FILE}";
};
EOF
    success "Forward zone appended to named.conf.local."
fi

# bare zone file — SOA, NS, and glue A record for nameserver
# manage.sh will populate additional entries later
info "Writing zone file..."
cat > "${ZONE_FILE}" << EOF
\$ORIGIN ${DOMAIN}.
\$TTL 604800

@   IN  SOA ${NS_HOST}.${DOMAIN}. admin.${DOMAIN}. (
            $(date +%Y%m%d)01  ; Serial
            604800             ; Refresh
            86400              ; Retry
            2419200            ; Expire
            604800 )           ; Negative Cache TTL

@           IN  NS  ${NS_HOST}.${DOMAIN}.
${NS_HOST}  IN  A   ${SERVER_IP}
EOF

# ---------- validate ---------------------------------------------------------
info "Validating named.conf..."
if ! named-checkconf; then
    die "named.conf validation failed. Fix the config before proceeding."
fi
success "named.conf looks good."

info "Validating zone file..."
if ! named-checkzone "${DOMAIN}" "${ZONE_FILE}"; then
    die "Zone file validation failed. Fix the zone file before proceeding."
fi
success "Zone file looks good."

# ---------- enable and start -------------------------------------------------
info "Enabling and starting BIND9..."
systemctl enable --now named
success "BIND9 enabled and started."

info "Checking service status..."
if ! systemctl is-active --quiet named; then
    die "BIND9 failed to start. Run 'systemctl status named' for details."
fi
success "BIND9 is running."

# ---------- closing banner ---------------------------------------------------
echo ""
echo "${BOLD}${GREEN}============================================${NC}"
echo "${BOLD}${GREEN}  BIND9 Forward Zone Setup Complete!${NC}"
echo "${BOLD}${GREEN}============================================${NC}"
echo ""
info "Domain      : ${DOMAIN}"
info "Server IP   : ${SERVER_IP}"
info "Nameserver  : ${NS_HOST}.${DOMAIN}"
info "Forwarder   : ${FORWARDER}"
info "Zone file   : ${ZONE_FILE}"
echo ""
warn "Add DNS entries    : sudo bash manage.sh"
warn "Check logs         : journalctl -u named -f"
warn "Check config       : named-checkconf"