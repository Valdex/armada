#!/bin/bash
set -euxo pipefail

# SSC gyro daemons built in the Containerfile's sensors-build stage.
install -m 0755 /packages/rpmini-sensors/adsprpcd /usr/bin/adsprpcd
install -m 0755 /packages/rpmini-sensors/snsfeed /usr/bin/snsfeed

# linux-firmware ships the Thundercomm RB5 slpi.mbn.xz at the same path; drop
# it so the Retroid stock slpi.mbn from system_files is the only candidate.
rm -f /usr/lib/firmware/qcom/sm8250/slpi.mbn.xz
chmod 0755 /usr/libexec/armada/rpmini-sensors-start

# Unit is inert (ConditionPathExists) until the Android sensor registry dump
# lands in system_files/usr/share/qcom-hexagon-fs.
systemctl enable rpmini-sensors.service
