#!/bin/bash

# ============================================================
# Global / Configuration
# ============================================================

BIND_CONFIG="/etc/bind"
PROJECT_DIR="/etc/bind/dns-manager"

NAMESERVER_FILE="$PROJECT_DIR/nameservers"
ZONE_INCLUDE_FILE="$PROJECT_DIR/named.conf.zones"
NAMED_OPTIONS="$BIND_CONFIG/named.conf.options"
NAMED_LOCAL="$BIND_CONFIG/named.conf.local"

ZONE_ROOT="$PROJECT_DIR/zones"

SERVER_IP=""
BASE_DOMAIN=""
NAMESERVER_HOSTNAME=""
NAMESERVER_FQDN=""

OLD_OPTIONS_BACKUP=""
OLD_REGISTRY_BACKUP=""

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

	if ! apt-get install -y "$package"
	then
		die "Failed to install package: $package"
	fi

	print_success "$package installed."
}

install_dependencies()
{
	print_info "Checking dependencies..."

	if check_package_installed bind9
	then
		print_success "bind9 is already installed."
	else
		install_package bind9
	fi

	if check_package_installed bind9-utils
	then
		print_success "bind9-utils is already installed."
	else
		install_package bind9-utils
	fi

	if command -v ip >/dev/null 2>&1
	then
		print_success "ip command is available."
	else
		install_package iproute2
	fi
}

# ============================================================
# Initialization
# ============================================================

initialize_directories()
{
	print_info "Initializing DNS manager directories..."

	if ! mkdir -p "$PROJECT_DIR"
	then
		die "Failed to create project directory."
	fi

	if ! mkdir -p "$ZONE_ROOT"
	then
		die "Failed to create zone root."
	fi

	if ! mkdir -p "$BIND_CONFIG"
	then
		die "Failed to access BIND configuration directory."
	fi

	if [ ! -f "$NAMESERVER_FILE" ]
	then
		if ! touch "$NAMESERVER_FILE"
		then
			die "Failed to create nameserver registry."
		fi
	fi

	if [ ! -f "$ZONE_INCLUDE_FILE" ]
	then
		if ! touch "$ZONE_INCLUDE_FILE"
		then
			die "Failed to create zone include file."
		fi
	fi

	if [ ! -f "$NAMED_LOCAL" ]
	then
		if ! touch "$NAMED_LOCAL"
		then
			die "Failed to create named.conf.local."
		fi
	fi

	print_success "DNS manager directories initialized."
}

# ============================================================
# Input
# ============================================================

get_user_config()
{
	get_server_ip
	get_base_domain
	get_nameserver_hostname

	NAMESERVER_FQDN="${NAMESERVER_HOSTNAME}.${BASE_DOMAIN}"
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
# Validation - IPv4
# ============================================================

validate_ipv4()
{
	local ip="$1"
	local octet
	local value
	local count=0

	if [[ ! "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
	then
		return 1
	fi

	IFS='.' read -r -a octets <<< "$ip"

	if [ "${#octets[@]}" -ne 4 ]
	then
		return 1
	fi

	for octet in "${octets[@]}"
	do
		count=$((count + 1))

		# Reject leading zeroes.
		if [[ "$octet" =~ ^0[0-9]+$ ]]
		then
			return 1
		fi

		value=$((10#$octet))

		if [ "$value" -lt 0 ] || [ "$value" -gt 255 ]
		then
			return 1
		fi
	done

	return 0
}

# ============================================================
# Validation - DNS Label
# ============================================================

validate_dns_label()
{
	local label="$1"
	local length

	length=${#label}

	if [ "$length" -lt 1 ] || [ "$length" -gt 63 ]
	then
		return 1
	fi

	if [[ ! "$label" =~ ^[A-Za-z0-9-]+$ ]]
	then
		return 1
	fi

	if [[ "$label" == -* ]] || [[ "$label" == *- ]]
	then
		return 1
	fi

	return 0
}

# ============================================================
# Validation - DNS Name
# ============================================================

validate_dns_name()
{
	local name="$1"
	local label
	local length

	# Remove one optional trailing dot.
	name="${name%.}"

	length=${#name}

	if [ "$length" -lt 1 ] || [ "$length" -gt 253 ]
	then
		return 1
	fi

	if [[ "$name" == *".."* ]]
	then
		return 1
	fi

	if [[ "$name" == *"/"* ]]
	then
		return 1
	fi

	IFS='.' read -r -a labels <<< "$name"

	for label in "${labels[@]}"
	do
		if ! validate_dns_label "$label"
		then
			return 1
		fi
	done

	return 0
}

# ============================================================
# Validation - User Input
# ============================================================

validate_user_input()
{
	print_info "Validating input..."

	if ! validate_ipv4 "$SERVER_IP"
	then
		die "Invalid IPv4 address: $SERVER_IP"
	fi

	if ! validate_dns_name "$BASE_DOMAIN"
	then
		die "Invalid base domain: $BASE_DOMAIN"
	fi

	if ! validate_dns_label "$NAMESERVER_HOSTNAME"
	then
		die "Invalid nameserver hostname: $NAMESERVER_HOSTNAME"
	fi

	print_success "Input validation passed."
}

# ============================================================
# Validation - Local IP
# ============================================================

check_local_ip()
{
	local target="$SERVER_IP"

	print_info "Checking whether $target is assigned to this machine..."

	if ! ip -4 -o addr show |
		awk -v target="$target" '
			{
				split($4, address, "/")

				if (address[1] == target)
				{
					found = 1
				}
			}

			END
			{
				exit !found
			}
		'
	then
		die "IP address is not assigned to this machine: $SERVER_IP"
	fi

	print_success "IP address is assigned to this machine."
}

# ============================================================
# Nameserver Registry
# ============================================================

check_nameserver_hostname_conflict()
{
	if awk -F'|' -v hostname="$NAMESERVER_FQDN" '
		$1 == hostname {
			found = 1
		}

		END {
			exit !found
		}
	' "$NAMESERVER_FILE"
	then
		die "Nameserver already exists: $NAMESERVER_FQDN"
	fi
}

check_nameserver_ip_conflict()
{
	if awk -F'|' -v ip="$SERVER_IP" '
		$2 == ip {
			found = 1
		}

		END {
			exit !found
		}
	' "$NAMESERVER_FILE"
	then
		die "IP address is already registered: $SERVER_IP"
	fi
}

check_nameserver_conflict()
{
	print_info "Checking nameserver conflicts..."

	check_nameserver_hostname_conflict
	check_nameserver_ip_conflict

	print_success "No nameserver conflicts found."
}

# ============================================================
# Nameserver Directory
# ============================================================

create_nameserver_directories()
{
	local nameserver_dir="$ZONE_ROOT/$NAMESERVER_FQDN"

	print_info "Creating nameserver directories..."

	if ! mkdir -p "$nameserver_dir/forward"
	then
		die "Failed to create forward zone directory."
	fi

	if ! mkdir -p "$nameserver_dir/reverse"
	then
		die "Failed to create reverse zone directory."
	fi

	print_success "Nameserver directories created."
}

# ============================================================
# Registry Candidate
# ============================================================

create_registry_candidate()
{
	local candidate="$PROJECT_DIR/nameservers.tmp"

	if ! cp "$NAMESERVER_FILE" "$candidate"
	then
		die "Failed to create registry candidate."
	fi

	printf '%s|%s\n' \
		"$NAMESERVER_FQDN" \
		"$SERVER_IP" >> "$candidate" ||
		die "Failed to update registry candidate."

	printf '%s\n' "$candidate"
}

# ============================================================
# BIND Options Generation
# ============================================================

generate_named_options()
{
	local registry_file="$1"
	local output_file="$2"
	local hostname
	local ip

	cat > "$output_file" <<EOF
// Managed by dns-manager.sh

options {
	directory "/var/cache/bind";

	listen-on {
EOF

	while IFS='|' read -r hostname ip
	do
		[ -z "$hostname" ] && continue
		[ -z "$ip" ] && continue

		printf '\t\t%s;\n' "$ip" >> "$output_file"
	done < "$registry_file"

	cat >> "$output_file" <<EOF
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
}

# ============================================================
# BIND Local Configuration
# ============================================================

ensure_zone_include()
{
	local include_line
	local temp_file

	include_line='include "/etc/bind/dns-manager/named.conf.zones";'

	if grep -Fqx "$include_line" "$NAMED_LOCAL"
	then
		print_success "Managed zone include already exists."
		return 0
	fi

	temp_file=$(mktemp) ||
		die "Failed to create temporary named.conf.local."

	cp "$NAMED_LOCAL" "$temp_file" ||
		die "Failed to copy named.conf.local."

	printf '\n%s\n' "$include_line" >> "$temp_file"

	if ! named-checkconf "$temp_file"
	then
		rm -f "$temp_file"
		die "named.conf.local is invalid after adding the managed include."
	fi

	if ! mv "$temp_file" "$NAMED_LOCAL"
	then
		rm -f "$temp_file"
		die "Failed to install named.conf.local."
	fi

	print_success "Managed zone include added."
}

# ============================================================
# BIND Configuration Transaction
# ============================================================

apply_bind_configuration()
{
	local registry_candidate="$1"
	local options_candidate
	local options_backup

	options_candidate=$(mktemp) ||
		die "Failed to create temporary options file."

	options_backup=$(mktemp) ||
		die "Failed to create temporary options backup."

	if ! generate_named_options \
		"$registry_candidate" \
		"$options_candidate"
	then
		rm -f "$options_candidate" "$options_backup"
		die "Failed to generate BIND options."
	fi

	if [ -f "$NAMED_OPTIONS" ]
	then
		if ! cp "$NAMED_OPTIONS" "$options_backup"
		then
			rm -f "$options_candidate" "$options_backup"
			die "Failed to back up named.conf.options."
		fi
	else
		: > "$options_backup"
	fi

	if ! cp "$NAMESERVER_FILE" "$OLD_REGISTRY_BACKUP"
	then
		rm -f "$options_candidate" "$options_backup"
		die "Failed to back up nameserver registry."
	fi

	if ! cp "$options_candidate" "$NAMED_OPTIONS"
	then
		rm -f "$options_candidate"
		rm -f "$options_backup"
		die "Failed to install candidate named.conf.options."
	fi

	if ! named-checkconf
	then
		print_error "BIND configuration validation failed."

		if [ -s "$options_backup" ]
		then
			cp "$options_backup" "$NAMED_OPTIONS"
		else
			rm -f "$NAMED_OPTIONS"
		fi

		rm -f "$options_candidate"
		rm -f "$options_backup"

		die "BIND configuration was not changed."
	fi

	if ! cp "$registry_candidate" "$NAMESERVER_FILE"
	then
		print_error "Failed to install nameserver registry."

		if [ -s "$options_backup" ]
		then
			cp "$options_backup" "$NAMED_OPTIONS"
		else
			rm -f "$NAMED_OPTIONS"
		fi

		rm -f "$options_candidate"
		rm -f "$options_backup"

		die "Setup transaction rolled back."
	fi

	rm -f "$options_candidate"
	rm -f "$options_backup"

	print_success "BIND configuration and nameserver registry updated."
}

# ============================================================
# Zone Include Initialization
# ============================================================

initialize_zone_include()
{
	# The file is intentionally empty during setup.
	#
	# dns-manager.sh will populate it when zones are created.
	#
	# Keeping one dedicated include file means the manager
	# does not need to modify named.conf.local every time.

	if [ ! -f "$ZONE_INCLUDE_FILE" ]
	then
		if ! touch "$ZONE_INCLUDE_FILE"
		then
			die "Failed to create zone include file."
		fi
	fi

	print_success "Managed zone include initialized."
}

# ============================================================
# Service Management
# ============================================================

enable_bind_service()
{
	print_info "Enabling named service..."

	if ! systemctl enable named
	then
		die "Failed to enable named service."
	fi

	print_success "named service enabled."
}

start_or_reload_bind()
{
	if systemctl is-active --quiet named
	then
		print_info "named is already running. Reloading configuration..."

		if ! systemctl reload named
		then
			die "Failed to reload named."
		fi

		print_success "named configuration reloaded."
	else
		print_info "Starting named service..."

		if ! systemctl start named
		then
			die "Failed to start named service."
		fi

		print_success "named service started."
	fi
}

# ============================================================
# Status
# ============================================================

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
	printf 'BIND config       : %s\n' "$BIND_CONFIG"
	printf 'Project dir       : %s\n' "$PROJECT_DIR"
	printf 'Nameserver file   : %s\n' "$NAMESERVER_FILE"
	printf 'Zone include      : %s\n' "$ZONE_INCLUDE_FILE"
	printf 'Nameserver        : %s\n' "$NAMESERVER_FQDN"
	printf 'Server IP         : %s\n' "$SERVER_IP"
	printf 'Zone directory    : %s/%s\n' "$ZONE_ROOT" "$NAMESERVER_FQDN"
	printf '%s\n' "========================================"
	printf '\n'

	print_info "No forward or reverse zones were created."
	print_info "Use dns-manager.sh to create and manage zones."
}

show_bind_status()
{
	print_info "named service status:"

	systemctl --no-pager --full status named
}

# ============================================================
# Main
# ============================================================

main()
{
	local registry_candidate

	check_privilege

	print_info "Starting BIND9 DNS setup..."

	install_dependencies
	initialize_directories

	get_user_config

	validate_user_input
	check_local_ip
	check_nameserver_conflict

	create_nameserver_directories
	initialize_zone_include
	ensure_zone_include

	registry_candidate=$(create_registry_candidate)

	OLD_REGISTRY_BACKUP=$(mktemp) ||
		die "Failed to create registry backup."

	apply_bind_configuration "$registry_candidate"

	rm -f "$registry_candidate"
	rm -f "$OLD_REGISTRY_BACKUP"

	enable_bind_service
	start_or_reload_bind

	show_nameserver_summary
	show_setup_summary
	show_bind_status

	print_success "BIND9 DNS setup completed."
}

main "$@"
