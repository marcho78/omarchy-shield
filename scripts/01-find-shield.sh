#!/usr/bin/env bash
# Find the SHIELD on the LAN and print its IPv4 address. Read-only.
#
# Uses the SHIELD's Google Cast mDNS record, then confirms the product name
# through the Cast setup API, so other Android TV boxes on the network are
# never mistaken for it.
#
# Usage: scripts/01-find-shield.sh [--quiet]
source "$(dirname "$0")/lib.sh"
need avahi-browse curl

quiet=${1:-}
found=()
while read -r addr; do
  product=$(curl -sk -m 5 "https://$addr:8443/setup/eureka_info?params=device_info" |
    grep -o '"product_name":"[^"]*"' | cut -d'"' -f4 || true)
  if [[ -z $quiet ]]; then
    log "$addr: SHIELD Android TV, product '${product:-unknown}'"
  fi
  if [[ $product == "$SHIELD_PRODUCT" ]]; then
    found+=("$addr")
  fi
done < <(avahi-browse -rpt _googlecast._tcp 2>/dev/null |
  awk -F';' '$1 == "=" && $3 == "IPv4" && $10 ~ /md=SHIELD Android TV/ { print $8 }' | sort -u)

case ${#found[@]} in
  0) die "no SHIELD with product '$SHIELD_PRODUCT' found on the LAN; set SHIELD_IP=<address> instead" ;;
  1) echo "${found[0]}" ;;
  *) die "several matching SHIELDs (${found[*]}); pick one with SHIELD_IP=<address>" ;;
esac
