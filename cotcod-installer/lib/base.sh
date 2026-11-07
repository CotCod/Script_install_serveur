#!/usr/bin/env bash

base_prepare() {
    local hostname os kernel upgradable reboot_required package status services
    local -a packages missing

    require_command dpkg-query
    require_command paste
    require_command uname

    source /etc/os-release
    packages=(vim curl wget sudo net-tools bash-completion htop unzip ufw fail2ban \
        apparmor apparmor-utils rsync logrotate ca-certificates locales)
    [[ "${ID:-}" != debian ]] || packages+=(resolvconf)

    hostname=$(hostnamectl --static 2>/dev/null || hostname)
    os=${PRETTY_NAME:-${ID:-unknown} ${VERSION_ID:-}}
    kernel=$(uname -r)
    upgradable=$(apt list --upgradable 2>/dev/null | awk 'NR > 1 {sub(/\/.*/, "", $1); print $1}' | paste -sd, -)
    services=$(systemctl list-units --type=service --state=running --no-legend --no-pager) \
        || die "Impossible de relever les services actifs."
    [[ -e /var/run/reboot-required ]] && reboot_required=true || reboot_required=false

    missing=()
    for package in "${packages[@]}"; do
        status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null || true)
        [[ "$status" == installed ]] || missing+=("$package")
    done

    local missing_csv
    missing_csv=$(IFS=,; printf '%s' "${missing[*]}")
    state_put_base_plan "$hostname" "$os" "$kernel" "${upgradable:-}" "$missing_csv" "$reboot_required" "${packages[*]}"
    state_update '.steps.base_installation.inventory.running_services = $services | .report.system.running_services_before_review = $services' \
        --arg services "$services"

    log "Inventaire initial enregistré en lecture seule."
    log "Paquets CotCod absents : ${missing_csv:-aucun}."
    log "Paquets pouvant être mis à jour : ${upgradable:-aucun détecté dans les index locaux}."
    log "Aucune mise à jour ni installation n'a été lancée."
}

base_apply() {
    local session_id=$1 confirmation target_hostname current_hostname boot_id
    local -a packages
    state_require_confirmed preparation
    [[ "$(jq -r '.steps.os_support.status // "not_started"' "$STATE_FILE")" == succeeded ]] \
        || die "Consignez d'abord la validation technique de la distribution et de sa version avec --record-manual os_support."
    require_command apt-get
    require_command dpkg
    require_command hostnamectl
    require_command locale-gen
    require_command update-locale
    require_command localectl
    require_command timedatectl
    jq -e '.steps.base_installation.status == "prepared"' "$STATE_FILE" >/dev/null \
        || die "Le plan d'installation initial doit être préparé avant son application."

    state_show_preparation
    printf '\nCette étape mettra à jour le système et installera les outils CotCod. Une sauvegarde de /etc sera créée.\n'
    read -r -p "Tapez APPLIQUER-BASE pour continuer : " confirmation || die "Lecture interrompue."
    [[ "$confirmation" == APPLIQUER-BASE ]] || die "Application annulée; aucune modification système n'a été lancée."

    local backup_dir="$STATE_DIR/backups/$session_id"
    mkdir -p -- "$backup_dir"
    chmod 700 -- "$STATE_DIR/backups" "$backup_dir"
    backup_file /etc "$backup_dir"
    dpkg --get-selections > "$backup_dir/dpkg-selections-before.txt"
    chmod 600 -- "$backup_dir/dpkg-selections-before.txt"

    target_hostname=$(jq -r '.preparation.hostname' "$STATE_FILE")
    current_hostname=$(hostnamectl --static 2>/dev/null || hostname)

    packages=(vim curl wget sudo net-tools bash-completion htop unzip ufw fail2ban \
        apparmor apparmor-utils rsync logrotate ca-certificates locales)
    source /etc/os-release
    [[ "${ID:-}" != debian ]] || packages+=(resolvconf)

    state_set_status base_installation in_progress
    state_set_status base_apt_update running
    if apt-get update; then
        state_set_status base_apt_update succeeded
    else
        state_set_status base_apt_update failed
        die "Échec d'apt-get update. Le système n'a pas poursuivi les étapes suivantes."
    fi

    state_set_status base_full_upgrade running
    if apt-get full-upgrade -y; then
        state_set_status base_full_upgrade succeeded
    else
        state_set_status base_full_upgrade failed
        die "Échec d'apt-get full-upgrade. Vérifiez l'état des paquets avant de poursuivre."
    fi

    state_set_status base_packages running
    if apt-get install -y --no-install-recommends "${packages[@]}"; then
        state_set_status base_packages succeeded
    else
        state_set_status base_packages failed
        die "Échec d'installation des outils CotCod. Vérifiez l'état des paquets avant de poursuivre."
    fi

    state_set_status base_system_configuration running
    if [[ "$current_hostname" != "$target_hostname" ]]; then
        hostnamectl set-hostname "$target_hostname" || { state_set_status base_system_configuration failed; die "Impossible de définir le hostname CotCod."; }
    fi
    if ! grep -qE '^[[:space:]]*fr_FR.UTF-8[[:space:]]+UTF-8([[:space:]]|$)' /etc/locale.gen; then
        printf '\nfr_FR.UTF-8 UTF-8\n' >> /etc/locale.gen
    fi
    locale-gen fr_FR.UTF-8 || { state_set_status base_system_configuration failed; die "La génération de fr_FR.UTF-8 a échoué."; }
    update-locale LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 || { state_set_status base_system_configuration failed; die "Impossible de définir la locale française."; }
    localectl set-keymap us || { state_set_status base_system_configuration failed; die "Impossible de définir le clavier console anglais (us)."; }
    local keyboard_tmp
    keyboard_tmp=$(mktemp /etc/default/.keyboard.cotcod.XXXXXX)
    if [[ -f /etc/default/keyboard ]]; then
        awk '
            BEGIN { model=layout=variant=options=backspace=0 }
            /^XKBMODEL=/ { if (!model++) print "XKBMODEL=\"pc105\""; next }
            /^XKBLAYOUT=/ { if (!layout++) print "XKBLAYOUT=\"us\""; next }
            /^XKBVARIANT=/ { if (!variant++) print "XKBVARIANT=\"\""; next }
            /^XKBOPTIONS=/ { if (!options++) print "XKBOPTIONS=\"\""; next }
            /^BACKSPACE=/ { if (!backspace++) print "BACKSPACE=\"guess\""; next }
            { print }
            END {
                if (!model) print "XKBMODEL=\"pc105\""
                if (!layout) print "XKBLAYOUT=\"us\""
                if (!variant) print "XKBVARIANT=\"\""
                if (!options) print "XKBOPTIONS=\"\""
                if (!backspace) print "BACKSPACE=\"guess\""
            }
        ' /etc/default/keyboard > "$keyboard_tmp"
    else
        printf 'XKBMODEL="pc105"\nXKBLAYOUT="us"\nXKBVARIANT=""\nXKBOPTIONS=""\nBACKSPACE="guess"\n' > "$keyboard_tmp"
    fi
    chmod 644 "$keyboard_tmp"
    chown root:root "$keyboard_tmp"
    mv -f -- "$keyboard_tmp" /etc/default/keyboard
    timedatectl set-timezone Europe/Paris || { state_set_status base_system_configuration failed; die "Impossible de définir le fuseau Europe/Paris."; }
    state_update '.steps.base_system_configuration = {status:"succeeded", hostname:$hostname, locale:"fr_FR.UTF-8", keyboard:"us", timezone:"Europe/Paris", configured_at:$now} | .report.system.hostname_requested=$hostname | .report.system.locale="fr_FR.UTF-8" | .report.system.keyboard="us" | .report.system.timezone="Europe/Paris"' \
        --arg hostname "$target_hostname"

    if [[ -e /var/run/reboot-required ]]; then
        state_set_status base_reboot required
        boot_id=$(cat /proc/sys/kernel/random/boot_id)
        state_update '.steps.base_reboot = {status:"required", boot_id_before:$boot_id, requested_at:$now}' --arg boot_id "$boot_id"
        warn "Le système demande un redémarrage. Il ne sera pas lancé automatiquement."
    else
        state_update '.steps.base_reboot = {status:"not_required", checked_at:$now}'
    fi
    state_set_status base_installation succeeded
    log "Mises à jour et outils CotCod installés."
}
