#!/bin/sh
# SPDX-FileCopyrightText: 2026 Chimera-NAS Project Contributors
#
# SPDX-License-Identifier: Unlicense

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs udev /dev
mount -t tmpfs none /tmp
# POSIX shm and pseudo-terminals: a number of tests (e.g. LTP cachestat/ioctl/
# remap_file_pages) need /dev/shm and /dev/pts, which devtmpfs does not provide.
mkdir -p /dev/shm /dev/pts
mount -t tmpfs none /dev/shm
mount -t devpts none /dev/pts 2>/dev/null || true

# Configure networking (VM side of the TAP link)
# virtio_net, virtio_blk, virtio_pci are built-in to the Ubuntu kernel
ip link set lo up
ip link set eth0 up 2>/dev/null || true
# The guest IP defaults to 10.0.0.2, but the multi-client harness boots more than
# one guest on the same link and passes guest_ip=<addr> on the cmdline so each
# gets a distinct address (hence a distinct NFS client identity to the server).
GUEST_IP=`cat /proc/cmdline | sed -ne 's/^.*guest_ip=\([0-9.]*\).*$/\1/p'`
[ -z "$GUEST_IP" ] && GUEST_IP=10.0.0.2
ip addr add ${GUEST_IP}/24 dev eth0 2>/dev/null || true
# Default route to the server: the nfstest suite derives its own client IP via a
# UDP connect()+getsockname() probe, which needs a route to choose a source
# address (nothing routes off-subnet otherwise).  Harmless for other tests.
ip route add default via 10.0.0.1 2>/dev/null || true

# Re-enable kernel console output (quiet suppressed it during boot)
echo 7 > /proc/sys/kernel/printk

# The multi-client harness flags the secondary client guest with start_sshd=1 so
# the primary can drive it over ssh (nfstest's --client path).  Host keys and a
# symmetric test keypair are baked into the image.
case "`cat /proc/cmdline`" in
    *start_sshd=1*) /usr/sbin/sshd 2>/dev/null || true ;;
esac

# Kerberos (sec=krb5) NFS client bring-up, triggered by krb5=1 on the cmdline.
# The per-test realm material -- krb5.conf, the client machine keytab and the
# /etc/hosts entries for the server/client FQDNs -- is generated at test time by
# an ephemeral KDC on the host, so it cannot be baked into the image.  The host
# harness passes it through a 9p share tagged "krbshare"; we copy it into place,
# then start rpc.gssd, which backs the kernel's GSS upcall for a sec=krb5 mount.
case "`cat /proc/cmdline`" in
    *krb5=1*)
        # A stable client hostname so the machine principal the harness put in
        # the keytab (host/<fqdn>@REALM) matches what rpc.gssd looks up.
        GUEST_HOST=`cat /proc/cmdline | sed -ne 's/^.*guest_host=\([^ ]*\).*$/\1/p'`
        [ -n "$GUEST_HOST" ] && hostname "$GUEST_HOST"

        modprobe 9pnet_virtio 2>/dev/null || true
        modprobe 9p 2>/dev/null || true
        modprobe rpcsec_gss_krb5 2>/dev/null || true

        mkdir -p /mnt/krb
        if mount -t 9p -o trans=virtio,version=9p2000.L krbshare /mnt/krb 2>/dev/null; then
            [ -f /mnt/krb/krb5.conf ]   && cp /mnt/krb/krb5.conf /etc/krb5.conf
            [ -f /mnt/krb/krb5.keytab ] && { cp /mnt/krb/krb5.keytab /etc/krb5.keytab; chmod 600 /etc/krb5.keytab; }
            [ -f /mnt/krb/hosts ]       && cat /mnt/krb/hosts >> /etc/hosts
            umount /mnt/krb 2>/dev/null || true
        fi

        # rpc.gssd talks to the kernel over rpc_pipefs.
        mkdir -p /var/lib/nfs/rpc_pipefs
        mount -t rpc_pipefs rpc_pipefs /var/lib/nfs/rpc_pipefs 2>/dev/null || true
        /usr/sbin/rpc.gssd 2>/dev/null || true
        ;;
esac

# Parse test_cmd="..." from kernel cmdline
TEST_CMD=`cat /proc/cmdline | sed -e 's/^.*test_cmd="//' -e 's/".*$//'`

echo "Executing: $TEST_CMD"

# Run the test command in background so we can monitor it
eval "$TEST_CMD" &
TEST_PID=$!

# Background watchdog: if test runs longer than 10s, dump diagnostics
(
    ELAPSED=0
    while kill -0 $TEST_PID 2>/dev/null; do
        sleep 5
        ELAPSED=$((ELAPSED + 5))
        if [ $ELAPSED -ge 10 ]; then
            echo "=== WATCHDOG: test PID $TEST_PID still running after ${ELAPSED}s ==="
            echo "--- All processes ---"
            for pid in $(ls -d /proc/[0-9]* 2>/dev/null | cut -d/ -f3); do
                COMM=$(cat /proc/$pid/comm 2>/dev/null) || continue
                WCHAN=$(cat /proc/$pid/wchan 2>/dev/null)
                STATE=$(cat /proc/$pid/stat 2>/dev/null | cut -d' ' -f3)
                echo "PID $pid ($COMM) state=$STATE wchan=$WCHAN"
                if [ "$STATE" = "D" ]; then
                    cat /proc/$pid/stack 2>/dev/null
                fi
            done
            echo "--- NFS mount stats ---"
            cat /proc/self/mountstats 2>/dev/null | head -60
            echo "--- NFS RPC stats ---"
            cat /proc/net/rpc/nfs 2>/dev/null
            echo "--- dmesg (last 30 lines) ---"
            dmesg 2>/dev/null | tail -30
            echo "=== END WATCHDOG ==="
        fi
    done
) &
WATCHDOG_PID=$!

wait $TEST_PID
EXIT_CODE=$?

# Stop the watchdog
kill $WATCHDOG_PID 2>/dev/null
wait $WATCHDOG_PID 2>/dev/null

# Write exit code via kmsg so it goes through the kernel console driver
# synchronously, guaranteeing it reaches the serial log before power off
echo "CHIMERA_KVM_EXIT_CODE=${EXIT_CODE}" > /dev/kmsg

# Tell kernel to power off; QEMU with -no-reboot will exit
echo o > /proc/sysrq-trigger

# Don't let init terminate before kernel has a chance to act
sleep 60
