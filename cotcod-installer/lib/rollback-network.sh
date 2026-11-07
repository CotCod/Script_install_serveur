#!/usr/bin/env bash
set -Eeuo pipefail

archive=$1
kind=$2
interface=$3

case "$kind" in
    netplan)
        rm -f -- /etc/netplan/99-cotcod.yaml
        tar -C /etc -xzf "$archive" netplan
        netplan apply || true
        ;;
    ifupdown)
        rm -f -- /etc/network/interfaces.d/99-cotcod.cfg
        tar -C /etc -xzf "$archive" network
        ifdown --force "$interface" || true
        ifup "$interface" || true
        systemctl restart networking || true
        ;;
    *) exit 2 ;;
esac
