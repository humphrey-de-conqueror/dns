# dns-server

A collection of Bash scripts to set up and manage a BIND9 DNS server on Debian/Ubuntu systems.
Covers forward DNS, reverse DNS, and zone management — each component is standalone and can be
run independently.

## Structure

dns-server/
├── forward/
│   ├── setup-forward.sh    # install BIND9 and configure forward zone
│   └── manage.sh           # add, remove, and list A records
├── reverse/
│   ├── setup-reverse.sh    # install BIND9 and append reverse zone
│   └── manage-reverse.sh   # add, remove, and list PTR records
└── zones.sh                # list and remove declared zones

## Usage

### Forward DNS

```bash
sudo bash forward/setup-forward.sh
```

Prompts for:
- **Server IP** — IP of the machine running BIND9 (required)
- **Domain name** — zone name, e.g. `example.com` (default: `example.com`)
- **DNS forwarder** — upstream resolver (default: `8.8.8.8`)
- **Nameserver hostname** — e.g. `ns1` (default: `ns1`)

Once setup is done, manage A records:

```bash
sudo bash forward/manage.sh
```

### Reverse DNS

```bash
sudo bash reverse/setup-reverse.sh
```

Prompts for the same inputs as forward. The reverse zone is derived automatically from the
server IP — for example `192.168.0.239` becomes `0.168.192.in-addr.arpa`.

Forward and reverse can coexist — `setup-reverse.sh` appends to `named.conf.local` without
overwriting the forward zone. Run order does not matter.

Once setup is done, manage PTR records:

```bash
sudo bash reverse/manage-reverse.sh
```

PTR records require a fully qualified domain name with a trailing dot, e.g. `webserver.example.com.`

### Zone Manager

List all declared zones and optionally remove one:

```bash
sudo bash zones.sh
```

Removing a zone deletes both its declaration from `named.conf.local` and its zone file from
`/etc/bind/`. BIND9 is reloaded automatically after every change.

## Requirements

- Debian or Ubuntu
- Root privileges (`sudo`)
- Internet access for `apt-get` during setup

## Testing

After setup, verify with `dig`:

```bash
# forward lookup
dig @<server-ip> <hostname>.<domain> A +short

# reverse lookup
dig @<server-ip> -x <server-ip> +short
```