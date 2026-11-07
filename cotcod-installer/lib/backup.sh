#!/usr/bin/env bash

backup_file() {
    local source_path=$1 backup_root=${2:-$STATE_DIR/backups}
    [[ -e "$source_path" ]] || return 0
    mkdir -p -- "$backup_root"
    chmod 700 -- "$backup_root"
    local safe_name timestamp target
    safe_name=${source_path#/}
    safe_name=${safe_name//\//__}
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    target=$(mktemp -d "$backup_root/${timestamp}__${safe_name}.XXXXXX") || die "Impossible de réserver un emplacement de sauvegarde."
    cp -a -- "$source_path" "$target/" || die "Échec de sauvegarde de $source_path."
    log "Sauvegarde créée: $source_path"
}
