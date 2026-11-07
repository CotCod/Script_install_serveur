#!/usr/bin/env bash

network_inspect() {
    local session_id=$1 interfaces routes dns= ntp_service time_status
    state_require_confirmed preparation
    [[ "$(jq -r '.steps.storage.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Validez d'abord le stockage (chapitre 5)."
    require_command ip
    require_command timedatectl

    interfaces=$(ip -brief address 2>&1 || true)
    routes=$(ip route 2>&1 || true)
    if command_exists resolvectl; then dns=$(resolvectl dns 2>&1 || true); fi
    [[ "$dns" == *1.1.1.1* && "$dns" == *1.0.0.1* ]] || dns=$(cat /etc/resolv.conf 2>&1 || true)
    time_status=$(timedatectl status 2>&1 || true)
    ntp_service=$(systemctl status systemd-timesyncd --no-pager 2>&1 || true)

    state_update '.steps.network.audit_status = "inspected" | .steps.network.inspected_at = $now | .report.network = ((.report.network // {}) + {interfaces:$interfaces, routes:$routes, dns:$dns, time_status:$time_status, timesyncd:$ntp, inspected_at:$now})' \
        --arg interfaces "$interfaces" --arg routes "$routes" --arg dns "$dns" \
        --arg time_status "$time_status" --arg ntp "$ntp_service"
    printf '%s\n' "$interfaces"
    printf '\nRoutes:\n%s\n' "$routes"
    printf '\nDNS:\n%s\n' "$dns"
    printf '\nSynchronisation horaire:\n%s\n' "$time_status"
    log "Inventaire réseau enregistré en lecture seule."
    log "Après application/vérification de l'IP fixe, de la passerelle, des DNS et du NTP, utilisez --record-manual network --session $session_id."
}

network_configure() {
    local session_id=$1 route interface detected_ip detected_prefix gateway ip prefix choice
    local os network_kind config_path archive backup_dir rollback_unit config_content current_ip netmask
    local iface_match config_files iface_count network_state alternative_pkg confirmation
    local -a alternative_ntp=()
    state_require_confirmed preparation
    [[ "$(jq -r '.steps.storage.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Validez d'abord le stockage (chapitre 5)."
    [[ "$(jq -r '.steps.network.audit_status // ""' "$STATE_FILE")" == inspected ]] \
        || die "Lancez d'abord --inspect-network pour relever l'interface, l'adresse et la passerelle."
    network_state=$(jq -r '.steps.network.configuration // "not_started"' "$STATE_FILE")
    if [[ "$network_state" == in_progress || "$network_state" == failed ]]; then
        rollback_unit="cotcod-net-rollback-${session_id}"
        systemctl is-active --quiet "$rollback_unit.timer" \
            && die "Le retour arrière réseau est encore programmé; attendez son exécution avant toute reprise."
        read -r -p "Après vérification de la restauration réseau, tapez REINITIALISER-RESEAU : " choice \
            || die "Lecture interrompue."
        [[ "$choice" == REINITIALISER-RESEAU ]] || die "Reprise réseau annulée."
        state_update '.steps.network.configuration = "not_started" | .steps.network.audit_status = "stale"'
        network_state=not_started
    fi
    [[ "$network_state" == not_started ]] || die "La configuration réseau a déjà été validée."
    require_command ip
    require_command python3
    require_command systemd-run
    require_command tar

    route=$(ip -4 route show default | head -n1)
    interface=$(awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}' <<< "$route")
    gateway=$(awk '{for (i=1;i<=NF;i++) if ($i=="via") {print $(i+1); exit}}' <<< "$route")
    detected_ip=$(jq -r '.preparation.ip_address // ""' "$STATE_FILE")

    while :; do
        read -r -p "Interface réseau [$interface] : " choice || die "Lecture interrompue."
        interface=${choice:-$interface}
        [[ "$interface" =~ ^[a-zA-Z0-9_.-]{1,15}$ ]] && break
        warn "Nom d'interface invalide."
    done
    current_ip=$(ip -4 -o address show dev "$interface" scope global 2>/dev/null | awk -v ip="$detected_ip" '{split($4,cidr,"/"); if (cidr[1] == ip) {print $4; found=1; exit} if (NR == 1) first=$4} END {if (NR && !found) print first}')
    detected_prefix=${current_ip#*/}
    while :; do
        read -r -p "Adresse IPv4 statique [$detected_ip] : " choice || die "Lecture interrompue."
        ip=${choice:-$detected_ip}
        valid_ipv4 "$ip" && break
        warn "Adresse IPv4 invalide."
    done
    while :; do
        read -r -p "Préfixe CIDR (ex. 24) [$detected_prefix] : " choice || die "Lecture interrompue."
        prefix=${choice:-$detected_prefix}
        [[ "$prefix" =~ ^([1-9]|[12][0-9]|3[0-2])$ ]] && break
        warn "Le préfixe IPv4 doit être un entier entre 1 et 32."
    done
    while :; do
        read -r -p "Passerelle IPv4 [$gateway] : " choice || die "Lecture interrompue."
        gateway=${choice:-$gateway}
        valid_ipv4 "$gateway" || { warn "Adresse IPv4 invalide."; continue; }
        if python3 - "$ip" "$prefix" "$gateway" <<'PY'
import ipaddress, sys
address, prefix, gateway = sys.argv[1], int(sys.argv[2]), sys.argv[3]
network = ipaddress.ip_network(f"{address}/{prefix}", strict=False)
addr, gw = ipaddress.ip_address(address), ipaddress.ip_address(gateway)
reserved = prefix <= 30 and addr in (network.network_address, network.broadcast_address)
raise SystemExit(0 if gw in network and gw != addr and not reserved else 1)
PY
        then break; fi
        warn "La passerelle doit être différente de l'adresse serveur et appartenir au même sous-réseau."
    done

    source /etc/os-release
    case "${ID:-}" in
        ubuntu)
            command_exists netplan || die "Netplan est absent; configurez le réseau manuellement."
            network_kind=netplan
            config_path=/etc/netplan/99-cotcod.yaml
            config_content=$(cat <<EOF
network:
  version: 2
  ethernets:
    $interface:
      dhcp4: false
      addresses: [$ip/$prefix]
      routes:
        - to: default
          via: $gateway
      nameservers:
        addresses: [1.1.1.1, 1.0.0.1]
EOF
)
            ;;
        debian)
            command_exists ifup && command_exists ifdown || die "ifupdown n'est pas installé; configurez le réseau manuellement avant de poursuivre."
            command_exists resolvconf || die "resolvconf est requis pour appliquer les DNS ifupdown; terminez l'installation de base puis relancez."
            network_kind=ifupdown
            netmask=$(python3 -c 'import ipaddress,sys; print(ipaddress.IPv4Network("0.0.0.0/"+sys.argv[1]).netmask)' "$prefix")
            config_files=(/etc/network/interfaces /etc/network/interfaces.d/*)
            iface_count=$(awk -v iface="$interface" '$1 == "iface" && $2 == iface && $3 == "inet" {n++} END {print n+0}' "${config_files[@]}" 2>/dev/null || true)
            [[ "${iface_count:-0}" != 0 && "${iface_count:-0}" != 1 ]] && die "Plusieurs configurations ifupdown existent pour $interface; intervention manuelle requise."
            iface_match=$(awk -v iface="$interface" '$1 == "iface" && $2 == iface && $3 == "inet" {files[FILENAME]=1} END {for (f in files) print f}' "${config_files[@]}" 2>/dev/null || true)
            [[ "$iface_match" != *$'\n'* ]] || die "Plusieurs configurations ifupdown existent pour $interface; intervention manuelle requise."
            config_path=${iface_match:-/etc/network/interfaces.d/99-cotcod.cfg}
            if [[ -n "$iface_match" ]]; then
                config_content=$(awk -v iface="$interface" -v ip="$ip" -v mask="$netmask" -v gw="$gateway" '
                    function emit_config() {
                        print "    address " ip
                        print "    netmask " mask
                        print "    gateway " gw
                        print "    dns-nameservers 1.1.1.1 1.0.0.1"
                    }
                    $1 == "iface" {
                        if (in_target && !emitted) { emit_config(); emitted=1 }
                        in_target=($2 == iface && $3 == "inet")
                        if (in_target) { print "iface " iface " inet static"; next }
                    }
                    in_target && $1 ~ /^(address|netmask|gateway|dns-nameservers)$/ { next }
                    { print }
                    END { if (in_target && !emitted) emit_config() }
                ' "$config_path")
            else
                config_content=$(cat <<EOF
allow-hotplug $interface
iface $interface inet static
    address $ip
    netmask $netmask
    gateway $gateway
    dns-nameservers 1.1.1.1 1.0.0.1
EOF
)
            fi
            ;;
        *) die "Distribution non prise en charge pour la configuration réseau : ${ID:-unknown}" ;;
    esac

    printf 'Configuration prévue : %s, %s/%s, passerelle %s, DNS 1.1.1.1 et 1.0.0.1.\n' "$interface" "$ip" "$prefix" "$gateway"
    printf 'Un retour arrière automatique sera programmé dans quinze minutes. Confirmez uniquement si vous pouvez tester une nouvelle connexion.\n'
    read -r -p "Tapez APPLIQUER-RESEAU pour continuer : " choice || die "Lecture interrompue."
    [[ "$choice" == APPLIQUER-RESEAU ]] || die "Configuration réseau annulée."

    for alternative_pkg in chrony ntp ntpsec openntpd; do
        [[ "$(dpkg-query -W -f='${db:Status-Status}' "$alternative_pkg" 2>/dev/null || true)" == installed ]] \
            && alternative_ntp+=("$alternative_pkg")
    done
    if ((${#alternative_ntp[@]})); then
        printf 'Le protocole impose systemd-timesyncd. Les services horaires alternatifs suivants sont installés : %s\n' "${alternative_ntp[*]}"
        read -r -p "Leurs configurations seront sauvegardées puis les paquets purgés. Tapez RETIRER-NTP-ALTERNATIF : " confirmation \
            || die "Lecture interrompue."
        [[ "$confirmation" == RETIRER-NTP-ALTERNATIF ]] || die "Retrait des services horaires alternatifs annulé."
        backup_dir="$STATE_DIR/backups/$session_id"
        mkdir -p -- "$backup_dir"
        chmod 700 -- "$STATE_DIR/backups" "$backup_dir"
        backup_file /etc/chrony "$backup_dir"
        backup_file /etc/ntp.conf "$backup_dir"
        backup_file /etc/ntpsec "$backup_dir"
        backup_file /etc/openntpd "$backup_dir"
        dpkg --get-selections > "$backup_dir/dpkg-selections-before-ntp-purge.txt"
        chmod 600 "$backup_dir/dpkg-selections-before-ntp-purge.txt"
        state_update '.steps.network.alternative_ntp = {status:"removing", packages:$packages}' --argjson packages "$(printf '%s\n' "${alternative_ntp[@]}" | jq -R . | jq -s .)"
        apt-get purge -y -- "${alternative_ntp[@]}" || { state_update '.steps.network.alternative_ntp.status = "failed"'; die "Échec de la purge des services horaires alternatifs."; }
        state_update '.steps.network.alternative_ntp.status = "removed" | .steps.network.alternative_ntp.removed_at = $now'
    fi

    backup_dir="$STATE_DIR/backups/$session_id"
    mkdir -p -- "$backup_dir"
    chmod 700 -- "$STATE_DIR/backups" "$backup_dir"
    if [[ "$network_kind" == netplan ]]; then
        backup_file /etc/netplan "$backup_dir"
        archive="$backup_dir/netplan-before.tar.gz"
        tar -C /etc -czf "$archive" netplan
    else
        backup_file /etc/network "$backup_dir"
        archive="$backup_dir/network-before.tar.gz"
        tar -C /etc -czf "$archive" network
    fi
    chmod 600 "$archive"
    if [[ -e "$config_path" ]]; then backup_file "$config_path" "$backup_dir"; fi

    rollback_unit="cotcod-net-rollback-${session_id}"
    state_update '.steps.network.audit_status = "stale" | .steps.network.configuration = "in_progress" | .steps.network.planned_address = $ip | .steps.network.prefix = $prefix | .steps.network.gateway = $gateway | .steps.network.interface = $interface | .report.network.plan = {interface:$interface, ipv4:$ip, prefix:$prefix, gateway:$gateway, dns:["1.1.1.1","1.0.0.1"], file:$file, mode:$mode}' \
        --arg interface "$interface" --arg ip "$ip" --arg prefix "$prefix" \
        --arg gateway "$gateway" --arg file "$config_path" --arg mode "$network_kind"
    if ! systemd-run --unit="$rollback_unit" --on-active=15m /bin/bash "$SCRIPT_DIR/lib/rollback-network.sh" "$archive" "$network_kind" "$interface"; then
        /bin/bash "$SCRIPT_DIR/lib/rollback-network.sh" "$archive" "$network_kind" "$interface" || true
        state_update '.steps.network.configuration = "not_started"'
        die "Impossible de programmer le retour arrière; la configuration précédente a été restaurée."
    fi

    if [[ "$network_kind" == ifupdown && "$config_path" == /etc/network/interfaces.d/* ]] \
        && ! grep -Eq '^[[:space:]]*source(-directory)?[[:space:]]+/etc/network/interfaces\.d(/\*)?([[:space:]]|$)' /etc/network/interfaces; then
        printf '\nsource /etc/network/interfaces.d/*\n' >> /etc/network/interfaces
    fi
    write_config_file "$config_path" "$config_content"
    [[ "$network_kind" != netplan ]] || chmod 600 "$config_path"

    if [[ "$network_kind" == netplan ]]; then
        netplan generate || die "netplan generate a échoué; le retour arrière reste programmé."
        netplan try --timeout 180 || die "netplan try a échoué ou a été annulé; le retour arrière reste programmé."
    else
        ifdown --force "$interface" || true
        ifup "$interface" || die "ifup a échoué; le retour arrière reste programmé."
    fi

    if ! ip -4 -o address show dev "$interface" | awk -v ip="$ip" -v prefix="$prefix" '$4 == ip "/" prefix {found=1} END {exit !found}' \
        || ! ip -4 route show default | grep -Fq "via $gateway"; then
        die "La nouvelle adresse ou la route n'est pas active; le retour arrière reste programmé."
    fi
    printf 'L’adresse et la route sont actives. Testez maintenant depuis le poste technicien la connexion SSH et l’accès à Internet.\n'
    read -r -p "Tapez GARDER-RESEAU uniquement si les tests externes réussissent : " choice || die "Lecture interrompue; le retour arrière reste programmé."
    [[ "$choice" == GARDER-RESEAU ]] || die "Réseau non validé; le retour arrière reste programmé."
    if ! ip -4 -o address show dev "$interface" | awk -v ip="$ip" -v prefix="$prefix" '$4 == ip "/" prefix {found=1} END {exit !found}' \
        || ! ip -4 route show default | grep -Fq "via $gateway"; then
        die "La configuration a été annulée pendant le test; le retour arrière reste programmé."
    fi
    backup_file /etc/localtime "$backup_dir"
    backup_file /etc/systemd/timesyncd.conf "$backup_dir"
    timedatectl set-timezone Europe/Paris
    apt-get install -y --no-install-recommends systemd-timesyncd
    systemctl enable --now systemd-timesyncd
    if systemctl is-active --quiet "$rollback_unit.timer"; then
        systemctl stop "$rollback_unit.timer" || die "Impossible d'annuler le retour arrière; la sauvegarde reste disponible."
    fi
    systemctl is-active --quiet "$rollback_unit.timer" && die "Le retour arrière réseau est toujours actif."
    if ! ip -4 -o address show dev "$interface" | awk -v ip="$ip" -v prefix="$prefix" '$4 == ip "/" prefix {found=1} END {exit !found}' \
        || ! ip -4 route show default | grep -Fq "via $gateway"; then
        die "Le retour arrière réseau s'est déclenché pendant la configuration de l'horloge; la session n'est pas validée."
    fi
    state_update '.preparation.ip_address = $ip | .steps.network.configuration = "succeeded" | .steps.network.configured_at = $now | .report.network = ((.report.network // {}) + {interface:$interface, ipv4:$ip, prefix:$prefix, gateway:$gateway, dns_primary:"1.1.1.1", dns_secondary:"1.0.0.1", method:$mode, config_file:$file, configured_at:$now})' \
        --arg interface "$interface" --arg ip "$ip" --arg prefix "$prefix" \
        --arg gateway "$gateway" --arg mode "$network_kind" --arg file "$config_path"
    state_update '.report.network.timezone = "Europe/Paris" | .report.network.timesyncd = "enabled"'
    log "Configuration réseau statique appliquée et confirmée. Lancez --inspect-network puis validez le contrôle avec --record-manual network."
}

verify_installation_iso() {
    local session_id=$1 iso_path expected_hash source_url actual_hash
    state_require_confirmed preparation
    require_command sha256sum
    while :; do
        read -r -p "Chemin de l'image ISO à vérifier : " iso_path || die "Lecture interrompue."
        [[ -f "$iso_path" && -r "$iso_path" ]] && break
        warn "Fichier ISO introuvable ou illisible; vérifiez le chemin."
    done
    while :; do
        prompt_value expected_hash "SHA-256 officiel publié par l'éditeur : "
        expected_hash=${expected_hash,,}
        [[ "$expected_hash" =~ ^[0-9a-f]{64}$ ]] && break
        warn "Le SHA-256 doit contenir exactement 64 caractères hexadécimaux."
    done
    prompt_value source_url "Source officielle de téléchargement : "
    actual_hash=$(sha256sum -- "$iso_path" | awk '{print $1}')
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        state_update '.steps.iso_verification = {status:"failed", expected_sha256:$expected, actual_sha256:$actual, source:$source, verified_at:$now} | .non_conformities += [{severity:"critical", step:"iso_verification", description:"Le SHA-256 de l’ISO ne correspond pas à la valeur officielle."}]' \
            --arg expected "$expected_hash" --arg actual "$actual_hash" --arg source "$source_url"
        die "SHA-256 invalide : l'image ne doit pas être utilisée."
    fi
    state_update '.steps.iso_verification = {status:"succeeded", image:$image, sha256:$actual, source:$source, verified_at:$now} | .report.system.iso = {image:$image, sha256:$actual, source:$source, verified_at:$now}' \
        --arg image "$iso_path" --arg actual "$actual_hash" --arg source "$source_url"
    log "Image ISO vérifiée; SHA-256 conforme."
}
