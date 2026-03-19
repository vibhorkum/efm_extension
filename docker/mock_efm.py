#!/usr/bin/python3
"""
Mock EFM binary for testing efm_extension

This script simulates EFM commands for testing purposes.
It can be configured to simulate various scenarios including:
- Normal operation
- EFM agent down
- Timeout scenarios
- Various error conditions

Environment variables:
- MOCK_EFM_MODE: normal, down, timeout, error
- MOCK_EFM_DELAY: seconds to delay response (simulates slow EFM)
"""

import sys
import os
import json
import time

# Configuration from environment
MODE = os.environ.get('MOCK_EFM_MODE', 'normal')
DELAY = float(os.environ.get('MOCK_EFM_DELAY', '0'))

# Mock cluster status data
MOCK_CLUSTER_STATUS_JSON = {
    "nodes": {
        "172.17.0.2": {
            "type": "Primary",
            "agent": "UP",
            "db": "UP",
            "info": "",
            "xlog": "0/50001234",
            "xloginfo": "DB is primary"
        },
        "172.17.0.3": {
            "type": "Standby",
            "agent": "UP",
            "db": "UP",
            "info": "",
            "xlog": "0/50001234",
            "xloginfo": "Streaming from primary"
        }
    },
    "allowednodes": ["172.17.0.2", "172.17.0.3"],
    "membershipcoordinator": "172.17.0.2",
    "failoverpriority": ["172.17.0.3"],
    "VIP": "",
    "minimumstandbys": 0,
    "messages": []
}

MOCK_CLUSTER_STATUS_TEXT = """Cluster Status: efm
VIP:

        Agent Type  Address              Agent  DB       Info
        --------------------------------------------------------------
        Primary     172.17.0.2           UP     UP
        Standby     172.17.0.3           UP     UP

Allowed node host list:
        172.17.0.2
        172.17.0.3

Membership coordinator: 172.17.0.2

Standby priority host list:
        172.17.0.3

Promote Status:


DB Type/Status (from PG):

        Address              Type         Status
        --------------------------------------------------------------
        172.17.0.2           Primary      UP
        172.17.0.3           Standby      UP
"""


def simulate_delay():
    """Simulate command execution delay"""
    if DELAY > 0:
        time.sleep(DELAY)


def handle_cluster_status(cluster_name):
    """Handle cluster-status command"""
    simulate_delay()

    if MODE == 'down':
        print("Error: EFM agent is not running", file=sys.stderr)
        return 3

    if MODE == 'timeout':
        # Simulate timeout by sleeping longer than the timeout
        time.sleep(60)
        return 0

    if MODE == 'error':
        print("Error: Cluster not found", file=sys.stderr)
        return 1

    print(MOCK_CLUSTER_STATUS_TEXT)
    return 0


def handle_cluster_status_json(cluster_name):
    """Handle cluster-status-json command"""
    simulate_delay()

    if MODE == 'down':
        print("Error: EFM agent is not running", file=sys.stderr)
        return 3

    if MODE == 'timeout':
        time.sleep(60)
        return 0

    if MODE == 'error':
        print(json.dumps({"error": "Cluster not found"}), file=sys.stderr)
        return 1

    print(json.dumps(MOCK_CLUSTER_STATUS_JSON))
    return 0


def handle_allow_node(cluster_name, ip_address):
    """Handle allow-node command"""
    simulate_delay()

    if MODE == 'down':
        print("Error: EFM agent is not running", file=sys.stderr)
        return 3

    print(f"Allowed node {ip_address}")
    return 0


def handle_disallow_node(cluster_name, ip_address):
    """Handle disallow-node command"""
    simulate_delay()

    if MODE == 'down':
        print("Error: EFM agent is not running", file=sys.stderr)
        return 3

    print(f"Disallowed node {ip_address}")
    return 0


def handle_set_priority(cluster_name, ip_address, priority):
    """Handle set-priority command"""
    simulate_delay()

    if MODE == 'down':
        print("Error: EFM agent is not running", file=sys.stderr)
        return 3

    print(f"Set priority for {ip_address} to {priority}")
    return 0


def handle_promote(cluster_name, switchover=False):
    """Handle promote command"""
    simulate_delay()

    if MODE == 'down':
        print("Error: EFM agent is not running", file=sys.stderr)
        return 3

    if switchover:
        print("Switchover initiated")
    else:
        print("Failover initiated")
    return 0


def handle_resume(cluster_name):
    """Handle resume command"""
    simulate_delay()

    if MODE == 'down':
        print("Error: EFM agent is not running", file=sys.stderr)
        return 3

    print("Monitoring resumed")
    return 0


def main():
    if len(sys.argv) < 3:
        print("Usage: efm <command> <cluster> [args...]", file=sys.stderr)
        return 1

    command = sys.argv[1]
    cluster_name = sys.argv[2]

    if command == 'cluster-status':
        return handle_cluster_status(cluster_name)

    elif command == 'cluster-status-json':
        return handle_cluster_status_json(cluster_name)

    elif command == 'allow-node':
        if len(sys.argv) < 4:
            print("Usage: efm allow-node <cluster> <ip>", file=sys.stderr)
            return 1
        return handle_allow_node(cluster_name, sys.argv[3])

    elif command == 'disallow-node':
        if len(sys.argv) < 4:
            print("Usage: efm disallow-node <cluster> <ip>", file=sys.stderr)
            return 1
        return handle_disallow_node(cluster_name, sys.argv[3])

    elif command == 'set-priority':
        if len(sys.argv) < 5:
            print("Usage: efm set-priority <cluster> <ip> <priority>", file=sys.stderr)
            return 1
        return handle_set_priority(cluster_name, sys.argv[3], sys.argv[4])

    elif command == 'promote':
        switchover = '-switchover' in sys.argv
        return handle_promote(cluster_name, switchover)

    elif command == 'resume':
        return handle_resume(cluster_name)

    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
