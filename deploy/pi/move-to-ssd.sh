#!/bin/bash
# move-to-ssd.sh /dev/sdX  — OPTIONAL. ERASES /dev/sdX, then moves Docker (images, containers,
# logs) and the system journal onto it, so the SD card only holds the OS. Run with sudo.
# The Pi keeps booting from the SD card; without the SSD attached it still boots, but the
# bridge stays down until the SSD is back.
set -euo pipefail
log() { echo "[$(date +%T)] $*"; }
DEV="${1:?usage: sudo ./move-to-ssd.sh /dev/sdX   (see: lsblk -o NAME,SIZE,MODEL,TRAN)}"
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
MODEL=$(lsblk -dno MODEL "$DEV" | xargs); TRAN=$(lsblk -dno TRAN "$DEV" | xargs)
[ "$TRAN" = usb ] || { log "ABORT: $DEV is not a USB disk ($TRAN)"; exit 1; }
echo "This ERASES $DEV ($MODEL, $(lsblk -dno SIZE "$DEV")). Type ERASE to continue:"; read -r ok
[ "$ok" = ERASE ] || { echo "aborted"; exit 1; }
findmnt -rno SOURCE / | grep -q mmcblk0 || { log "ABORT: root is not on the SD card"; exit 1; }
log "target $DEV = $MODEL ($TRAN), root on SD: ok"
# --- 1. wipe + one ext4 partition
for m in $(lsblk -lnpo MOUNTPOINT "$DEV" | grep -v '^$'); do umount "$m"; done
wipefs -aq "$DEV"
parted -s "$DEV" mklabel gpt mkpart bridge-ssd ext4 1MiB 100%
udevadm settle; sleep 2
PART=$(lsblk -lnpo NAME,TYPE "$DEV" | awk '$2=="part"{print $1; exit}')
mkfs.ext4 -q -F -L bridge-ssd "$PART"
UUID=$(blkid -s UUID -o value "$PART"); log "formatted $PART ext4 UUID=$UUID"
# --- 2. mount by UUID; nofail so the Pi still boots without the drive
mkdir -p /srv/ssd
sed -i '\#/srv/ssd#d' /etc/fstab
echo "UUID=$UUID /srv/ssd ext4 defaults,noatime,nofail,x-systemd.device-timeout=15 0 2" >> /etc/fstab
systemctl daemon-reload; mount /srv/ssd; log "mounted: $(df -h /srv/ssd | tail -1 | awk '{print $2" total, "$4" free"}')"
# --- 3. docker data-root and containerd's image store -> SSD
# (Docker >= 29 keeps image layers in /var/lib/containerd, not in its data-root)
log "stopping docker (cameras pause)"
systemctl stop docker.socket docker containerd
mkdir -p /srv/ssd/docker /srv/ssd/containerd
rsync -aHAX --numeric-ids /var/lib/docker/ /srv/ssd/docker/
rsync -aHAX --numeric-ids /var/lib/containerd/ /srv/ssd/containerd/
python3 - <<'PY'
import json, os
p = "/etc/docker/daemon.json"
d = json.load(open(p)) if os.path.exists(p) and os.path.getsize(p) else {}
d["data-root"] = "/srv/ssd/docker"
d.setdefault("log-driver", "json-file")
d.setdefault("log-opts", {"max-size": "10m", "max-file": "3"})
json.dump(d, open(p, "w"), indent=2)
PY
rm -rf /var/lib/docker && mv /var/lib/containerd /var/lib/containerd.old && mkdir -p /var/lib/containerd
sed -i '\#/var/lib/containerd#d' /etc/fstab
echo "/srv/ssd/containerd /var/lib/containerd none bind,nofail,x-systemd.requires-mounts-for=/srv/ssd 0 0" >> /etc/fstab
for u in docker containerd; do
  mkdir -p /etc/systemd/system/$u.service.d
  printf '[Unit]\nRequiresMountsFor=/srv/ssd /var/lib/containerd\n' > /etc/systemd/system/$u.service.d/ssd.conf
done
systemctl daemon-reload; mount /var/lib/containerd; rm -rf /var/lib/containerd.old
systemctl start containerd docker
log "docker root: $(docker info -f '{{.DockerRootDir}}')"
# --- 4. persistent journal on the SSD (bind mount)
mkdir -p /srv/ssd/journal /var/log/journal
if ! findmnt -rno TARGET /var/log/journal >/dev/null; then
  rsync -a /var/log/journal/ /srv/ssd/journal/ 2>/dev/null || true
  sed -i '\#/var/log/journal#d' /etc/fstab
  echo "/srv/ssd/journal /var/log/journal none bind,nofail,x-systemd.requires-mounts-for=/srv/ssd 0 0" >> /etc/fstab
  systemctl daemon-reload; mount /var/log/journal
  systemd-tmpfiles --create --prefix /var/log/journal; systemctl restart systemd-journald
fi
log "journal on: $(findmnt -rno SOURCE /var/log/journal)"
log DONE
