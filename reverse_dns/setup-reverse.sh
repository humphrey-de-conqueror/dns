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
read -rp "Domain name [example.com]: " DOMAIN
DOMAIN="${DOMAIN:-example.com}"

read -rp "DNS forwarder [8.8.8.8]: " FORWARDER
FORWARDER="${FORWARDER:-8.8.8.8}"

read -rp "Nameserver hostname [ns1]: " NS_HOST
NS_HOST="${NS_HOST:-ns1}"

# ---------- derive reverse zone ----------------------------------------------
# e.g. 192.168.122.1 -> 122.168.192.in-addr.arpa
REVERSE_ZONE=$(echo "${SERVER_IP}" | awk -F. '{print $3"."$2"."$1".in-addr.arpa"}')

# last octet used in PTR record
# e.g. 192.168.122.1 -> 1
LAST_OCTET=$(echo "${SERVER_IP}" | awk -F. '{print $4}')

ZONE_FILE="/etc/bind/db.${REVERSE_ZONE}"

info "Reverse zone : ${REVERSE_ZONE}"
info "Zone file    : ${ZONE_FILE}"

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

# named.conf.options: identical to forward — global options do not change
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

# named.conf.local: append reverse zone — do not overwrite forward zone
# if it already exists, skip to avoid duplicate declarations
info "Updating named.conf.local..."
if grep -q "${REVERSE_ZONE}" /etc/bind/named.conf.local 2>/dev/null; then
    warn "Reverse zone ${REVERSE_ZONE} already declared in named.conf.local, skipping."
else
    cat >> /etc/bind/named.conf.local << EOF

zone "${REVERSE_ZONE}" {
    type master;
    file "${ZONE_FILE}";
};
EOF
    success "Reverse zone appended to named.conf.local."
fi

# reverse zone file — SOA, NS, and one PTR for the nameserver itself
# manage-reverse.sh will populate additional PTR entries later
info "Writing reverse zone file..."
cat > "${ZONE_FILE}" << EOF
\$ORIGIN ${REVERSE_ZONE}.
\$TTL 604800

@   IN  SOA ${NS_HOST}.${DOMAIN}. admin.${DOMAIN}. (
            $(date +%Y%m%d)01  ; Serial
            604800             ; Refresh
            86400              ; Retry
            2419200            ; Expire
            604800 )           ; Negative Cache TTL

@               IN  NS   ${NS_HOST}.${DOMAIN}.
${LAST_OCTET}   IN  PTR  ${NS_HOST}.${DOMAIN}.
EOF

# ---------- validate ---------------------------------------------------------
info "Validating named.conf..."
if ! named-checkconf; then
    die "named.conf validation failed. Fix the config before proceeding."
fi
success "named.conf looks good."

info "Validating reverse zone file..."
if ! named-checkzone "${REVERSE_ZONE}" "${ZONE_FILE}"; then
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

# ---------- verify -----------------------------------------------------------
info "Verifying reverse DNS resolution..."

# give BIND9 a moment to fully load the zone
sleep 2

RESULT=$(dig @"${SERVER_IP}" -x "${SERVER_IP}" +short)

if [[ -z "${RESULT}" ]]; then
    die "Reverse DNS query returned no result. Check journalctl -u named for details."
fi
success "Reverse DNS working — ${SERVER_IP} resolves to ${RESULT}"

# ---------- closing banner ---------------------------------------------------
echo ""
echo "${BOLD}${GREEN}============================================${NC}"
echo "${BOLD}${GREEN}  BIND9 Reverse Zone Setup Complete!${NC}"
echo "${BOLD}${GREEN}============================================${NC}"
echo ""
info "Domain        : ${DOMAIN}"
info "Server IP     : ${SERVER_IP}"
info "Reverse zone  : ${REVERSE_ZONE}"
info "Nameserver    : ${NS_HOST}.${DOMAIN}"
info "Forwarder     : ${FORWARDER}"
info "Zone file     : ${ZONE_FILE}"
echo ""
warn "Add PTR entries    : sudo bash manage-reverse.sh"
warn "Check logs         : journalctl -u named -f"
warn "Check config       : named-checkconf"