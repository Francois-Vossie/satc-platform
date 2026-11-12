#!/bin/bash
set -euo pipefail
pip3 install --quiet -r /opt/satc/requirements.txt
# load the build version into the service environment
if [ -f /opt/satc/app.env ]; then
  mkdir -p /etc/systemd/system/satc.service.d
  printf '[Service]\nEnvironmentFile=/opt/satc/app.env\n' > /etc/systemd/system/satc.service.d/version.conf
  systemctl daemon-reload
fi
