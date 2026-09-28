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

# ---------- read domain from existing config ---------------------------------
# exclude in-addr.arpa zones so we only grab the forward zone
DOMAIN=$(grep -oP 'zone "\K[^"]+' /etc/bind/named.conf.local | grep -v "in-addr.arpa") \
    || die "Could not read domain from /etc/bind/named.conf.local. Run setup-forward.sh first."

ZONE_FILE="/etc/bind/db.${DOMAIN}"

# ---------- preflight checks -------------------------------------------------
command -v named &>/dev/null      || die "BIND9 not installed. Run setup-forward.sh first."
[[ -f "${ZONE_FILE}" ]]           || die "Zone file not found. Run setup-forward.sh first."
systemctl is-active --quiet named || die "BIND9 not running. Run setup-forward.sh first."

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
    if ! named-checkzone "${DOMAIN}" "${ZONE_FILE}"; then
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
    read -rp "Hostname (e.g. webserver): " HOSTNAME
    read -rp "IP address (e.g. 192.168.1.50): " IP

    # basic IP format check
    if ! [[ "${IP}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        die "Invalid IP format: ${IP}"
    fi

    # check if entry already exists
    if grep -qP "^${HOSTNAME}\s+IN\s+A\s+" "${ZONE_FILE}"; then
        die "Entry for '${HOSTNAME}' already exists. Remove it first."
    fi

    echo "${HOSTNAME}	IN	A	${IP}" >> "${ZONE_FILE}"
    success "Added: ${HOSTNAME} -> ${IP}"

    bump_serial
    validate
    reload_bind
}

remove_entry() {
    read -rp "Hostname to remove (e.g. webserver): " HOSTNAME

    # check entry actually exists
    if ! grep -qP "^${HOSTNAME}\s+IN\s+A\s+" "${ZONE_FILE}"; then
        die "No entry found for '${HOSTNAME}'."
    fi

    # show the line we are about to delete
    warn "About to remove:"
    grep -P "^${HOSTNAME}\s+IN\s+A\s+" "${ZONE_FILE}"
    echo ""
    read -rp "Confirm? [y/N]: " CONFIRM

    if [[ "${CONFIRM,,}" != "y" ]]; then
        info "Aborted."
        exit 0
    fi

    sed -i "/^${HOSTNAME}\s\+IN\s\+A\s\+/d" "${ZONE_FILE}"
    success "Removed: ${HOSTNAME}"

    bump_serial
    validate
    reload_bind
}

list_entries() {
    echo ""
    echo "${BOLD}Current A records in ${DOMAIN}:${NC}"
    echo "-------------------------------------------"
    grep -P "IN\t+A\t+" "${ZONE_FILE}" || warn "No A records found."
    echo "-------------------------------------------"
    echo ""
}

# ---------- menu -------------------------------------------------------------

echo ""
echo "${BOLD}${CYAN}DNS Management — ${DOMAIN}${NC}"
echo ""
echo "  1) Add entry"
echo "  2) Remove entry"
echo "  3) List entries"
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