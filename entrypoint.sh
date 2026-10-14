#!/bin/bash
set -e
/usr/local/bin/init-firewall.sh
exec runuser -u node -- sleep infinity
