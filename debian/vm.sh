#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

# --- first-boot config (edit me) ---
HOSTNAME="debian-dev"
USERNAME="dev"
DISK_SIZE="20G"
MEMORY="4G"
CPUS=4
SSH_PORT=2222
PACKAGES=(build-essential git vim usbutils)
RUNCMD=(
  "echo hello from cloud-init"
)
# -----------------------------------

IMAGE_URL="https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2"
QCOW2="debian.qcow2"
FIRMWARE="edk2-aarch64-code.fd"
VARSTORE="varstore.img"
KEY="vm_key"
SEED_DIR="seed"
SEED_ISO="seed.iso"
PASSWORD_FILE="vm_password"

# Optional console password for $USERNAME, so the serial console is usable and
# not just SSH. Taken from $VM_PASSWORD, else the first line of ./vm_password
# (both untracked). Empty means no password: the account stays locked and the
# SSH key is the only way in. SSH stays key-only either way (ssh_pwauth: false).
PASSWORD="${VM_PASSWORD:-}"
if [ -z "$PASSWORD" ] && [ -f "$PASSWORD_FILE" ]; then
  PASSWORD="$(head -n 1 "$PASSWORD_FILE")"
fi

for bin in qemu-system-aarch64 qemu-img hdiutil ssh-keygen curl brew; do
  command -v "$bin" >/dev/null || { echo "missing dependency: $bin" >&2; exit 1; }
done

# 1. Cloud image
if [ ! -f "$QCOW2" ]; then
  echo "==> Downloading Debian cloud image"
  curl -L -o "$QCOW2" "$IMAGE_URL"
  echo "==> Resizing disk to $DISK_SIZE"
  qemu-img resize "$QCOW2" "$DISK_SIZE"
fi

# 2. UEFI firmware
if [ ! -f "$FIRMWARE" ]; then
  echo "==> Copying UEFI firmware"
  cp "$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd" "$FIRMWARE"
fi

# 3. NVRAM varstore
if [ ! -f "$VARSTORE" ]; then
  echo "==> Creating NVRAM varstore"
  dd if=/dev/zero of="$VARSTORE" bs=1m count=64
fi

# 4. SSH keypair
if [ ! -f "$KEY" ]; then
  echo "==> Generating SSH keypair"
  ssh-keygen -t ed25519 -f "$KEY" -N "" -C "qemu-debian"
fi

# 5. Cloud-init seed (regenerated every run so config edits take effect on next
#    first boot; to re-apply on an already-initialised VM, run inside it:
#    sudo cloud-init clean && sudo reboot)
echo "==> Building cloud-init seed"
mkdir -p "$SEED_DIR"

cat > "$SEED_DIR/meta-data" <<EOF
instance-id: $HOSTNAME
local-hostname: $HOSTNAME
EOF

{
  echo "#cloud-config"
  echo "hostname: $HOSTNAME"
  echo "users:"
  echo "  - name: $USERNAME"
  echo "    sudo: ALL=(ALL) NOPASSWD:ALL"
  echo "    shell: /bin/bash"
  if [ -n "$PASSWORD" ]; then
    # lock_passwd defaults to true, which is what makes console login
    # impossible; unlock it and hand cloud-init the plaintext. Escaped for a
    # YAML double-quoted scalar.
    esc=${PASSWORD//\\/\\\\}
    esc=${esc//\"/\\\"}
    echo "    lock_passwd: false"
    echo "    plain_text_passwd: \"$esc\""
  fi
  echo "    ssh_authorized_keys:"
  echo "      - $(cat "$KEY.pub")"
  echo "ssh_pwauth: false"
  if [ "${#PACKAGES[@]}" -gt 0 ]; then
    echo "package_update: true"
    echo "packages:"
    for pkg in "${PACKAGES[@]}"; do
      echo "  - $pkg"
    done
  fi
  if [ "${#RUNCMD[@]}" -gt 0 ]; then
    echo "runcmd:"
    for cmd in "${RUNCMD[@]}"; do
      printf '  - %s\n' "$cmd"
    done
  fi
} > "$SEED_DIR/user-data"

rm -f "$SEED_ISO"
hdiutil makehybrid -iso -joliet -default-volume-name cidata -o "$SEED_ISO" "$SEED_DIR/" >/dev/null

# 6. Boot
echo "==> Booting VM (Ctrl-A X to quit; ssh -i $KEY -p $SSH_PORT $USERNAME@localhost)"
if [ -n "$PASSWORD" ]; then
  echo "==> Console login enabled for '$USERNAME'"
else
  echo "==> Console login disabled (SSH key only); see \$VM_PASSWORD in $0"
fi
exec qemu-system-aarch64 \
  -machine virt,accel=hvf \
  -cpu host \
  -smp "$CPUS" -m "$MEMORY" \
  -drive if=pflash,format=raw,readonly=on,file="$FIRMWARE" \
  -drive if=pflash,format=raw,file="$VARSTORE" \
  -drive if=virtio,format=qcow2,file="$QCOW2" \
  -drive if=virtio,format=raw,file="$SEED_ISO" \
  -netdev user,id=n0,hostfwd=tcp::"$SSH_PORT"-:22 \
  -device virtio-net-pci,netdev=n0 \
  -nographic
