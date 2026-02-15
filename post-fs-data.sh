#!/system/bin/sh
# Certificates are collected during post-fs-data so that they are auto-mounted on top of /system for non-conscrypt devices
MODDIR=${0%/*}
SYS_CERT_DIR=/system/etc/security/cacerts
# We copy everything here
TMP_CERT_DIR=$MODDIR$SYS_CERT_DIR

log() {
    echo "$(date '+%m-%d %H:%M:%S') $1" >> "$MODDIR/log.txt"
}

collect_user_certs(){
    mkdir -p "$TMP_CERT_DIR"
    chmod 755 "$TMP_CERT_DIR"
    chown root:root "$TMP_CERT_DIR"
    chcon u:object_r:system_file:s0 "$TMP_CERT_DIR"

    # Clean directory so that deleted certs actually disappear
    rm -rf "$TMP_CERT_DIR/*"

    log "Grabbing user certs"
    # Add the user-defined certs, looping over all available users
    # Typically user 0 is the main one, but we check all
    for dir in /data/misc/user/*; do
        if [ -d "$dir/cacerts-added" ]; then
            for cert in "$dir/cacerts-added"/*; do
                if [ -f "$cert" ]; then
                    cp "$cert" "$TMP_CERT_DIR/"
                    log "Grabbing user cert: $(basename "$cert")"
                fi
            done
        fi
    done
}

main(){
    # Reset log
    echo "" > "$MODDIR/log.txt"
    log "MagiskTrustUserCerts - post-fs-data.sh started"

    collect_user_certs

    log "Grabbing /system certs"
    # Copy existing system certs to our temp dir so we overlay them, not replace them
    cp "$SYS_CERT_DIR/"* "$TMP_CERT_DIR/"
    
    # Set permissions for all files in the temp dir
    chmod 644 "$TMP_CERT_DIR/"*
    chown root:root "$TMP_CERT_DIR/"*
    chcon u:object_r:system_security_cacerts_file:s0 "$TMP_CERT_DIR/"*

    log "Certificates collected and permissions set."
}

main