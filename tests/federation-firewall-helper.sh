#!/usr/bin/env bash
# Exercise Federation's firewall policy with a veth-backed guest namespace.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
helper="$root/bin/federation-firewall-helper"
suffix="$$"
namespace="wf-fw-$suffix"
tap="wffw$suffix"
guest="wfgw$suffix"
vm_cidr="198.18.0.2/30"
host_ip="198.18.0.1"
forward_chain="WFFW_${tap//-/_}"
input_chain="${forward_chain}_IN"

static_validate() {
  bash -n "$helper"
  grep -Fq -- '-d 10.0.0.0/8 -j DROP' "$helper"
  grep -Fq -- '-d 172.16.0.0/12 -j DROP' "$helper"
  grep -Fq -- '-d 192.168.0.0/16 -j DROP' "$helper"
  grep -Fq -- '-d 169.254.0.0/16 -j DROP' "$helper"
  grep -Fq -- '-A "$input_chain" -s "$vm_ip_cidr" -j DROP' "$helper"
  grep -Fq -- '-j MASQUERADE' "$helper"
  echo "STATIC OK: helper parses and contains NAT, host, RFC1918, and link-local deny policy"
}

has_net_admin() {
  local cap_eff
  cap_eff="$(awk '/^CapEff:/ { print $2 }' /proc/self/status)"
  (( (16#$cap_eff & 0x1000) != 0 ))
}

static_validate
if ! has_net_admin; then
  echo "SKIP: requires root — run under privileged CI (CAP_NET_ADMIN is also sufficient)"
  exit 0
fi

cleanup() {
  local status=$?
  "$helper" down "$tap" >/dev/null 2>&1 || true
  ip netns del "$namespace" 2>/dev/null || true
  return "$status"
}
trap cleanup EXIT

assert_denied() {
  local destination=$1 label=$2
  if timeout 3 ip netns exec "$namespace" ping -n -c 1 -W 1 "$destination" >/dev/null 2>&1; then
    echo "FAIL: $label ($destination) was reachable" >&2
    exit 1
  fi
  echo "DENIED: $label ($destination)"
}

ip netns add "$namespace"
ip link add "$tap" type veth peer name "$guest"
ip link set "$guest" netns "$namespace"
ip -n "$namespace" link set lo up
ip -n "$namespace" link set "$guest" up
ip -n "$namespace" addr add "$vm_cidr" dev "$guest"
ip -n "$namespace" route add default via "$host_ip"

"$helper" up "$tap" "$vm_cidr" "$host_ip"

# Prove locally delivered host traffic as well as forwarded private/link-local
# destinations are denied. Each destination must traverse the installed policy.
assert_denied "$host_ip" "host TAP IP"
assert_denied 192.168.250.1 "RFC1918 LAN"
assert_denied 10.250.250.1 "RFC1918 LAN"
assert_denied 169.254.169.254 "link-local metadata"

if timeout 5 ip netns exec "$namespace" ping -n -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
  echo "INTERNET OK: 1.1.1.1"
else
  echo "SKIP: internet egress could not be confirmed from this host; deny checks passed"
fi

"$helper" down "$tap"
"$helper" down "$tap"
! ip link show dev "$tap" >/dev/null 2>&1
! iptables -S | grep -Fq "$forward_chain"
! iptables -S | grep -Fq "$input_chain"
! iptables -t nat -S | grep -Fq "$vm_cidr"
echo "CLEAN: interface and scoped rules removed; second down was idempotent"
