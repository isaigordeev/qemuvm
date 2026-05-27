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

