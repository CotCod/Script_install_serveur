#!/usr/bin/env bash

storage_inspect() {
    local session_id=$1
    local devices filesystems mounts fstab_check backup
    state_require_confirmed preparation
    [[ "$(jq -r '.steps.base_reboot.status // "not_required"' "$STATE_FILE")" != required ]] \
        || die "Le système attend un redémarrage après mise à jour. Redémarrez puis consignez --record-manual base_reboot avant de poursuivre."
    [[ "$(jq -r '.steps.base_installation.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Terminez d'abord l'installation initiale (chapitre 4)."
    [[ "$(jq -r '.steps.services_review.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Consignez d'abord la revue des services actifs avec --record-manual services_review."
    require_command lsblk
    require_command df
    require_command findmnt
    require_command blkid

    devices=$(lsblk -f 2>&1 || true)
    filesystems=$(df -h 2>&1 || true)
    mounts=$(findmnt -rn -o TARGET,SOURCE,FSTYPE,SIZE,OPTIONS 2>&1 || true)
    fstab_check=$(findmnt --verify --verbose 2>&1 || true)
    backup=$(cat /etc/fstab 2>&1 || true)

    state_update '.steps.storage.audit_status = "inspected" | .steps.storage.inspected_at = $now | .report.storage = {block_devices:$devices, filesystems:$filesystems, mounts:$mounts, fstab:$fstab, fstab_validation:$fstab_check, inspected_at:$now}' \
        --arg devices "$devices" --arg filesystems "$filesystems" \
        --arg mounts "$mounts" --arg fstab "$backup" --arg fstab_check "$fstab_check"

    log "Inventaire stockage enregistré sans modification."
    printf '%s\n' "$devices"
    printf '\n%s\n' "$filesystems"
    printf '\n%s\n' "$fstab_check"
    log "Après vérification du schéma et des options, consignez le contrôle avec --record-manual storage --session $session_id."
}
