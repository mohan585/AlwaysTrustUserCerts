#!/system/bin/sh
MODDIR=${0%/*}
SYS_CERT_DIR=/system/etc/security/cacerts

# Directory where we will copy everything to before mounting
TMP_CERT_DIR=$MODDIR$SYS_CERT_DIR

log() {
    echo "$(date '+%m-%d %H:%M:%S') $1" >> "$MODDIR/log.txt"
}

# Find the conscrypt directory dynamically (Android 10+)
find_conscrypt_dir() {
    if [ -d "/apex/com.android.conscrypt/cacerts" ]; then
        echo "/apex/com.android.conscrypt/cacerts"
    elif [ -d "/apex/com.google.android.conscrypt/cacerts" ]; then
        echo "/apex/com.google.android.conscrypt/cacerts"
    else
        echo ""
    fi
}

CONCRYPT_CERT_DIR=$(find_conscrypt_dir)

# Check if a specific mount is present in a process's mountinfo
has_mount() {
    local pid="$1"
    local target="$2"
    if [ ! -f "/proc/$pid/mountinfo" ]; then
        return 1
    fi
    grep -q " $target " "/proc/$pid/mountinfo"
}

monitor_zygote() {
    log "Starting Zygote monitor..."
    while true; do
        # Find all zygote processes (32-bit and 64-bit)
        # Using pidof is generally safe on Android 6+, Magisk ensures generic tools
        zygote_pids=$(pidof zygote zygote64)
        
        for zp in $zygote_pids; do
            # Check if we have already injected into this zygote
            if ! has_mount "$zp" "$CONCRYPT_CERT_DIR"; then
                log "Injecting into Zygote ($zp)..."
                
                # Mount the temp directory over the conscrypt directory in the zgyote namespace
                # Use --bind instead of --rbind for simpler bind mount
                nsenter --mount=/proc/$zp/ns/mnt -- \
                    mount --bind "$TMP_CERT_DIR" "$CONCRYPT_CERT_DIR"
                
                if [ $? -eq 0 ]; then
                    log "Success: Injected into Zygote ($zp)"
                else
                    log "Error: Failed to inject into Zygote ($zp)"
                fi
            fi

            # Handle children of Zygote
            # pgrep might be missing on very old Android or stripped down ROMs
            # Fallback to ps if pgrep fails or just ignore if not critical
            if command -v pgrep >/dev/null 2>&1; then
                for child_pid in $(pgrep -P $zp); do
                     if ! has_mount "$child_pid" "$CONCRYPT_CERT_DIR"; then
                         nsenter --mount=/proc/$child_pid/ns/mnt -- \
                            mount --bind "$TMP_CERT_DIR" "$CONCRYPT_CERT_DIR"
                     fi
                 done
            fi
        done
        
        # Sleep to avoid high CPU usage
        sleep 5
    done
}

main() {
    log "MagiskTrustUserCerts - service.sh started"

    # Wait for boot to complete roughly
    while [ "$(getprop sys.boot_completed)" != "1" ]; do
        sleep 1
    done
    
    # Ensure our temp directory is ready and has correct permissions
    if [ -d "$TMP_CERT_DIR" ]; then
        chown -R root:root "$TMP_CERT_DIR"
        chmod 755 "$TMP_CERT_DIR"
        # Set directory context, ignore errors on old Android if context invalid
        chcon u:object_r:system_file:s0 "$TMP_CERT_DIR" 2>/dev/null
        
        # Set file permissions and context correctly for certs
        chmod 644 "$TMP_CERT_DIR"/*
        chown root:root "$TMP_CERT_DIR"/*
        # Use system_file if security_cacerts_file is invalid on older Android
        chcon u:object_r:system_security_cacerts_file:s0 "$TMP_CERT_DIR"/* 2>/dev/null || \
        chcon u:object_r:system_file:s0 "$TMP_CERT_DIR"/* 2>/dev/null
    else
        log "Error: Temp cert dir not found at $TMP_CERT_DIR"
    fi

    if [ -n "$CONCRYPT_CERT_DIR" ]; then
        log "Conscrypt directory found at: $CONCRYPT_CERT_DIR (Android 10+)"
        
        # 1. Mount over the system certs location (for non-conscrypt apps/fallback)
        mount --bind "$TMP_CERT_DIR" "$SYS_CERT_DIR"
        
        # 2. Start monitoring Zygote to inject into the APEX path
        monitor_zygote &
    else
        log "No Conscrypt APEX found. Assuming legacy Android (<10) or non-standard setup."
        # Just mount over system certs
        # Zygote monitoring for system certs isn't typically needed on <10 as mounts propagate easier
        # or Magisk handles it via Magic Mount. But manual bind ensures it.
        mount --bind "$TMP_CERT_DIR" "$SYS_CERT_DIR"
    fi
}

main