#!/usr/bin/env bash

write_config_file() {
    local path=$1 content=$2 tmp
    mkdir -p -- "$(dirname -- "$path")"
    tmp=$(mktemp "$(dirname -- "$path")/.cotcod.XXXXXX") || die "Impossible de préparer $path."
    printf '%s\n' "$content" > "$tmp"
    chmod 644 "$tmp"
    mv -f -- "$tmp" "$path"
}

protection_configure() {
    local session_id=$1 confirmation ssh_port sshd_config fail2ban_config sysctl_config ufw_status protection_step boot_id
    local ssh_ports ssh_port_count

    state_require_confirmed preparation
    [[ "$(jq -r '.steps.base_installation.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Terminez d'abord l'installation initiale (chapitre 4)."
    [[ "$(jq -r '.steps.ssh.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Validez d'abord l'accès SSH avec clé et port final (chapitre 8)."
    [[ "$(jq -r '.steps.mfa.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Validez d'abord l'authentification MFA (chapitre 9)."
    for protection_step in firewall fail2ban sysctl apparmor; do
        [[ "$(jq -r --arg step "$protection_step" '.steps[$step].status // "not_started"' "$STATE_FILE")" == not_started ]] \
            || die "L'étape '$protection_step' a déjà commencé; vérifiez l'état et les sauvegardes avant reprise."
    done

    require_command sshd
    require_command ufw
    require_command fail2ban-client
    require_command sysctl
    require_command aa-enforce
    require_command aa-status

    sshd_config=$(sshd -T 2>/dev/null) || die "Impossible de lire la configuration effective de sshd."
    ssh_ports=$(awk '$1 == "port" {print $2}' <<< "$sshd_config")
    ssh_port_count=$(awk '$1 == "port" {n++} END {print n+0}' <<< "$sshd_config")
    [[ "$ssh_port_count" == 1 ]] || die "Le pare-feu exige un port SSH unique configuré."
    ssh_port=$ssh_ports
    [[ "$ssh_port" =~ ^[0-9]+$ ]] && ((ssh_port >= 49152 && ssh_port <= 65535)) \
        || die "Le port SSH actif doit être compris entre 49152 et 65535."

    printf 'Cette étape configure UFW, Fail2Ban, sysctl et AppArmor.\n'
    printf 'Port SSH détecté : %s/tcp. Gardez la session SSH actuelle ouverte et vérifiez un accès de secours console.\n' "$ssh_port"
    read -r -p "Tapez APPLIQUER-PROTECTIONS pour continuer : " confirmation || die "Lecture interrompue."
    [[ "$confirmation" == APPLIQUER-PROTECTIONS ]] || die "Configuration des protections annulée."

    local backup_dir="$STATE_DIR/backups/$session_id"
    mkdir -p -- "$backup_dir"
    chmod 700 -- "$STATE_DIR/backups" "$backup_dir"
    backup_file /etc/default/ufw "$backup_dir"
    backup_file /etc/ufw "$backup_dir"
    backup_file /etc/fail2ban/jail.d "$backup_dir"
    backup_file /etc/sysctl.d/99-cotcod.conf "$backup_dir"
    backup_file /etc/apparmor.d "$backup_dir"

    state_set_status firewall in_progress
    if grep -q '^IPV6=' /etc/default/ufw; then
        sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    else
        printf '\nIPV6=yes\n' >> /etc/default/ufw
    fi
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow "$ssh_port/tcp" comment 'CotCod - SSH Administration'
    ufw --force enable
    systemctl enable ufw
    ufw_status=$(ufw status verbose)
    [[ "$ufw_status" == *"Status: active"* && "$ufw_status" == *"deny (incoming)"* && "$ufw_status" == *"allow (outgoing)"* ]] \
        || { state_set_status firewall failed; die "La vérification UFW a échoué."; }
    state_set_status firewall succeeded
    state_update '.report.firewall = {solution:"UFW", status:$status, ssh_port:$port, ipv6:true, configured_at:$now}' \
        --arg status "$ufw_status" --arg port "$ssh_port"

    state_set_status fail2ban in_progress
    fail2ban_config='[DEFAULT]
ignoreip = 127.0.0.1/8 ::1
bantime = 1h
findtime = 10m
maxretry = 5
backend = systemd

[sshd]
enabled = true
port = SSH_PORT
logpath = %(sshd_log)s'
    fail2ban_config=${fail2ban_config//SSH_PORT/$ssh_port}
    write_config_file /etc/fail2ban/jail.d/99-cotcod.conf "$fail2ban_config"
    if fail2ban-client -t && systemctl enable --now fail2ban && fail2ban-client status sshd >/dev/null; then
        state_set_status fail2ban succeeded
        state_update '.report.fail2ban = {version:$version, config:"/etc/fail2ban/jail.d/99-cotcod.conf", bantime:"1h", findtime:"10m", maxretry:5, ssh_port:$port, jail:"sshd", configured_at:$now}' \
            --arg version "$(fail2ban-client --version 2>/dev/null | head -n1)" --arg port "$ssh_port"
    else
        state_set_status fail2ban failed
        die "Fail2Ban n'a pas passé ses contrôles; le reste des protections n'a pas été appliqué."
    fi

    state_set_status sysctl in_progress
    sysctl_config=$(cat <<'EOF'
##############################################################
# Configuration Sysctl CotCod - Setup Essentiel
##############################################################
net.ipv4.ip_forward = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.log_martians = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
kernel.randomize_va_space = 2
kernel.yama.ptrace_scope = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
kernel.sysrq = 0
kernel.unprivileged_bpf_disabled = 1
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
EOF
)
    write_config_file /etc/sysctl.d/99-cotcod.conf "$sysctl_config"
    if sysctl --system; then
        state_set_status sysctl succeeded
        state_update '.report.sysctl = {file:"/etc/sysctl.d/99-cotcod.conf", values:$values, configured_at:$now}' \
            --arg values "$sysctl_config"
    else
        state_set_status sysctl failed
        die "Le chargement de sysctl a échoué; vérifiez les paramètres appliqués."
    fi

    state_set_status apparmor in_progress
    if systemctl enable --now apparmor && aa-enforce /etc/apparmor.d/* && aa-status >/dev/null; then
        state_set_status apparmor succeeded
        state_update '.report.apparmor = {version:$version, service:"active", status:$status, ssh_profile:(($status|contains("/usr/sbin/sshd"))), configured_at:$now}' \
            --arg version "$(dpkg-query -W -f='${Version}' apparmor 2>/dev/null || printf unknown)" \
            --arg status "$(aa-status 2>&1)"
    else
        state_set_status apparmor failed
        die "AppArmor n'a pas passé ses contrôles."
    fi

    log "UFW, Fail2Ban, sysctl et AppArmor configurés."
    log "Effectuez le contrôle externe du pare-feu puis --record-manual external_scan."
    log "Un redémarrage sera nécessaire pour valider la persistance, mais ne sera pas lancé automatiquement."
    boot_id=$(cat /proc/sys/kernel/random/boot_id)
    state_update '.steps.reboot_validation = {status:"pending", boot_id_before:$boot_id, protections_configured_at:$now}' --arg boot_id "$boot_id"
}
