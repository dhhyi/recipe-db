#!/usr/bin/python3
"""Reject unsafe network policy inputs before changing host access."""

import ipaddress
import json
import os
import sys


PRIVATE = [ipaddress.ip_network(cidr) for cidr in (
    "10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16", "fc00::/7",
)]


def validate_networks(admin, application, source):
    groups = []
    for entries in (admin, application):
        if not isinstance(entries, list) or not entries:
            raise ValueError("admin/application networks must be nonempty lists")
        networks = []
        for value in entries:
            network = ipaddress.ip_network(value, strict=True)
            if not any(network.version == private.version and network.subnet_of(private)
                       for private in PRIVATE):
                raise ValueError("only explicit RFC1918 or IPv6 ULA networks are allowed")
            networks.append(network)
        groups.append(networks)
    if not any(ipaddress.ip_address(source) in network for network in groups[0]):
        raise ValueError("current SSH source is outside admin_networks; refusing lockout")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 3:
            raise ValueError("usage: network-preflight ADMIN_JSON APPLICATION_JSON")
        source = os.environ.get("SSH_CONNECTION", "").split()
        if len(source) != 4:
            raise ValueError("cannot determine current SSH source")
        validate_networks(json.loads(sys.argv[1]), json.loads(sys.argv[2]), source[0])
        print("Private network policy includes current SSH source")
    except (ValueError, TypeError) as error:
        print(f"recipe-db network preflight failed: {error}", file=sys.stderr)
        sys.exit(1)
