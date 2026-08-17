# Lightweight Debian ARM64 VM on macOS (Apple Silicon)

A minimal reproducible setup for running Debian 12 (Bookworm) under QEMU with
HVF acceleration on Apple Silicon. Used for kernel-module development and
driver experiments.

## Prerequisites

- Apple Silicon Mac (M1 or newer)
- Homebrew installed
- QEMU: `brew install qemu`

## One-time setup

Run from this directory.

### 1. Download the Debian generic cloud image (~350 MB)

```bash
curl -L -o debian.qcow2 \
  https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-genericcloud-arm64.qcow2
```

### 2. Resize the virtual disk

```bash
qemu-img resize debian.qcow2 20G
```

### 3. Copy UEFI firmware and create writable NVRAM

```bash
cp "$(brew --prefix qemu)/share/qemu/edk2-aarch64-code.fd" .
dd if=/dev/zero of=varstore.img bs=1m count=64
```

### 4. Generate a dedicated SSH key for the VM

```bash
ssh-keygen -t ed25519 -f vm_key -N "" -C "qemu-debian"
```

### 5. Build the cloud-init seed ISO

Cloud-init reads this on first boot to create the user and install the SSH key.

```bash
mkdir -p seed

cat > seed/meta-data <<EOF
instance-id: debian-dev
local-hostname: debian-dev
EOF

cat > seed/user-data <<EOF
#cloud-config
users:
  - name: dev
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat vm_key.pub)
ssh_pwauth: false
EOF

hdiutil makehybrid -iso -joliet -default-volume-name cidata -o seed.iso seed/
```

### 6. Write the launch script

```bash
cat > start.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
qemu-system-aarch64 \
  -machine virt,accel=hvf \
  -cpu host \
  -smp 4 -m 4G \
  -drive if=pflash,format=raw,readonly=on,file=edk2-aarch64-code.fd \
  -drive if=pflash,format=raw,file=varstore.img \
  -drive if=virtio,format=qcow2,file=debian.qcow2 \
  -drive if=virtio,format=raw,file=seed.iso \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=n0 \
  -nographic
EOF
chmod +x start.sh
```

Verify the script is clean (should output `2`):

```bash
grep -c netdev start.sh
```

## Daily use

### Start the VM

```bash
./start.sh
```

The terminal becomes the VM's serial console. First boot takes ~1 minute as
cloud-init runs. Quit with `Ctrl-A` then `X`.

### SSH in from a second terminal

```bash
ssh -i vm_key -p 2222 dev@localhost
```

### Console password (optional)

By default `dev` has no password: the account is locked, so the serial console
stops at an unusable `login:` prompt and the SSH key is the only way in. To
enable console login, give `vm.sh` a password by either route:

```bash
VM_PASSWORD='hunter2' ./vm.sh     # one-off
echo 'hunter2' > vm_password      # persistent; untracked, first line is used
```

`vm.sh` then emits `lock_passwd: false` and `plain_text_passwd` into the seed.
SSH remains key-only regardless (`ssh_pwauth: false`), so this only affects the
console. The password lands in `seed/user-data` and `seed.iso` in plaintext —
both are gitignored, but treat them as secrets.

This applies on a VM's *first* boot. On an already-initialised VM, either run
`sudo cloud-init clean && sudo reboot` inside it to re-apply, or just set the
password directly (sudo is passwordless):

```bash
sudo passwd dev
```

### Install dev tools (inside the VM)

```bash
sudo apt update
sudo apt install -y build-essential linux-headers-cloud-arm64 git vim usbutils
```

### Shut down cleanly (inside the VM)

```bash
sudo poweroff
```

## Daemonized variant (optional)

If you want the VM to outlive the launching terminal and be able to reattach
to its serial console / monitor:

```bash
cat > start-daemon.sh <<'EOF'
#!/bin/bash
cd "$(dirname "$0")"
qemu-system-aarch64 \
  -machine virt,accel=hvf \
  -cpu host \
  -smp 4 -m 4G \
  -drive if=pflash,format=raw,readonly=on,file=edk2-aarch64-code.fd \
  -drive if=pflash,format=raw,file=varstore.img \
  -drive if=virtio,format=qcow2,file=debian.qcow2 \
  -drive if=virtio,format=raw,file=seed.iso \
  -netdev user,id=n0,hostfwd=tcp::2222-:22 \
  -device virtio-net-pci,netdev=n0 \
  -display none \
  -serial unix:/tmp/vm-console.sock,server,nowait \
  -monitor unix:/tmp/vm-monitor.sock,server,nowait \
  -daemonize \
  -pidfile /tmp/vm.pid
EOF
chmod +x start-daemon.sh
```

Then:

```bash
./start-daemon.sh                                          # start in background
ssh -i vm_key -p 2222 dev@localhost                        # main interface
socat -,raw,echo=0 UNIX-CONNECT:/tmp/vm-console.sock       # attach serial console
socat - UNIX-CONNECT:/tmp/vm-monitor.sock                  # attach QEMU monitor
kill $(cat /tmp/vm.pid)                                    # stop
```

`socat` is `brew install socat`.

## Snapshots

Before risky kernel work:

```bash
qemu-img snapshot -c clean debian.qcow2    # save snapshot named "clean"
qemu-img snapshot -l debian.qcow2          # list snapshots
qemu-img snapshot -a clean debian.qcow2    # restore (VM must be stopped)
qemu-img snapshot -d clean debian.qcow2    # delete
```

## Troubleshooting

- **`Duplicate ID 'n0' for netdev`**: `start.sh` has the `-netdev` line twice.
  Re-run step 6 to recreate the script.
- **SSH refused**: cloud-init isn't finished yet. Watch the QEMU console; wait
  for `cloud-init` lines to stop scrolling, then retry.
- **`hdiutil: makehybrid: error` on seed creation**: the `seed/` directory is
  missing or empty. Re-run step 5.
- **`edk2-aarch64-code.fd` not found**: `brew install qemu` did not complete,
  or path differs. Locate with
  `find "$(brew --prefix)" -name 'edk2-aarch64-code.fd'`.

## Files

| File | Purpose |
|---|---|
| `debian.qcow2` | Main VM disk (grows on demand up to 20 GB) |
| `varstore.img` | Writable UEFI NVRAM |
| `edk2-aarch64-code.fd` | Read-only UEFI firmware |
| `seed.iso` | Cloud-init config for first boot |
| `seed/` | Source for `seed.iso` (user-data, meta-data) |
| `vm_key` / `vm_key.pub` | SSH keypair for the `dev` user |
| `start.sh` | Foreground launcher |
| `start-daemon.sh` | Background launcher (optional) |
