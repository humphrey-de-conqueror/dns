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

# ---------- preflight checks -------------------------------------------------
command -v named &>/dev/null      || die "BIND9 not installed."
systemctl is-active --quiet named || die "BIND9 is not running."
[[ -f /etc/bind/named.conf.local ]] \
    || die "/etc/bind/named.conf.local not found. Has setup been run?"

# ---------- read declared zones ----------------------------------------------
mapfile -t ZONES < <(grep -oP 'zone "\K[^"]+' /etc/bind/named.conf.local)

if [[ ${#ZONES[@]} -eq 0 ]]; then
    info "No zones declared in named.conf.local. Nothing to manage."
    exit 0
fi

# ---------- display zones ----------------------------------------------------
echo ""
echo "${BOLD}${CYAN}Zone Manager${NC}"
echo ""
echo "Current zones:"
echo ""

for i in "${!ZONES[@]}"; do
    echo "  $((i+1))) ${ZONES[$i]}"
done

echo ""
read -rp "Select zone number to remove, or press Enter to exit: " CHOICE

# exit if user pressed Enter with no input
[[ -z "${CHOICE}" ]] && { info "No changes made. Exiting."; exit 0; }

# validate choice is a number within range
if ! [[ "${CHOICE}" =~ ^[0-9]+$ ]] || \
   (( CHOICE < 1 || CHOICE > ${#ZONES[@]} )); then
    die "Invalid selection."
fi

# ---------- confirm removal --------------------------------------------------
SELECTED_ZONE="${ZONES[$((CHOICE-1))]}"
ZONE_FILE="/etc/bind/db.${SELECTED_ZONE}"

echo ""
warn "You are about to remove:"
echo "    Zone      : ${SELECTED_ZONE}"
echo "    Zone file : ${ZONE_FILE}"
echo ""
read -rp "Confirm? [y/N]: " CONFIRM

if [[ "${CONFIRM,,}" != "y" ]]; then
    info "Aborted. No changes made."
    exit 0
fi

# ---------- remove zone declaration from named.conf.local --------------------
info "Removing zone declaration from named.conf.local..."
sed -i "/zone \"${SELECTED_ZONE}\"/,/};/d" /etc/bind/named.conf.local
success "Zone declaration removed."

# ---------- remove zone file if it exists ------------------------------------
if [[ -f "${ZONE_FILE}" ]]; then
    info "Removing zone file ${ZONE_FILE}..."
    rm -f "${ZONE_FILE}"
    success "Zone file removed."
else
    warn "Zone file ${ZONE_FILE} not found — skipping."
fi

# ---------- validate and reload ----------------------------------------------
info "Validating named.conf..."
if ! named-checkconf; then
    die "named.conf validation failed after removal. Check /etc/bind/named.conf.local manually."
fi
success "named.conf looks good."

info "Reloading BIND9..."
if ! rndc reload; then
    die "rndc reload failed. Check journalctl -u named for details."
fi
success "BIND9 reloaded."

# ---------- closing ----------------------------------------------------------
echo ""
echo "${BOLD}${GREEN}============================================${NC}"
echo "${BOLD}${GREEN}  Zone Removed Successfully${NC}"
echo "${BOLD}${GREEN}============================================${NC}"
echo ""
info "Removed zone : ${SELECTED_ZONE}"
echo ""
warn "To verify    : cat /etc/bind/named.conf.local"
warn "To check logs: journalctl -u named -f"