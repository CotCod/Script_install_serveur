#!/usr/bin/env bash

audit_final() {
    local expected_ip expected_hostname expected_gateway expected_iface expected_prefix actual_address actual_hostname os kernel default_route active_dns= ntp_state timezone timesyncd_active
    local sshd_effective= ssh_port=absent firewall_status fail2ban_status apparmor_status failed_units upgrades
    local storage_json interfaces_json links_json disks_json mounts_json findings components package_name package_version
    local cpu_model cpu_count ram serial_uuid total_disk_bytes total_disk readable_total ports journal_summary
    local locale_file keyboard_status apparmor_errors inbound_rules
    local user group_list home_mode auth_file_mode shadow_policy forbidden_user home_owner key_owner sudo_check authorized_keys fail2ban_active apparmor_kernel journal_critical
    local -a failures=()
    local -a admins
    local step

    for step in os_support iso_verification base_installation services_review storage network users ssh_key_test ssh_password_test ssh mfa firewall external_scan fail2ban sysctl apparmor reboot_validation; do
        if [[ "$(jq -r --arg step "$step" '.steps[$step].status // "not_started"' "$STATE_FILE")" != succeeded ]]; then
            failures+=("Étape non validée : $step")
        fi
    done
    if [[ "$(jq -r '.steps.base_reboot.status // "not_required"' "$STATE_FILE")" == required ]]; then
        [[ "$(jq -r '.steps.base_reboot.status' "$STATE_FILE")" == succeeded ]] || failures+=("Redémarrage initial requis non validé")
        [[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(jq -r '.steps.base_reboot.boot_id_before' "$STATE_FILE")" ]] || failures+=("Le serveur n'a pas redémarré après la mise à jour initiale")
    fi
    [[ ! -e /var/run/reboot-required ]] || failures+=("Redémarrage système en attente")

    expected_ip=$(jq -r '.preparation.ip_address // ""' "$STATE_FILE")
    expected_hostname=$(jq -r '.preparation.hostname // ""' "$STATE_FILE")
    expected_gateway=$(jq -r '.steps.network.gateway // ""' "$STATE_FILE")
    expected_iface=$(jq -r '.steps.network.interface // ""' "$STATE_FILE")
    expected_prefix=$(jq -r '.steps.network.prefix // ""' "$STATE_FILE")
    actual_hostname=$(hostnamectl --static 2>/dev/null || hostname)
    source /etc/os-release
    os=${PRETTY_NAME:-${ID:-unknown}}
    kernel=$(uname -r)
    cpu_model=$(awk -F: '/model name/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}' /proc/cpuinfo)
    cpu_count=$(nproc 2>/dev/null || printf unknown)
    ram=$(free -h 2>/dev/null | awk '/^Mem:/ {print $2; exit}')
    serial_uuid=$(cat /sys/class/dmi/id/product_uuid 2>/dev/null || printf unknown)
    total_disk_bytes=$(lsblk -b -dn -o SIZE 2>/dev/null | awk '{sum += $1} END {print sum+0}')
    readable_total=$(numfmt --to=iec "$total_disk_bytes" 2>/dev/null || printf unknown)

    if [[ "$actual_hostname" != "$expected_hostname" ]]; then failures+=("Hostname constaté différent du hostname demandé"); fi
    locale_file=$(cat /etc/default/locale 2>/dev/null || true)
    grep -Eq '^LANG="?fr_FR.UTF-8"?$' <<< "$locale_file" || failures+=("Locale par défaut différente de fr_FR.UTF-8")
    locale -a 2>/dev/null | grep -Eiq '^fr_FR\.utf-?8$' || failures+=("Locale fr_FR.UTF-8 absente des locales générées")
    if [[ -r /etc/default/keyboard ]]; then
        grep -Eq '^XKBLAYOUT="?us"?$' /etc/default/keyboard || failures+=("Disposition clavier différente de us")
    else
        failures+=("Configuration clavier /etc/default/keyboard absente")
    fi
    keyboard_status=$(localectl status 2>&1 || true)
    [[ "$keyboard_status" == *"VC Keymap: us"* ]] || failures+=("Disposition clavier console us non active")
    actual_address=$(ip -4 -o address show dev "$expected_iface" scope global 2>/dev/null | awk 'NR == 1 {print $4}')
    [[ "$actual_address" == "$expected_ip/$expected_prefix" ]] || failures+=("Adresse/préfixe IPv4 prévu absent de l'interface $expected_iface")
    default_route=$(ip -4 route show default 2>/dev/null || true)
    [[ -n "$default_route" ]] || failures+=("Route IPv4 par défaut absente")
    [[ "$default_route" == *"via $expected_gateway"* && "$default_route" == *"dev $expected_iface"* ]] || failures+=("Route par défaut différente de la passerelle/interface configurée")

    if command_exists resolvectl; then
        active_dns=$(resolvectl dns 2>/dev/null || true)
    fi
    [[ "$active_dns" == *1.1.1.1* && "$active_dns" == *1.0.0.1* ]] || active_dns=$(cat /etc/resolv.conf 2>/dev/null || true)
    [[ "$active_dns" == *1.1.1.1* && "$active_dns" == *1.0.0.1* ]] || failures+=("DNS CotCod 1.1.1.1 et 1.0.0.1 non détectés")
    getent ahostsv4 google.com >/dev/null 2>&1 || failures+=("Résolution DNS externe de google.com en échec")

    ntp_state=$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)
    [[ "$ntp_state" == yes ]] || failures+=("Horloge système non synchronisée")
    timezone=$(timedatectl show -p Timezone --value 2>/dev/null || true)
    [[ "$timezone" == Europe/Paris ]] || failures+=("Fuseau horaire différent d'Europe/Paris")
    timesyncd_active=$(systemctl is-active systemd-timesyncd 2>/dev/null || true)
    [[ "$timesyncd_active" == active ]] || failures+=("systemd-timesyncd inactif")
    for package_name in chrony ntp ntpsec openntpd; do
        [[ "$(dpkg-query -W -f='${db:Status-Status}' "$package_name" 2>/dev/null || true)" != installed ]] \
            || failures+=("Service NTP alternatif installé : $package_name")
    done

    upgrades=$(apt list --upgradable 2>/dev/null | awk 'NR > 1 {print $1}')
    [[ -z "$upgrades" ]] || failures+=("Des paquets restent à mettre à jour")
    [[ ! -e /var/run/reboot-required ]] || failures+=("Redémarrage système en attente")
    for package_name in vim curl wget sudo net-tools bash-completion htop unzip ufw fail2ban apparmor apparmor-utils rsync logrotate ca-certificates locales; do
        dpkg-query -W -f='${db:Status-Status}' "$package_name" 2>/dev/null | grep -qx installed \
            || failures+=("Paquet CotCod absent : $package_name")
    done
    if [[ "${ID:-}" == debian ]]; then
        dpkg-query -W -f='${db:Status-Status}' resolvconf 2>/dev/null | grep -qx installed \
            || failures+=("Paquet CotCod absent : resolvconf (nécessaire aux DNS ifupdown)")
    fi
    for package_name in ubuntu-desktop ubuntu-desktop-minimal task-gnome-desktop task-kde-desktop task-xfce-desktop \
        xserver-xorg-core gdm3 gnome-shell kubuntu-desktop kde-plasma-desktop plasma-desktop lightdm \
        xubuntu-desktop lubuntu-desktop xfce4 lxde mate-desktop-environment cinnamon-desktop-environment; do
        if dpkg-query -W -f='${db:Status-Status}' "$package_name" 2>/dev/null | grep -qx installed; then
            failures+=("Environnement graphique installé : $package_name")
        fi
    done

    if command_exists sshd; then
        sshd_effective=$(sshd -T 2>/dev/null || true)
        ssh_port=$(awk '$1 == "port" {print $2; exit}' <<< "$sshd_effective")
        [[ "$sshd_effective" == *$'permitrootlogin no'* ]] || failures+=("SSH : connexion root non interdite")
        [[ "$sshd_effective" == *$'passwordauthentication no'* ]] || failures+=("SSH : authentification par mot de passe active")
        [[ "$sshd_effective" == *$'pubkeyauthentication yes'* ]] || failures+=("SSH : authentification par clé inactive")
        [[ "$sshd_effective" == *$'authenticationmethods publickey,keyboard-interactive'* ]] || failures+=("SSH : méthodes publickey et TOTP non imposées")
        [[ "$sshd_effective" == *$'kbdinteractiveauthentication yes'* ]] || failures+=("SSH : keyboard-interactive désactivé")
        [[ "$sshd_effective" == *$'x11forwarding no'* && "$sshd_effective" == *$'allowtcpforwarding no'* && "$sshd_effective" == *$'allowagentforwarding no'* ]] \
            || failures+=("SSH : transferts ou X11 encore autorisés")
        local ssh_setting
        for ssh_setting in 'permittunnel no' 'usepam yes' 'permitemptypasswords no' 'maxauthtries 3' 'logingracetime 30' 'clientaliveinterval 300' 'clientalivecountmax 2' 'strictmodes yes'; do
            grep -Fqx "$ssh_setting" <<< "$sshd_effective" || failures+=("SSH : paramètre effectif non conforme ($ssh_setting)")
        done
        [[ "$ssh_port" =~ ^[0-9]+$ ]] && ((ssh_port >= 49152 && ssh_port <= 65535)) || failures+=("Port SSH hors de la plage 49152–65535")
        ss -H -ltn | awk -v port="$ssh_port" '$4 ~ (":" port "$") {found=1} END {exit !found}' \
            || failures+=("Le port SSH configuré n'est pas réellement à l'écoute")
        if ss -H -ltn | awk '$4 ~ /:22$/ {found=1} END {exit !found}'; then
            failures+=("Le port SSH 22 reste à l'écoute")
        fi
    else
        ssh_port=absent
        failures+=("OpenSSH serveur absent")
    fi

    firewall_status=$(ufw status 2>/dev/null || true)
    [[ "$firewall_status" == *"Status: active"* ]] || failures+=("UFW inactif")
    [[ "$firewall_status" == *"deny (incoming)"* && "$firewall_status" == *"allow (outgoing)"* ]] || failures+=("Politiques UFW par défaut non conformes")
    grep -Eq '^IPV6=yes' /etc/default/ufw 2>/dev/null || failures+=("UFW IPv6 désactivé")
    ports=$(ufw status numbered 2>/dev/null || true)
    [[ "$ports" == *"$ssh_port/tcp"* ]] || failures+=("Règle UFW du port SSH absente")
    inbound_rules=$(awk '/^[[:space:]]*\[[[:space:]]*[0-9]+\]/ && /ALLOW IN/ {print}' <<< "$ports")
    if grep -Ev "${ssh_port}/tcp([[:space:]]|$)" <<< "$inbound_rules" | grep -q .; then
        failures+=("UFW autorise au moins un port entrant autre que SSH")
    fi

    fail2ban_status=$(fail2ban-client status sshd 2>&1 || true)
    [[ "$fail2ban_status" == *"Jail list:"* || "$fail2ban_status" == *"Currently banned:"* ]] || failures+=("Jail SSH Fail2Ban inactive")
    fail2ban_active=$(systemctl is-active fail2ban 2>/dev/null || true)
    [[ "$fail2ban_active" == active ]] || failures+=("Service Fail2Ban inactif")
    [[ "$(fail2ban-client get sshd maxretry 2>/dev/null || true)" == 5 ]] || failures+=("Fail2Ban maxretry différent de 5")
    [[ "$(fail2ban-client get sshd findtime 2>/dev/null || true)" == 600 ]] || failures+=("Fail2Ban findtime différent de 10 minutes")
    [[ "$(fail2ban-client get sshd bantime 2>/dev/null || true)" == 3600 ]] || failures+=("Fail2Ban bantime différent de 1 heure")
    [[ "$(fail2ban-client get sshd port 2>/dev/null || true)" == *"$ssh_port"* ]] || failures+=("Fail2Ban ne surveille pas le port SSH configuré")

    local key value
    while read -r key value; do
        [[ -n "$key" ]] || continue
        [[ "$(sysctl -n "$key" 2>/dev/null || true)" == "$value" ]] || failures+=("Sysctl non conforme : $key")
    done <<'EOF'
kernel.randomize_va_space 2
kernel.yama.ptrace_scope 1
net.ipv4.ip_forward 0
net.ipv4.tcp_syncookies 1
fs.protected_symlinks 1
net.ipv4.conf.all.accept_redirects 0
net.ipv4.conf.default.accept_redirects 0
net.ipv4.conf.all.secure_redirects 0
net.ipv4.conf.default.secure_redirects 0
net.ipv4.conf.all.send_redirects 0
net.ipv4.conf.default.send_redirects 0
net.ipv4.conf.all.accept_source_route 0
net.ipv4.conf.default.accept_source_route 0
net.ipv6.conf.all.forwarding 0
net.ipv6.conf.all.accept_redirects 0
net.ipv6.conf.default.accept_redirects 0
net.ipv6.conf.all.accept_source_route 0
net.ipv6.conf.default.accept_source_route 0
net.ipv4.conf.all.rp_filter 1
net.ipv4.conf.default.rp_filter 1
net.ipv4.conf.all.log_martians 1
net.ipv4.icmp_ignore_bogus_error_responses 1
net.ipv4.icmp_echo_ignore_broadcasts 1
fs.protected_hardlinks 1
fs.protected_fifos 2
fs.protected_regular 2
fs.suid_dumpable 0
kernel.sysrq 0
kernel.unprivileged_bpf_disabled 1
kernel.dmesg_restrict 1
kernel.kptr_restrict 2
EOF
    [[ -f /etc/sysctl.d/99-cotcod.conf ]] || failures+=("Fichier Sysctl CotCod absent")

    apparmor_status=$(aa-status 2>&1 || true)
    apparmor_errors=$(journalctl -u apparmor -p err..alert -n 100 --no-pager 2>&1 || true)
    apparmor_kernel=$(cat /sys/module/apparmor/parameters/enabled 2>/dev/null || true)
    journal_critical=$(journalctl -p crit..alert -b --no-pager 2>&1 || true)
    [[ "$apparmor_status" == *"apparmor module is loaded"* || "$apparmor_status" == *"apparmor is enabled"* ]] || failures+=("AppArmor inactif")
    [[ "$apparmor_status" == *"enforce"* ]] || failures+=("Aucun profil AppArmor en mode enforce")
    [[ "$apparmor_kernel" == Y ]] || failures+=("Module AppArmor non chargé dans le noyau")
    grep -Eq '[1-9][0-9]* profiles? are in complain mode' <<< "$apparmor_status" && failures+=("Un ou plusieurs profils AppArmor sont en complain")
    [[ -e /etc/apparmor.d/usr.sbin.sshd || "$apparmor_status" == *"/usr/sbin/sshd"* ]] || failures+=("Profil AppArmor sshd absent")
    [[ -z "$apparmor_errors" || "$apparmor_errors" == *"-- No entries --"* ]] || failures+=("Erreurs AppArmor détectées dans les journaux")
    [[ -z "$journal_critical" || "$journal_critical" == *"-- No entries --"* ]] || failures+=("Erreurs critiques ou alertes présentes dans le journal courant")

    failed_units=$(systemctl --failed --no-legend 2>/dev/null | awk 'NF {n++} END {print n+0}')
    [[ "$failed_units" == 0 ]] || failures+=("Unités systemd en échec : $failed_units")

    if command_exists findmnt; then
        findmnt --verify --verbose >/dev/null 2>&1 || failures+=("Vérification de /etc/fstab en échec")
    else
        failures+=("Commande findmnt absente pour contrôler /etc/fstab")
    fi

    [[ "$(grep -E '^[[:space:]]*PASS_MAX_DAYS[[:space:]]+30([[:space:]]|$)' /etc/login.defs 2>/dev/null)" ]] || failures+=("PASS_MAX_DAYS n'est pas 30")
    [[ "$(grep -E '^[[:space:]]*PASS_MIN_DAYS[[:space:]]+1([[:space:]]|$)' /etc/login.defs 2>/dev/null)" ]] || failures+=("PASS_MIN_DAYS n'est pas 1")
    [[ "$(grep -E '^[[:space:]]*PASS_WARN_AGE[[:space:]]+7([[:space:]]|$)' /etc/login.defs 2>/dev/null)" ]] || failures+=("PASS_WARN_AGE n'est pas 7")
    grep -q 'pam_pwquality.so.*minlen=8.*ucredit=-1.*lcredit=-1.*dcredit=-1.*ocredit=-1.*usercheck=1' /etc/pam.d/common-password 2>/dev/null \
        || failures+=("Module PAM pwquality absent ou non conforme")
    grep -q '^auth required pam_google_authenticator.so$' /etc/pam.d/sshd 2>/dev/null \
        || failures+=("Module PAM TOTP absent ou non conforme")
    [[ "$(getent shadow root 2>/dev/null | awk -F: '{print $4 ":" $5 ":" $6}')" == 1:30:7 ]] \
        || failures+=("Politique d'expiration root non conforme")
    for forbidden_user in admin administrator support tech user test cotcod; do
        if getent passwd "$forbidden_user" >/dev/null 2>&1; then failures+=("Compte interdit présent : $forbidden_user"); fi
    done
    mapfile -t admins < <(jq -r '.preparation.authorized_admins[]' "$STATE_FILE")
    authorized_keys=$(printf '/home/%s/.ssh/authorized_keys\n' "${admins[@]}")
    for user in "${admins[@]}"; do
        group_list=$(id -nG "$user" 2>/dev/null || true)
        [[ " $group_list " == *" sudo "* ]] || failures+=("$user n'est pas membre de sudo")
        sudo_check=$(sudo -n -l -U "$user" 2>&1 || true)
        [[ "$sudo_check" == *"(ALL : ALL) ALL"* || "$sudo_check" == *"(ALL:ALL) ALL"* ]] || failures+=("Les privilèges sudo de $user ne sont pas opérationnels")
        home_mode=$(stat -c '%a' "/home/$user" 2>/dev/null || printf absent)
        [[ "$home_mode" == 750 ]] || failures+=("Permissions du home de $user différentes de 750")
        home_owner=$(stat -c '%U' "/home/$user" 2>/dev/null || printf absent)
        [[ "$home_owner" == "$user" ]] || failures+=("Propriétaire du home incorrect pour $user")
        home_mode=$(stat -c '%a' "/home/$user/.ssh" 2>/dev/null || printf absent)
        [[ "$home_mode" == 700 ]] || failures+=("Permissions de .ssh incorrectes pour $user")
        auth_file_mode=$(stat -c '%a' "/home/$user/.ssh/authorized_keys" 2>/dev/null || printf absent)
        [[ "$auth_file_mode" == 600 ]] || failures+=("authorized_keys absent ou permissions incorrectes pour $user")
        if ! awk 'NF && $1 !~ /^#/ {if ($1 != "ssh-ed25519") bad=1; seen=1} END {exit !(seen && !bad)}' "/home/$user/.ssh/authorized_keys" 2>/dev/null; then
            failures+=("authorized_keys de $user ne contient pas uniquement une clé ED25519")
        fi
        key_owner=$(stat -c '%U' "/home/$user/.ssh/authorized_keys" 2>/dev/null || printf absent)
        [[ "$key_owner" == "$user" ]] || failures+=("Propriétaire de authorized_keys incorrect pour $user")
        auth_file_mode=$(stat -c '%a' "/home/$user/.google_authenticator" 2>/dev/null || printf absent)
        [[ "$auth_file_mode" == 600 ]] || failures+=("Secret TOTP absent ou permissions incorrectes pour $user")
        [[ "$(stat -c '%U' "/home/$user/.google_authenticator" 2>/dev/null || true)" == "$user" ]] || failures+=("Propriétaire du secret TOTP incorrect pour $user")
        shadow_policy=$(getent shadow "$user" 2>/dev/null | awk -F: '{print $4 ":" $5 ":" $6}' || true)
        [[ "$shadow_policy" == 1:30:7 ]] || failures+=("Politique d'expiration non conforme pour $user")
    done

    interfaces_json=$(ip -brief address 2>&1 || true)
    links_json=$(ip -brief link 2>&1 || true)
    disks_json=$(lsblk -f 2>&1 || true)
    mounts_json=$(findmnt -rn -o TARGET,SOURCE,FSTYPE,OPTIONS 2>&1 || true)
    storage_json=$(df -h 2>&1 || true)
    components=
    for package_name in openssh-server ufw fail2ban apparmor libpam-google-authenticator; do
        package_version=$(dpkg-query -W -f='${Version}' "$package_name" 2>/dev/null || printf absent)
        components+="$package_name: $package_version"$'\n'
    done
    journal_summary=$(journalctl --disk-usage 2>&1 || true)
    findings=$(printf '%s\n' "${failures[@]}")

    state_update '.report.kernel = $kernel | .report.hostname = $hostname | .report.system = ((.report.system // {}) + {operating_system:$os, kernel:$kernel, upgradable_packages:$upgrades, failed_systemd_units:$failed_units, hardware:{cpu_model:$cpu_model, vcpu:$cpu_count, ram:$ram, machine_id:$serial, total_storage:$total_disk}, component_versions:$components}) | .report.network = ((.report.network // {}) + {expected_ipv4:$expected_ip, active_interfaces:$interfaces, link_addresses:$links, default_route:$route, active_dns:$dns, ntp_synchronized:$ntp, timezone:$timezone}) | .report.storage = ((.report.storage // {}) + {filesystems:$filesystems, block_devices:$disks, mounts:$mounts}) | .report.users.authorized_keys = $authorized_keys | .report.users.root_usage = "réservé aux urgences, SSH interdit" | .report.ssh = ((.report.ssh // {}) + {effective_configuration:$ssh, port:$ssh_port}) | .report.firewall = ((.report.firewall // {}) + {status:$firewall, rules:$ports}) | .report.fail2ban = ((.report.fail2ban // {}) + {sshd_jail:$fail2ban}) | .report.apparmor = ((.report.apparmor // {}) + {status:$apparmor}) | .report.logging = {solution:"systemd-journald", journal_usage:$journal, rotation:"logrotate"} | .report.final_audit = {failures:$findings, performed_at:$now}' \
        --arg kernel "$kernel" --arg hostname "$actual_hostname" --arg os "$os" \
        --arg upgrades "${upgrades:-aucun}" --arg failed_units "$failed_units" \
        --arg cpu_model "${cpu_model:-unknown}" --arg cpu_count "$cpu_count" --arg ram "${ram:-unknown}" \
        --arg serial "$serial_uuid" --arg total_disk "$readable_total" --arg components "$components" \
        --arg expected_ip "$expected_ip" --arg interfaces "$interfaces_json" --arg links "$links_json" \
        --arg authorized_keys "$authorized_keys" \
        --arg route "${default_route:-absente}" --arg dns "$active_dns" \
        --arg ntp "$ntp_state ($timesyncd_active)" --arg timezone "$timezone" --arg filesystems "$storage_json" \
        --arg disks "$disks_json" --arg mounts "$mounts_json" \
        --arg ssh "$sshd_effective" --arg ssh_port "$ssh_port" \
        --arg firewall "$firewall_status" --arg ports "$ports" --arg fail2ban "$fail2ban_status" \
        --arg apparmor "$apparmor_status" --arg journal "$journal_summary" --arg findings "$findings"
    state_update '.report.system.locale = "fr_FR.UTF-8" | .report.system.keyboard = "us" | .report.system.keyboard_status = $keyboard | .report.system.timezone = $timezone | .report.firewall.allowed_inbound_rules = $inbound_rules | .report.apparmor.errors = $apparmor_errors | .report.apparmor.kernel_module = $apparmor_kernel | .report.logging.critical_alerts = $critical' \
        --arg timezone "$timezone" --arg inbound_rules "$inbound_rules" --arg apparmor_errors "$apparmor_errors" --arg keyboard "$keyboard_status" \
        --arg apparmor_kernel "$apparmor_kernel" --arg critical "$journal_critical"

    if ((${#failures[@]})); then
        state_set_status final_audit failed
        printf 'Contrôle final en échec :\n' >&2
        printf ' - %s\n' "${failures[@]}" >&2
        die "Corrigez les points listés puis relancez le contrôle final."
    fi

    state_set_status final_audit succeeded
    state_update '.status = "audit_passed" | .report.validated_at = $now'
    log "Contrôle final réussi. Générer ensuite le rapport PDF pour clôturer la session."
}
