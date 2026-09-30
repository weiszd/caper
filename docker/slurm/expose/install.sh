#!/usr/bin/env bash
# Install caper-expose (run as root). Safe while caper-server is running:
# only populates /srv/caper-view; the container doesn't use it until recreated.
set -euo pipefail
cd "$(dirname "$0")"
install -m 755 -o root -g root caper-expose /usr/local/sbin/caper-expose
[[ -e /etc/caper-expose.conf ]] || install -m 644 -o root -g root caper-expose.conf /etc/caper-expose.conf
install -m 644 -o root -g root caper-expose.service /etc/systemd/system/caper-expose.service
systemctl daemon-reload
systemctl enable --now caper-expose.service
/usr/local/sbin/caper-expose list
