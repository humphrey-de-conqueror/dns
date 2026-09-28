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

# ---------- read reverse zone from existing config ---------------------------
# lookahead ensures we only match the in-addr.arpa zone, not the forward zone
REVERSE_ZONE=$(grep -oP 'zone "\K[^"]+' /etc/bind/named.conf.local | grep "in-addr.arpa") \
    || die "Could not read reverse zone from named.conf.local. Run setup-reverse.sh first."

ZONE_FILE="/etc/bind/db.${REVERSE_ZONE}"

# derive network prefix for IP validation
# e.g. 0.168.192.in-addr.arpa -> 192.168.0.
PREFIX=$(echo "${REVERSE_ZONE}" | awk -F. '{print $3"."$2"."$1"."}')

# ---------- preflight checks -------------------------------------------------
command -v named &>/dev/null      || die "BIND9 not installed. Run setup-reverse.sh first."
[[ -f "${ZONE_FILE}" ]]           || die "Zone file not found. Run setup-reverse.sh first."
systemctl is-active --quiet named || die "BIND9 not running. Run setup-reverse.sh first."

# ---------- helper functions -------------------------------------------------

bump_serial() {
    CURRENT_SERIAL=$(grep -oP '^\s*\K[0-9]{10}(?=\s*;\s*Serial)' "${ZONE_FILE}")
    TODAY=$(date +%Y%m%d)

    if [[ "${CURRENT_SERIAL:0:8}" == "${TODAY}" ]]; then
        NN=$(( 10#${CURRENT_SERIAL:8:2} + 1 ))
        NEW_SERIAL="${TODAY}$(printf '%02d' "${NN}")"
    else
        NEW_SERIAL="${TODAY}01"
    fi

    sed -i "s/${CURRENT_SERIAL}/${NEW_SERIAL}/" "${ZONE_FILE}"
    info "Serial bumped: ${CURRENT_SERIAL} -> ${NEW_SERIAL}"
}

validate() {
    info "Validating zone file..."
    if ! named-checkzone "${REVERSE_ZONE}" "${ZONE_FILE}"; then
        die "Zone file validation failed. No changes applied."
    fi
    success "Zone file valid."
}

reload_bind() {
    info "Reloading BIND9..."
    if ! rndc reload; then
        die "rndc reload failed. Check journalctl -u named for details."
    fi
    success "BIND9 reloaded."
}

# ---------- entry management -------------------------------------------------

add_entry() {
    read -rp "IP address (e.g. ${PREFIX}50): " IP
    read -rp "Hostname FQDN (e.g. webserver.example.com.): " HOSTNAME

    # basic IP format check
    if ! [[ "${IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Invalid IP format: ${IP}"
    fi

    # ensure IP belongs to this reverse zone
    if [[ "${IP}" != "${PREFIX}"* ]]; then
        die "IP ${IP} does not belong to this reverse zone (${REVERSE_ZONE})."
    fi

    # ensure FQDN has trailing dot
    if [[ "${HOSTNAME}" != *"." ]]; then
        die "Hostname must be a fully qualified domain name with a trailing dot (e.g. webserver.example.com.)"
    fi

    # extract last octet for the PTR record
    LAST_OCTET=$(echo "${IP}" | awk -F. '{print $4}')

    # check if entry already exists
    if grep -qP "^${LAST_OCTET}\s+IN\s+PTR\s+" "${ZONE_FILE}"; then
        die "PTR entry for '${IP}' already exists. Remove it first."
    fi

    echo "${LAST_OCTET}	IN	PTR	${HOSTNAME}" >> "${ZONE_FILE}"
    success "Added: ${IP} -> ${HOSTNAME}"

    bump_serial
    validate
    reload_bind
}

remove_entry() {
    read -rp "IP address to remove (e.g. ${PREFIX}50): " IP

    # basic IP format check
    if ! [[ "${IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Invalid IP format: ${IP}"
    fi

    # ensure IP belongs to this reverse zone
    if [[ "${IP}" != "${PREFIX}"* ]]; then
        die "IP ${IP} does not belong to this reverse zone (${REVERSE_ZONE})."
    fi

    LAST_OCTET=$(echo "${IP}" | awk -F. '{print $4}')

    # check entry actually exists
    if ! grep -qP "^${LAST_OCTET}\s+IN\s+PTR\s+" "${ZONE_FILE}"; then
        die "No PTR entry found for '${IP}'."
    fi

    # show the line we are about to delete
    warn "About to remove:"
    grep -P "^${LAST_OCTET}\s+IN\s+PTR\s+" "${ZONE_FILE}"
    echo ""
    read -rp "Confirm? [y/N]: " CONFIRM

    if [[ "${CONFIRM,,}" != "y" ]]; then
        info "Aborted."
        exit 0
    fi

    sed -i "/^${LAST_OCTET}\s\+IN\s\+PTR\s\+/d" "${ZONE_FILE}"
    success "Removed PTR for: ${IP}"

    bump_serial
    validate
    reload_bind
}

list_entries() {
    echo ""
    echo "${BOLD}Current PTR records in ${REVERSE_ZONE}:${NC}"
    echo "-------------------------------------------"
    grep -P "IN\t+PTR\t+" "${ZONE_FILE}" || warn "No PTR records found."
    echo "-------------------------------------------"
    echo ""
}

# ---------- menu -------------------------------------------------------------

echo ""
echo "${BOLD}${CYAN}Reverse DNS Management — ${REVERSE_ZONE}${NC}"
echo ""
echo "  1) Add PTR entry"
echo "  2) Remove PTR entry"
echo "  3) List PTR entries"
echo "  4) Exit"
echo ""
read -rp "Choice [1-4]: " CHOICE

case "${CHOICE}" in
    1) add_entry ;;
    2) remove_entry ;;
    3) list_entries ;;
    4) exit 0 ;;
    *) die "Invalid choice." ;;
esac