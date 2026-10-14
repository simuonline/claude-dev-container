#!/bin/bash
# Gehärtete Variante der Anthropic-Devcontainer-Firewall
# Änderungen ggü. Original:
#  - kein Zugriff auf Docker-Host/Host-Netz (nur eingehend Port 4321 für Astro-Dev-Server)
#  - kein ausgehendes SSH zu beliebigen Zielen (nur zu GitHub)
#  - sentry.io / statsig.com entfernt (Telemetrie via CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 abschalten)
#  - Login-Domains ergänzt (prüfen!)
#  - IPv6 komplett gesperrt
set -euo pipefail
IFS=$'\n\t'

DEV_PORT=4321

# 1. Docker-DNS-Regeln sichern, bevor alles geleert wird
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# 2. Nur das interne Docker-DNS wiederherstellen
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# DNS und localhost
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allowlist
ipset create allowed-domains hash:net

echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    ipset add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

for domain in \
    "api.github.com" \
    "github.com" \
    "codeload.github.com" \
    "objects.githubusercontent.com" \
    "registry.npmjs.org" \
    "api.anthropic.com" \
    "claude.ai" \
    "console.anthropic.com" \
    "marketplace.visualstudio.com" \
    "vscode.blob.core.windows.net" \
    "update.code.visualstudio.com"; do
    echo "Resolving $domain..."
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: Failed to resolve $domain"
        exit 1
    fi
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        ipset add allowed-domains "$ip" -exist
    done < <(echo "$ips")
done

# Default: alles sperren
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Eingehend nur Astro-Dev-Server (Port ist im Stack nur an 127.0.0.1 des Hosts gebunden)
iptables -A INPUT -p tcp --dport "$DEV_PORT" -j ACCEPT

# Ausgehend nur Allowlist (inkl. SSH, aber nur zu GitHub)
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# IPv6 komplett sperren (falls verfügbar)
if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -P INPUT DROP 2>/dev/null || true
    ip6tables -P FORWARD DROP 2>/dev/null || true
    ip6tables -P OUTPUT DROP 2>/dev/null || true
fi

echo "Firewall configuration complete"

# Verifikation
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - reached https://example.com"
    exit 1
fi
echo "OK: https://example.com blocked"

if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - cannot reach https://api.github.com"
    exit 1
fi
echo "OK: https://api.github.com reachable"
