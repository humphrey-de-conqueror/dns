#!/bin/bash

# ============================================================
# Initialization
# ============================================================

load_config()
{
	BIND_CONFIG="/etc/bind"
	PROJECT_DIR="/etc/bind/dns-manager"
	NAMESERVER_FILE="$PROJECT_DIR/nameservers"

	FORWARD_ZONE_DIR="$PROJECT_DIR/zones/forward"
	REVERSE_ZONE_DIR="$PROJECT_DIR/zones/reverse"

	NAMED_LOCAL="$BIND_CONFIG/named.conf.local"

	NAMESERVERS=()
	FORWARD_ZONES=()
	REVERSE_ZONES=()

	SELECTED_NAMESERVER=""
	SELECTED_NAMESERVER_IP=""

	SELECTED_ZONE=""
	SELECTED_ZONE_FILE=""
	SELECTED_ZONE_CONF=""
}

initialize_manager()
{
	if [ ! -d "$PROJECT_DIR" ]
	then
		die "DNS manager has not been initialized."
	fi

	if [ ! -f "$NAMESERVER_FILE" ]
	then
		die "Nameserver registry does not exist: $NAMESERVER_FILE"
	fi

	mkdir -p "$FORWARD_ZONE_DIR" ||
		die "Failed to create forward zone directory."

	mkdir -p "$REVERSE_ZONE_DIR" ||
		die "Failed to create reverse zone directory."

	if [ ! -f "$NAMED_LOCAL" ]
	then
		touch "$NAMED_LOCAL" ||
			die "Failed to create $NAMED_LOCAL."
	fi
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
# Nameserver Discovery
# ============================================================

discover_nameservers()
{
	NAMESERVERS=()

	while IFS='|' read -r hostname ip
	do
		[ -z "$hostname" ] && continue

		NAMESERVERS+=("$hostname|$ip")
	done < "$NAMESERVER_FILE"
}

get_nameservers()
{
	discover_nameservers
}

select_nameserver()
{
	local choice
	local i

	if [ "${#NAMESERVERS[@]}" -eq 0 ]
	then
		print_warning "No nameservers are registered."
		return 1
	fi

	printf '\n'
	printf '%s\n' "========================================"
	printf '%s\n' " Select Nameserver"
	printf '%s\n' "========================================"

	for ((i = 0; i < ${#NAMESERVERS[@]}; i++))
	do
		local hostname="${NAMESERVERS[$i]%%|*}"
		local ip="${NAMESERVERS[$i]#*|}"

		printf '%d. %s (%s)\n' \
			"$((i + 1))" \
			"$hostname" \
			"$ip"
	done

	printf '0. Back\n'

	read -rp "Choice: " choice

	if [ "$choice" = "0" ]
	then
		return 1
	fi

	if ! [[ "$choice" =~ ^[0-9]+$ ]]
	then
		print_warning "Invalid choice."
		return 1
	fi

	if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#NAMESERVERS[@]}" ]
	then
		print_warning "Invalid choice."
		return 1
	fi

	local selected="${NAMESERVERS[$((choice - 1))]}"

	SELECTED_NAMESERVER="${selected%%|*}"
	SELECTED_NAMESERVER_IP="${selected#*|}"

	return 0
}

# ============================================================
# Main Menu
# ============================================================

show_main_menu()
{
	local choice

	printf '\n'
	printf '%s\n' "========================================"
	printf '%s\n' " DNS Manager"
	printf '%s\n' "========================================"

	get_nameservers

	if [ "${#NAMESERVERS[@]}" -eq 0 ]
	then
		printf 'No nameservers registered.\n'
	else
		local i

		for ((i = 0; i < ${#NAMESERVERS[@]}; i++))
		do
			local hostname="${NAMESERVERS[$i]%%|*}"
			local ip="${NAMESERVERS[$i]#*|}"

			printf '%d. %s (%s)\n' \
				"$((i + 1))" \
				"$hostname" \
				"$ip"
		done
	fi

	printf '\n'
	printf 'R. Remove nameserver\n'
	printf '0. Exit\n'

	read -rp "Choice: " choice

	case "$choice" in
		R|r)
			remove_nameserver
			;;
		0)
			return 1
			;;
		*)
			if ! [[ "$choice" =~ ^[0-9]+$ ]]
			then
				print_warning "Invalid choice."
				return 0
			fi

			if [ "$choice" -lt 1 ] ||
			   [ "$choice" -gt "${#NAMESERVERS[@]}" ]
			then
				print_warning "Invalid choice."
				return 0
			fi

			local selected="${NAMESERVERS[$((choice - 1))]}"

			SELECTED_NAMESERVER="${selected%%|*}"
			SELECTED_NAMESERVER_IP="${selected#*|}"

			show_nameserver_menu
			;;
	esac

	return 0
}

show_nameserver_menu()
{
	local choice

	while true
	do
		printf '\n'
		printf '%s\n' "========================================"
		printf ' Nameserver: %s\n' "$SELECTED_NAMESERVER"
		printf ' IP        : %s\n' "$SELECTED_NAMESERVER_IP"
		printf '%s\n' "========================================"
		printf '1. Forward zones\n'
		printf '2. Reverse zones\n'
		printf '3. Remove nameserver\n'
		printf '0. Back\n'

		read -rp "Choice: " choice

		case "$choice" in
			1)
				select_forward_zone
				;;
			2)
				select_reverse_zone
				;;
			3)
				remove_nameserver
				return
				;;
			0)
				return
				;;
			*)
				print_warning "Invalid choice."
				;;
		esac
	done
}

# ============================================================
# Nameserver Management
# ============================================================

remove_nameserver()
{
	local choice
	local hostname
	local ip
	local temp_file

	get_nameservers

	if [ "${#NAMESERVERS[@]}" -eq 0 ]
	then
		print_warning "No nameservers to remove."
		return
	fi

	printf '\n'
	printf '%s\n' "========================================"
	printf '%s\n' " Remove Nameserver"
	printf '%s\n' "========================================"

	select_nameserver || return

	hostname="$SELECTED_NAMESERVER"
	ip="$SELECTED_NAMESERVER_IP"

	printf '\n'
	print_warning "You are removing:"
	printf 'Hostname : %s\n' "$hostname"
	printf 'IP       : %s\n' "$ip"

	read -rp "Continue? [y/N]: " choice

	case "$choice" in
		y|Y)
			;;
		*)
			print_info "Operation cancelled."
			return
			;;
	esac

	temp_file="${NAMESERVER_FILE}.tmp"

	awk -F'|' -v hostname="$hostname" '
		$1 != hostname
	' "$NAMESERVER_FILE" > "$temp_file" ||
		die "Failed to create temporary nameserver registry."

	mv "$temp_file" "$NAMESERVER_FILE" ||
		die "Failed to update nameserver registry."

	print_success "Nameserver removed: $hostname"

	if [ "$hostname" = "$SELECTED_NAMESERVER" ]
	then
		SELECTED_NAMESERVER=""
		SELECTED_NAMESERVER_IP=""
	fi

	reload_bind_service
}

# ============================================================
# Zone Discovery
# ============================================================

discover_forward_zones()
{
	FORWARD_ZONES=()

	if [ ! -d "$FORWARD_ZONE_DIR" ]
	then
		return
	fi

	for zone_file in "$FORWARD_ZONE_DIR"/*.zone
	do
		[ -f "$zone_file" ] || continue

		local zone

		zone="$(basename "$zone_file" .zone)"

		FORWARD_ZONES+=("$zone")
	done
}

discover_reverse_zones()
{
	REVERSE_ZONES=()

	if [ ! -d "$REVERSE_ZONE_DIR" ]
	then
		return
	fi

	for zone_file in "$REVERSE_ZONE_DIR"/*.zone
	do
		[ -f "$zone_file" ] || continue

		local zone

		zone="$(basename "$zone_file" .zone)"

		REVERSE_ZONES+=("$zone")
	done
}

get_forward_zones()
{
	discover_forward_zones
}

get_reverse_zones()
{
	discover_reverse_zones
}

select_forward_zone()
{
	local choice
	local i

	get_forward_zones

	printf '\n'
	printf '%s\n' "========================================"
	printf '%s\n' " Forward Zones"
	printf '%s\n' "========================================"

	for ((i = 0; i < ${#FORWARD_ZONES[@]}; i++))
	do
		printf '%d. %s\n' \
			"$((i + 1))" \
			"${FORWARD_ZONES[$i]}"
	done

	printf '%d. Create zone\n' \
		"$(( ${#FORWARD_ZONES[@]} + 1 ))"

	printf '0. Back\n'

	read -rp "Choice: " choice

	if [ "$choice" = "0" ]
	then
		return
	fi

	if [ "$choice" = "$(( ${#FORWARD_ZONES[@]} + 1 ))" ]
	then
		create_forward_zone
		return
	fi

	if ! [[ "$choice" =~ ^[0-9]+$ ]]
	then
		print_warning "Invalid choice."
		return
	fi

	if [ "$choice" -lt 1 ] ||
	   [ "$choice" -gt "${#FORWARD_ZONES[@]}" ]
	then
		print_warning "Invalid choice."
		return
	fi

	SELECTED_ZONE="${FORWARD_ZONES[$((choice - 1))]}"
	SELECTED_ZONE_FILE="$FORWARD_ZONE_DIR/$SELECTED_ZONE.zone"
	SELECTED_ZONE_CONF="$FORWARD_ZONE_DIR/$SELECTED_ZONE.conf"

	show_forward_zone_menu
}

select_reverse_zone()
{
	local choice
	local i

	get_reverse_zones

	printf '\n'
	printf '%s\n' "========================================"
	printf '%s\n' " Reverse Zones"
	printf '%s\n' "========================================"

	for ((i = 0; i < ${#REVERSE_ZONES[@]}; i++))
	do
		printf '%d. %s\n' \
			"$((i + 1))" \
			"${REVERSE_ZONES[$i]}"
	done

	printf '%d. Create zone\n' \
		"$(( ${#REVERSE_ZONES[@]} + 1 ))"

	printf '0. Back\n'

	read -rp "Choice: " choice

	if [ "$choice" = "0" ]
	then
		return
	fi

	if [ "$choice" = "$(( ${#REVERSE_ZONES[@]} + 1 ))" ]
	then
		create_reverse_zone
		return
	fi

	if ! [[ "$choice" =~ ^[0-9]+$ ]]
	then
		print_warning "Invalid choice."
		return
	fi

	if [ "$choice" -lt 1 ] ||
	   [ "$choice" -gt "${#REVERSE_ZONES[@]}" ]
	then
		print_warning "Invalid choice."
		return
	fi

	SELECTED_ZONE="${REVERSE_ZONES[$((choice - 1))]}"
	SELECTED_ZONE_FILE="$REVERSE_ZONE_DIR/$SELECTED_ZONE.zone"
	SELECTED_ZONE_CONF="$REVERSE_ZONE_DIR/$SELECTED_ZONE.conf"

	show_reverse_zone_menu
}

# ============================================================
# Zone Menus
# ============================================================

show_forward_zone_menu()
{
	local choice

	while true
	do
		printf '\n'
		printf '%s\n' "========================================"
		printf ' Forward Zone: %s\n' "$SELECTED_ZONE"
		printf '%s\n' "========================================"
		printf '1. List records\n'
		printf '2. Add record\n'
		printf '3. Remove record\n'
		printf '4. Remove zone\n'
		printf '0. Back\n'

		read -rp "Choice: " choice

		case "$choice" in
			1)
				list_records
				;;
			2)
				add_record
				;;
			3)
				remove_record
				;;
			4)
				remove_forward_zone
				return
				;;
			0)
				return
				;;
			*)
				print_warning "Invalid choice."
				;;
		esac
	done
}

show_reverse_zone_menu()
{
	local choice

	while true
	do
		printf '\n'
		printf '%s\n' "========================================"
		printf ' Reverse Zone: %s\n' "$SELECTED_ZONE"
		printf '%s\n' "========================================"
		printf '1. List records\n'
		printf '2. Add PTR\n'
		printf '3. Remove PTR\n'
		printf '4. Remove zone\n'
		printf '0. Back\n'

		read -rp "Choice: " choice

		case "$choice" in
			1)
				list_records
				;;
			2)
				add_ptr_record
				;;
			3)
				remove_ptr_record
				;;
			4)
				remove_reverse_zone
				return
				;;
			0)
				return
				;;
			*)
				print_warning "Invalid choice."
				;;
		esac
	done
}

# ============================================================
# Forward Zone Management
# ============================================================

create_forward_zone()
{
	local zone
	local serial
	local zone_file
	local zone_conf

	read -rp "Forward zone name: " zone

	if [ -z "$zone" ]
	then
		print_warning "Zone name cannot be empty."
		return
	fi

	zone_file="$FORWARD_ZONE_DIR/$zone.zone"
	zone_conf="$FORWARD_ZONE_DIR/$zone.conf"

	if [ -f "$zone_file" ] || [ -f "$zone_conf" ]
	then
		die "Forward zone already exists: $zone"
	fi

	serial="$(date +%s)"

	cat > "$zone_file" <<EOF
\$TTL 86400

@	IN	SOA	$SELECTED_NAMESERVER. admin.$zone. (
		$serial
		3600
		1800
		604800
		86400
)

@	IN	NS	$SELECTED_NAMESERVER.
EOF

	if [ "$?" -ne 0 ]
	then
		die "Failed to create zone file."
	fi

	cat > "$zone_conf" <<EOF
zone "$zone" {
	type master;
	file "$zone_file";
};
EOF

	if [ "$?" -ne 0 ]
	then
		rm -f "$zone_file"
		die "Failed to create zone configuration."
	fi

	cat >> "$NAMED_LOCAL" <<EOF

// Managed by dns-manager.sh
include "$zone_conf";
EOF

	validate_zone || {
		rm -f "$zone_file"
		rm -f "$zone_conf"
		return
	}

	reload_bind_service

	print_success "Forward zone created: $zone"
}

remove_forward_zone()
{
	local choice
	local zone_conf

	printf '\n'
	print_warning "Remove forward zone: $SELECTED_ZONE"

	read -rp "Continue? [y/N]: " choice

	case "$choice" in
		y|Y)
			;;
		*)
			print_info "Operation cancelled."
			return
			;;
	esac

	zone_conf="$SELECTED_ZONE_CONF"

	remove_zone_configuration "$zone_conf"

	rm -f "$SELECTED_ZONE_FILE" ||
		die "Failed to remove zone file."

	rm -f "$zone_conf" ||
		die "Failed to remove zone configuration."

	reload_bind_service

	print_success "Forward zone removed: $SELECTED_ZONE"

	SELECTED_ZONE=""
	SELECTED_ZONE_FILE=""
	SELECTED_ZONE_CONF=""
}

# ============================================================
# Reverse Zone Management
# ============================================================

create_reverse_zone()
{
	local zone
	local serial
	local zone_file
	local zone_conf

	read -rp "IPv4 network (example: 192.168.0.0/24): " zone

	if [ -z "$zone" ]
	then
		print_warning "Network cannot be empty."
		return
	fi

	if [[ "$zone" != */24 ]]
	then
		die "This first version only supports /24 reverse zones."
	fi

	local network="${zone%/24}"
	local a="${network%%.*}"
	local rest="${network#*.}"
	local b="${rest%%.*}"
	rest="${rest#*.}"
	local c="${rest%%.*}"

	local reverse_zone="$c.$b.$a.in-addr.arpa"

	zone_file="$REVERSE_ZONE_DIR/$reverse_zone.zone"
	zone_conf="$REVERSE_ZONE_DIR/$reverse_zone.conf"

	if [ -f "$zone_file" ] || [ -f "$zone_conf" ]
	then
		die "Reverse zone already exists: $reverse_zone"
	fi

	serial="$(date +%s)"

	cat > "$zone_file" <<EOF
\$TTL 86400

@	IN	SOA	$SELECTED_NAMESERVER. admin.$reverse_zone. (
		$serial
		3600
		1800
		604800
		86400
)

@	IN	NS	$SELECTED_NAMESERVER.
EOF

	if [ "$?" -ne 0 ]
	then
		die "Failed to create reverse zone file."
	fi

	cat > "$zone_conf" <<EOF
zone "$reverse_zone" {
	type master;
	file "$zone_file";
};
EOF

	if [ "$?" -ne 0 ]
	then
		rm -f "$zone_file"
		die "Failed to create reverse zone configuration."
	fi

	cat >> "$NAMED_LOCAL" <<EOF

// Managed by dns-manager.sh
include "$zone_conf";
EOF

	validate_zone || {
		rm -f "$zone_file"
		rm -f "$zone_conf"
		return
	}

	reload_bind_service

	print_success "Reverse zone created: $reverse_zone"
}

remove_reverse_zone()
{
	local choice
	local zone_conf

	printf '\n'
	print_warning "Remove reverse zone: $SELECTED_ZONE"

	read -rp "Continue? [y/N]: " choice

	case "$choice" in
		y|Y)
			;;
		*)
			print_info "Operation cancelled."
			return
			;;
	esac

	zone_conf="$SELECTED_ZONE_CONF"

	remove_zone_configuration "$zone_conf"

	rm -f "$SELECTED_ZONE_FILE" ||
		die "Failed to remove reverse zone file."

	rm -f "$zone_conf" ||
		die "Failed to remove reverse zone configuration."

	reload_bind_service

	print_success "Reverse zone removed: $SELECTED_ZONE"

	SELECTED_ZONE=""
	SELECTED_ZONE_FILE=""
	SELECTED_ZONE_CONF=""
}

remove_zone_configuration()
{
	local zone_conf="$1"
	local temp_file

	temp_file="${NAMED_LOCAL}.tmp"

	awk -v conf="$zone_conf" '
		$0 != "include \"" conf "\";" {
			print
		}
	' "$NAMED_LOCAL" > "$temp_file" ||
		die "Failed to modify named.conf.local."

	mv "$temp_file" "$NAMED_LOCAL" ||
		die "Failed to update named.conf.local."
}

# ============================================================
# Record Menu
# ============================================================

show_record_menu()
{
	local choice

	printf '\n'
	printf '%s\n' "========================================"
	printf ' Zone: %s\n' "$SELECTED_ZONE"
	printf '%s\n' "========================================"
	printf '1. A\n'
	printf '2. AAAA\n'
	printf '3. CNAME\n'
	printf '4. MX\n'
	printf '5. NS\n'
	printf '6. TXT\n'
	printf '0. Back\n'

	read -rp "Record type: " choice

	case "$choice" in
		1)
			add_a_record
			;;
		2)
			add_aaaa_record
			;;
		3)
			add_cname_record
			;;
		4)
			add_mx_record
			;;
		5)
			add_ns_record
			;;
		6)
			add_txt_record
			;;
		0)
			return
			;;
		*)
			print_warning "Invalid choice."
			;;
	esac
}

# ============================================================
# Record Management
# ============================================================

add_record()
{
	show_record_menu
}

remove_record()
{
	local choice

	printf '\n'
	printf '%s\n' "Remove record:"
	printf '1. A\n'
	printf '2. AAAA\n'
	printf '3. CNAME\n'
	printf '4. MX\n'
	printf '5. NS\n'
	printf '6. TXT\n'
	printf '0. Back\n'

	read -rp "Record type: " choice

	case "$choice" in
		1)
			remove_a_record
			;;
		2)
			remove_aaaa_record
			;;
		3)
			remove_cname_record
			;;
		4)
			remove_mx_record
			;;
		5)
			remove_ns_record
			;;
		6)
			remove_txt_record
			;;
		0)
			return
			;;
		*)
			print_warning "Invalid choice."
			;;
	esac
}

list_records()
{
	if [ ! -f "$SELECTED_ZONE_FILE" ]
	then
		die "Zone file does not exist."
	fi

	printf '\n'
	printf '%s\n' "========================================"
	printf ' Records: %s\n' "$SELECTED_ZONE"
	printf '%s\n' "========================================"

	grep -vE '^[[:space:]]*$|^[[:space:]]*;|^[[:space:]]*\$TTL|^[[:space:]]*@.*SOA|^[[:space:]]*[0-9]+[[:space:]]*$' \
		"$SELECTED_ZONE_FILE"
}

# ============================================================
# Forward Record Types
# ============================================================

add_a_record()
{
	local name
	local value

	get_a_record_input name value

	append_zone_record "$name" "A" "$value"
}

remove_a_record()
{
	remove_record_by_type "A"
}

add_aaaa_record()
{
	local name
	local value

	get_aaaa_record_input name value

	append_zone_record "$name" "AAAA" "$value"
}

remove_aaaa_record()
{
	remove_record_by_type "AAAA"
}

add_cname_record()
{
	local name
	local value

	get_cname_record_input name value

	append_zone_record "$name" "CNAME" "$value"
}

remove_cname_record()
{
	remove_record_by_type "CNAME"
}

add_mx_record()
{
	local name
	local value
	local priority

	get_mx_record_input name priority value

	append_zone_record "$name" "MX" "$priority $value"
}

remove_mx_record()
{
	remove_record_by_type "MX"
}

add_ns_record()
{
	local name
	local value

	get_ns_record_input name value

	append_zone_record "$name" "NS" "$value"
}

remove_ns_record()
{
	remove_record_by_type "NS"
}

add_txt_record()
{
	local name
	local value

	get_txt_record_input name value

	append_zone_record "$name" "TXT" "\"$value\""
}

remove_txt_record()
{
	remove_record_by_type "TXT"
}

# ============================================================
# Reverse Records
# ============================================================

add_ptr_record()
{
	local name
	local value

	get_ptr_record_input name value

	append_zone_record "$name" "PTR" "$value"
}

remove_ptr_record()
{
	remove_record_by_type "PTR"
}

# ============================================================
# Record Input
# ============================================================

get_record_type()
{
	:
}

get_record_name()
{
	:
}

get_record_value()
{
	:
}

get_a_record_input()
{
	local _name_var="$1"
	local _value_var="$2"

	local name
	local value

	read -rp "Hostname: " name
	read -rp "IPv4 address: " value

	if [ -z "$name" ] || [ -z "$value" ]
	then
		print_warning "Hostname and IPv4 address are required."
		return 1
	fi

	printf -v "$_name_var" '%s' "$name"
	printf -v "$_value_var" '%s' "$value"
}

get_aaaa_record_input()
{
	local _name_var="$1"
	local _value_var="$2"

	local name
	local value

	read -rp "Hostname: " name
	read -rp "IPv6 address: " value

	if [ -z "$name" ] || [ -z "$value" ]
	then
		print_warning "Hostname and IPv6 address are required."
		return 1
	fi

	printf -v "$_name_var" '%s' "$name"
	printf -v "$_value_var" '%s' "$value"
}

get_cname_record_input()
{
	local _name_var="$1"
	local _value_var="$2"

	local name
	local value

	read -rp "Alias: " name
	read -rp "Canonical name: " value

	if [ -z "$name" ] || [ -z "$value" ]
	then
		print_warning "Alias and canonical name are required."
		return 1
	fi

	printf -v "$_name_var" '%s' "$name"
	printf -v "$_value_var" '%s' "$value"
}

get_mx_record_input()
{
	local _name_var="$1"
	local _priority_var="$2"
	local _value_var="$3"

	local name
	local priority
	local value

	read -rp "Domain: " name
	read -rp "Priority: " priority
	read -rp "Mail server: " value

	if [ -z "$name" ] ||
	   [ -z "$priority" ] ||
	   [ -z "$value" ]
	then
		print_warning "All MX fields are required."
		return 1
	fi

	printf -v "$_name_var" '%s' "$name"
	printf -v "$_priority_var" '%s' "$priority"
	printf -v "$_value_var" '%s' "$value"
}

get_ns_record_input()
{
	local _name_var="$1"
	local _value_var="$2"

	local name
	local value

	read -rp "Zone/name: " name
	read -rp "Nameserver: " value

	if [ -z "$name" ] || [ -z "$value" ]
	then
		print_warning "Name and nameserver are required."
		return 1
	fi

	printf -v "$_name_var" '%s' "$name"
	printf -v "$_value_var" '%s' "$value"
}

get_txt_record_input()
{
	local _name_var="$1"
	local _value_var="$2"

	local name
	local value

	read -rp "Name: " name
	read -rp "Text: " value

	if [ -z "$name" ] || [ -z "$value" ]
	then
		print_warning "Name and text are required."
		return 1
	fi

	printf -v "$_name_var" '%s' "$name"
	printf -v "$_value_var" '%s' "$value"
}

get_ptr_record_input()
{
	local _name_var="$1"
	local _value_var="$2"

	local name
	local value

	read -rp "Address portion: " name
	read -rp "Hostname: " value

	if [ -z "$name" ] || [ -z "$value" ]
	then
		print_warning "Address portion and hostname are required."
		return 1
	fi

	printf -v "$_name_var" '%s' "$name"
	printf -v "$_value_var" '%s' "$value"
}

# ============================================================
# Zone File Operations
# ============================================================

read_zone_file()
{
	cat "$SELECTED_ZONE_FILE"
}

write_zone_file()
{
	local content="$1"

	printf '%s\n' "$content" > "$SELECTED_ZONE_FILE" ||
		die "Failed to write zone file."
}

append_zone_record()
{
	local name="$1"
	local type="$2"
	local value="$3"

	if ! validate_record "$name" "$type" "$value"
	then
		return
	fi

	printf '%-20s IN\t%-8s %s\n' \
		"$name" \
		"$type" \
		"$value" >> "$SELECTED_ZONE_FILE" ||
		die "Failed to append record."

	update_zone_serial

	validate_zone || return

	reload_bind_service

	print_success "Record added."
}

remove_zone_record()
{
	local pattern="$1"
	local temp_file

	temp_file="${SELECTED_ZONE_FILE}.tmp"

	grep -v "$pattern" "$SELECTED_ZONE_FILE" > "$temp_file" ||
		true

	mv "$temp_file" "$SELECTED_ZONE_FILE" ||
		die "Failed to update zone file."

	update_zone_serial

	validate_zone || return

	reload_bind_service
}

remove_record_by_type()
{
	local type="$1"
	local name

	read -rp "Record name: " name

	if [ -z "$name" ]
	then
		print_warning "Record name cannot be empty."
		return
	fi

	if ! grep -Eq "^[[:space:]]*$name[[:space:]]+IN[[:space:]]+$type[[:space:]]" \
		"$SELECTED_ZONE_FILE"
	then
		print_warning "Record not found."
		return
	fi

	local temp_file

	temp_file="${SELECTED_ZONE_FILE}.tmp"

	grep -Ev "^[[:space:]]*$name[[:space:]]+IN[[:space:]]+$type[[:space:]]" \
		"$SELECTED_ZONE_FILE" > "$temp_file" ||
		die "Failed to modify zone file."

	mv "$temp_file" "$SELECTED_ZONE_FILE" ||
		die "Failed to update zone file."

	update_zone_serial

	validate_zone

	reload_bind_service

	print_success "Record removed."
}

# ============================================================
# Serial Number
# ============================================================

get_zone_serial()
{
	awk '
		/^[[:space:]]*[0-9]+[[:space:]]*$/ {
			print $1
			exit
		}
	' "$SELECTED_ZONE_FILE"
}

increment_zone_serial()
{
	local current_serial
	local current_time
	local new_serial

	current_serial="$(get_zone_serial)"
	current_time="$(date +%s)"

	if [ -z "$current_serial" ]
	then
		new_serial="$current_time"
	elif [ "$current_time" -gt "$current_serial" ]
	then
		new_serial="$current_time"
	else
		new_serial="$((current_serial + 1))"
	fi

	printf '%s\n' "$new_serial"
}

update_zone_serial()
{
	local old_serial
	local new_serial
	local temp_file

	old_serial="$(get_zone_serial)"
	new_serial="$(increment_zone_serial)"

	if [ -z "$old_serial" ]
	then
		die "Could not find zone serial."
	fi

	temp_file="${SELECTED_ZONE_FILE}.tmp"

	awk -v old="$old_serial" -v new="$new_serial" '
		$1 == old && $0 ~ /^[[:space:]]*[0-9]+[[:space:]]*$/ {
			sub(old, new)
			print
			next
		}

		{
			print
		}
	' "$SELECTED_ZONE_FILE" > "$temp_file" ||
		die "Failed to update zone serial."

	mv "$temp_file" "$SELECTED_ZONE_FILE" ||
		die "Failed to update zone file."

	print_info "Zone serial updated: $new_serial"
}

# ============================================================
# Validation
# ============================================================

validate_zone()
{
	print_info "Validating zone: $SELECTED_ZONE"

	if [[ "$SELECTED_ZONE" == *.in-addr.arpa ]]
	then
		named-checkzone "$SELECTED_ZONE" "$SELECTED_ZONE_FILE" ||
			die "Zone validation failed."
	else
		named-checkzone "$SELECTED_ZONE" "$SELECTED_ZONE_FILE" ||
			die "Zone validation failed."
	fi

	print_success "Zone is valid."
}

validate_record()
{
	local name="$1"
	local type="$2"
	local value="$3"

	case "$type" in
		A)
			validate_a_record "$value"
			;;
		AAAA)
			validate_aaaa_record "$value"
			;;
		CNAME|NS|PTR)
			validate_hostname "$value"
			;;
		MX)
			:
			;;
		TXT)
			:
			;;
		*)
			print_warning "Unsupported record type: $type"
			return 1
			;;
	esac
}

validate_a_record()
{
	local ip="$1"

	validate_ip_address "$ip"
}

validate_aaaa_record()
{
	local ip="$1"

	if ! [[ "$ip" =~ : ]]
	then
		print_warning "Invalid IPv6 address."
		return 1
	fi
}

validate_hostname()
{
	local hostname="$1"

	if [ -z "$hostname" ]
	then
		print_warning "Hostname cannot be empty."
		return 1
	fi

	if ! [[ "$hostname" =~ ^[A-Za-z0-9._-]+\.?$ ]]
	then
		print_warning "Invalid hostname: $hostname"
		return 1
	fi
}

validate_ip_address()
{
	local ip="$1"

	local IFS='.'
	local octets
	local octet

	read -ra octets <<< "$ip"

	if [ "${#octets[@]}" -ne 4 ]
	then
		print_warning "Invalid IPv4 address: $ip"
		return 1
	fi

	for octet in "${octets[@]}"
	do
		if ! [[ "$octet" =~ ^[0-9]+$ ]]
		then
			print_warning "Invalid IPv4 address: $ip"
			return 1
		fi

		if [ "$octet" -lt 0 ] || [ "$octet" -gt 255 ]
		then
			print_warning "Invalid IPv4 address: $ip"
			return 1
		fi
	done
}

# ============================================================
# Nameserver Validation
# ============================================================

validate_nameserver()
{
	if [ -z "$SELECTED_NAMESERVER" ]
	then
		print_warning "No nameserver selected."
		return 1
	fi

	if ! grep -Fq \
		"${SELECTED_NAMESERVER}|${SELECTED_NAMESERVER_IP}" \
		"$NAMESERVER_FILE"
	then
		print_warning "Selected nameserver is no longer registered."
		return 1
	fi
}

# ============================================================
# BIND Operations
# ============================================================

validate_bind_config()
{
	named-checkconf ||
		die "BIND configuration validation failed."

	print_success "BIND configuration is valid."
}

reload_bind_service()
{
	print_info "Reloading named..."

	validate_bind_config

	systemctl reload named ||
		die "Failed to reload named."

	print_success "named reloaded."
}

# ============================================================
# Status / Output
# ============================================================

show_nameserver_summary()
{
	printf '\n'
	printf '%s\n' "========================================"
	printf '%s\n' " Nameserver"
	printf '%s\n' "========================================"
	printf 'Hostname : %s\n' "$SELECTED_NAMESERVER"
	printf 'IP       : %s\n' "$SELECTED_NAMESERVER_IP"
	printf '%s\n' "========================================"
}

show_zone_summary()
{
	printf '\n'
	printf '%s\n' "========================================"
	printf '%s\n' " Zone"
	printf '%s\n' "========================================"
	printf 'Zone     : %s\n' "$SELECTED_ZONE"
	printf 'File     : %s\n' "$SELECTED_ZONE_FILE"
	printf '%s\n' "========================================"
}

show_record_summary()
{
	:
}

# ============================================================
# Main Workflow
# ============================================================

main()
{
	check_privilege

	print_info "Starting DNS manager..."

	load_config
	initialize_manager

	while true
	do
		if ! show_main_menu
		then
			break
		fi
	done

	print_success "DNS manager exited."
}

main "$@"