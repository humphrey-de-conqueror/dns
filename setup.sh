#!/bin/bash

# ============================================================
# Global / Configuration
# ============================================================

BIND_CONFIG="/etc/bind"
PROJECT_DIR="/etc/bind/dns-manager"
NAMESERVER_FILE="$PROJECT_DIR/nameservers"

SERVER_IP=""
BASE_DOMAIN=""
NAMESERVER_HOSTNAME=""
NAMESERVER_FQDN=""

# ============================================================
# Initialization
# ============================================================

init_config()
{
	mkdir -p "$PROJECT_DIR"

	if [ ! -f "$NAMESERVER_FILE" ]
	then
		touch "$NAMESERVER_FILE"
	fi
}

# ============================================================
# Output / Error Helpers
# ============================================================

print_msg()
{
	local color="$1"
	local message="$2"

	printf '%b%s%b\n' "$color" "$message" '\033[0m'
}

print_info()
{
	print_msg '\033[1;34m' "[INFO] $1"
}

print_success()
{
	print_msg '\033[1;32m' "[ OK ] $1"
}

print_warning()
{
	print_msg '\033[1;33m' "[WARN] $1"
}

print_error()
{
	print_msg '\033[1;31m' "[ERROR] $1"
}

die()
{
	print_error "$1"
	exit 1
}

# ============================================================
# Privilege
# ============================================================

check_privilege()
{
	if [ "$EUID" -ne 0 ]
	then
		die "This script must be run as root."
	fi
}

# ============================================================
# Package Management
# ============================================================

check_package_installed()
{
	local package="$1"

	dpkg -s "$package" >/dev/null 2>&1
}

install_package()
{
	local package="$1"

	print_info "Installing $package..."

	apt-get install -y "$package" ||
		die "Failed to install package: $package"

	print_success "$package installed."
}

install_dependencies()
{
	print_info "Checking dependencies..."

	if ! check_package_installed bind9
	then
		install_package bind9
	else
		print_success "bind9 is already installed."
	fi

	if ! check_package_installed bind9-utils
	then
		install_package bind9-utils
	else
		print_success "bind9-utils is already installed."
	fi
}

# ============================================================
# User Configuration
# ============================================================

get_user_config()
{
	get_server_ip
	get_base_domain
	get_nameserver_hostname
}

get_server_ip()
{
	read -rp "Server IP [127.0.0.1]: " SERVER_IP

	SERVER_IP="${SERVER_IP:-127.0.0.1}"

	print_info "Server IP: $SERVER_IP"
}

get_base_domain()
{
	read -rp "Base domain [example.com]: " BASE_DOMAIN

	BASE_DOMAIN="${BASE_DOMAIN:-example.com}"

	print_info "Base domain: $BASE_DOMAIN"
}

get_nameserver_hostname()
{
	read -rp "Nameserver hostname [ns1]: " NAMESERVER_HOSTNAME

	NAMESERVER_HOSTNAME="${NAMESERVER_HOSTNAME:-ns1}"

	print_info "Nameserver hostname: $NAMESERVER_HOSTNAME"
}

# ============================================================
# Nameserver Identity
# ============================================================

build_nameserver_fqdn()
{
	NAMESERVER_FQDN="${NAMESERVER_HOSTNAME}.${BASE_DOMAIN}"

	print_info "Nameserver FQDN: $NAMESERVER_FQDN"
}

check_nameserver_conflict()
{
	check_nameserver_hostname
	check_nameserver_ip
}

check_nameserver_hostname()
{
	if grep -Fq "${NAMESERVER_FQDN}|" "$NAMESERVER_FILE"
	then
		die "Nameserver already exists: $NAMESERVER_FQDN"
	fi
}

check_nameserver_ip()
{
	if grep -Eq "\|${SERVER_IP}$" "$NAMESERVER_FILE"
	then
		die "IP address is already registered: $SERVER_IP"
	fi
}

create_nameserver()
{
	printf '%s|%s\n' \
		"$NAMESERVER_FQDN" \
		"$SERVER_IP" >> "$NAMESERVER_FILE" ||
		die "Failed to register nameserver."

	print_success "Nameserver registered: $NAMESERVER_FQDN"
}

# ============================================================
# Directory / File Structure
# ============================================================

create_bind_directories()
{
	print_info "Creating project directories..."

	mkdir -p "$PROJECT_DIR" ||
		die "Failed to create project directory."

	mkdir -p "$PROJECT_DIR/zones" ||
		die "Failed to create zones directory."

	mkdir -p "$PROJECT_DIR/zones/forward" ||
		die "Failed to create forward zones directory."

	mkdir -p "$PROJECT_DIR/zones/reverse" ||
		die "Failed to create reverse zones directory."

	print_success "Project directories created."
}

create_nameserver_metadata()
{
	local metadata_file="$PROJECT_DIR/${NAMESERVER_FQDN}.conf"

	cat > "$metadata_file" <<EOF
NAMESERVER=$NAMESERVER_FQDN
IP=$SERVER_IP
DOMAIN=$BASE_DOMAIN
EOF

	if [ "$?" -ne 0 ]
	then
		die "Failed to create nameserver metadata."
	fi

	print_success "Nameserver metadata created."
}

# ============================================================
# BIND Configuration
# ============================================================

configure_bind()
{
	configure_bind_options
	configure_bind_local_settings
	configure_nameserver
}

configure_bind_options()
{
	print_info "Configuring BIND options..."

	cat > "$BIND_CONFIG/named.conf.options" <<EOF
options {
	directory "/var/cache/bind";

	listen-on {
		$SERVER_IP;
	};

	listen-on-v6 {
		none;
	};

	allow-query {
		any;
	};

	recursion no;

	dnssec-validation auto;
};
EOF

	if [ "$?" -ne 0 ]
	then
		die "Failed to configure named.conf.options."
	fi

	print_success "BIND options configured."
}

configure_bind_local_settings()
{
	if [ ! -f "$BIND_CONFIG/named.conf.local" ]
	then
		touch "$BIND_CONFIG/named.conf.local" ||
			die "Failed to create named.conf.local."
	fi

	print_success "BIND local configuration ready."
}

configure_nameserver()
{
	local nameserver_config="$PROJECT_DIR/nameserver.conf"

	cat > "$nameserver_config" <<EOF
# Managed by dns-manager.sh
#
# Nameserver identity:
# $NAMESERVER_FQDN
#
# IP address:
# $SERVER_IP
#
# Base domain:
# $BASE_DOMAIN
EOF

	if [ "$?" -ne 0 ]
	then
		die "Failed to create nameserver configuration."
	fi

	print_success "Nameserver configuration created."
}

# ============================================================
# Validation
# ============================================================

validate_bind_config()
{
	print_info "Validating BIND configuration..."

	named-checkconf ||
		die "BIND configuration validation failed."

	print_success "BIND configuration is valid."
}

validate_nameserver()
{
	print_info "Validating nameserver registration..."

	if ! grep -Fq "${NAMESERVER_FQDN}|${SERVER_IP}" "$NAMESERVER_FILE"
	then
		die "Nameserver registration could not be verified."
	fi

	print_success "Nameserver registration verified."
}

# ============================================================
# Service Management
# ============================================================

enable_bind_service()
{
	print_info "Enabling named service..."

	systemctl enable named ||
		die "Failed to enable named service."

	print_success "named service enabled."
}

start_bind_service()
{
	print_info "Starting named service..."

	systemctl start named ||
		die "Failed to start named service."

	print_success "named service started."
}

reload_bind_service()
{
	print_info "Reloading named service..."

	systemctl reload named ||
		die "Failed to reload named service."

	print_success "named service reloaded."
}

# ============================================================
# Status / Output
# ============================================================

show_bind_status()
{
	print_info "named service status:"

	systemctl --no-pager --full status named
}

show_nameserver_summary()
{
	printf '\n'
	printf '%s\n' "========================================"
	printf '%s\n' " Nameserver"
	printf '%s\n' "========================================"
	printf 'Hostname : %s\n' "$NAMESERVER_FQDN"
	printf 'IP       : %s\n' "$SERVER_IP"
	printf 'Domain   : %s\n' "$BASE_DOMAIN"
	printf '%s\n' "========================================"
}

show_setup_summary()
{
	printf '\n'
	printf '%s\n' "========================================"
	printf '%s\n' " Setup Summary"
	printf '%s\n' "========================================"
	printf 'BIND config     : %s\n' "$BIND_CONFIG"
	printf 'Project dir     : %s\n' "$PROJECT_DIR"
	printf 'Nameserver file : %s\n' "$NAMESERVER_FILE"
	printf 'Nameserver      : %s\n' "$NAMESERVER_FQDN"
	printf 'Server IP       : %s\n' "$SERVER_IP"
	printf '%s\n' "========================================"
	printf '\n'

	print_info "No forward or reverse zones were created."
	print_info "Use dns-manager.sh to create and manage zones."
}

# ============================================================
# Main Workflow
# ============================================================

main()
{
	check_privilege

	print_info "Starting BIND9 DNS setup..."

	init_config

	install_dependencies

	get_user_config

	build_nameserver_fqdn

	check_nameserver_conflict

	create_bind_directories

	configure_bind
	configure_nameserver

	create_nameserver
	create_nameserver_metadata

	validate_bind_config
	validate_nameserver

	enable_bind_service
	start_bind_service

	show_bind_status
	show_nameserver_summary
	show_setup_summary

	print_success "BIND9 DNS setup completed."
}

main "$@"