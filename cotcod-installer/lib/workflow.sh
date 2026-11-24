#!/usr/bin/env bash

collect_preparation() {
    local session_id=$1 client hostname ip role criticality admins detected_ip choice admin_index other_index
    local -a admin_list
    while :; do
        prompt_value client "Nom du client : "
        [[ "$client" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && break
        warn "Nom client invalide : utilisez 1 à 32 minuscules, chiffres ou tirets."
    done
    while :; do
        prompt_value role "Rôle du serveur : "
        [[ "$role" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && break
        warn "Rôle invalide : utilisez 1 à 32 minuscules, chiffres ou tirets."
    done
    while :; do
        prompt_value hostname "Nom du serveur (srv-${client}-${role}XX) : "
        [[ "$hostname" =~ ^srv-${client}-${role}[0-9]{2}$ ]] && break
        warn "Nom de serveur invalide : il doit respecter srv-${client}-${role} suivi de deux chiffres."
    done

    detected_ip=$(detect_primary_ipv4) || detected_ip=
    if [[ -n "$detected_ip" ]]; then
        log "Adresse IPv4 principale détectée automatiquement : $detected_ip"
        while :; do
            read -r -p "Utiliser cette adresse ? [Y/n] " choice || die "Lecture interrompue."
            choice=${choice,,}
            case "$choice" in
                ""|y|yes) ip=$detected_ip; break ;;
                n|no) ip=; break ;;
                *) warn "Répondez par Y (yes) ou n (no)." ;;
            esac
        done
    else
        warn "Aucune adresse IPv4 principale détectée; saisissez-la manuellement."
        ip=
    fi
    if [[ -z "$ip" ]]; then
        while :; do
            prompt_value ip "Adresse IPv4 du serveur : "
            valid_ipv4 "$ip" && break
            warn "Adresse IPv4 invalide : saisissez quatre nombres entre 0 et 255, séparés par des points."
        done
    fi
    while :; do
        prompt_value criticality "Criticité (faible/moyenne/haute/critique) : "
        [[ "$criticality" =~ ^(faible|moyenne|haute|critique)$ ]] && break
        warn "Choisissez faible, moyenne, haute ou critique."
    done
    while :; do
        prompt_value admins "Comptes administrateurs autorisés (séparés par des virgules) : "
        if [[ ${#admins} -gt 512 || ! "$admins" =~ ^[a-z_][a-z0-9_-]*[a-z0-9_](,[a-z_][a-z0-9_-]*[a-z0-9_])*$ ]]; then
            warn "Liste invalide : saisissez des identifiants Linux séparés par des virgules."
            continue
        fi
        if [[ ",$admins," =~ ,(admin|administrator|support|tech|user|test|cotcod)(,|,) ]]; then
            warn "La liste contient un compte interdit par le protocole."
            continue
        fi
        IFS=, read -r -a admin_list <<< "$admins"
        local admins_valid=true
        for admin_index in "${!admin_list[@]}"; do
            if ((${#admin_list[$admin_index]} > 32)); then admins_valid=false; break; fi
            for other_index in "${!admin_list[@]}"; do
                [[ "$other_index" -gt "$admin_index" ]] || continue
                if [[ "${admin_list[$admin_index]}" == "${admin_list[$other_index]}" ]]; then admins_valid=false; break 2; fi
            done
        done
        [[ "$admins_valid" == true ]] || { warn "Chaque identifiant doit être unique et ne pas dépasser 32 caractères."; continue; }
        break
    done
    state_put_preparation "$client" "$hostname" "$ip" "$role" "$criticality" "$admins"
    log "Préparation enregistrée pour $hostname."
    state_show_preparation
    local confirmation
    read -r -p "Vérifiez ces informations. Tapez CONFIRMER pour continuer : " confirmation || die "Lecture interrompue."
    [[ "$confirmation" == CONFIRMER ]] || die "Préparation non confirmée; aucune action système effectuée."
    state_confirm_preparation
}

workflow_status() {
    jq -r --arg step "$1" '.steps[$step].status // "not_started"' "$STATE_FILE"
}

workflow_attest() {
    local step=$1 instruction=$2
    [[ "$(workflow_status "$step")" != succeeded ]] || return 0
    printf '\nContrôle technicien requis : %s\n' "$instruction"
    read -r -p "Réalisez ce contrôle maintenant, puis appuyez sur Entrée pour le consigner. " _ || die "Lecture interrompue."
    record_manual_step "$step"
}

run_installation_workflow() {
    local session_id=$1 boot_id_before current_boot
    printf '\n=== Assistant CotCod Setup Essentiel ===\n'
    printf 'L’assistant conserve sa progression. Après un redémarrage demandé, relancez simplement : sudo ./cotcod-installer.sh\n\n'
    preflight

    if [[ "$(jq -r '.preparation.client // empty' "$STATE_FILE")" == "" ]]; then
        collect_preparation "$session_id"
    elif [[ "$(jq -r '.steps.preparation.confirmed // false' "$STATE_FILE")" != true ]]; then
        state_show_preparation
        local confirmation
        read -r -p "Tapez CONFIRMER pour valider ces informations : " confirmation || die "Lecture interrompue."
        [[ "$confirmation" == CONFIRMER ]] || die "Préparation non confirmée."
        state_confirm_preparation
    fi
    state_require_confirmed preparation

    if [[ "$(workflow_status base_installation)" != succeeded ]]; then
        if [[ "$(workflow_status base_installation)" == not_started ]]; then base_prepare; fi
        base_apply "$session_id"
    fi
    if [[ "$(workflow_status base_reboot)" == required ]]; then
        boot_id_before=$(jq -r '.steps.base_reboot.boot_id_before' "$STATE_FILE")
        current_boot=$(cat /proc/sys/kernel/random/boot_id)
        if [[ "$current_boot" == "$boot_id_before" ]]; then
            warn "Un redémarrage est requis pour continuer. Redémarrez le serveur, puis relancez sudo ./cotcod-installer.sh."
            return 0
        fi
        workflow_attest base_reboot "Le serveur a redémarré après les mises à jour."
    fi
    workflow_attest services_review "Examinez les services actifs affichés; désactivez ceux qui ne sont pas nécessaires."

    if [[ "$(workflow_status storage)" != succeeded ]]; then
        storage_inspect "$session_id"
        workflow_attest storage "Vérifiez les disques, systèmes de fichiers, montages et la validation de /etc/fstab."
    fi
    if [[ "$(workflow_status network)" != succeeded ]]; then
        if [[ "$(jq -r '.steps.network.audit_status // ""' "$STATE_FILE")" != inspected ]]; then network_inspect "$session_id"; fi
        if [[ "$(jq -r '.steps.network.configuration // "not_started"' "$STATE_FILE")" != succeeded ]]; then network_configure "$session_id"; fi
        network_inspect "$session_id"
        workflow_attest network "Depuis le poste technicien, vérifiez l’adresse fixe, la passerelle, le DNS et l’accès SSH."
    fi
    if [[ "$(workflow_status users)" != succeeded ]]; then users_apply "$session_id"; fi

    if [[ "$(workflow_status ssh)" != succeeded ]]; then
        if [[ "$(jq -r '.steps.ssh.initial_configuration // ""' "$STATE_FILE")" != succeeded ]]; then ssh_initial_configure "$session_id"; fi
        workflow_attest ssh_key_test "Ouvrez une nouvelle session SSH sur le port 22 avec une clé ED25519."
        if [[ "$(jq -r '.steps.ssh.hardening // "not_started"' "$STATE_FILE")" != succeeded ]]; then ssh_harden "$session_id"; fi
        workflow_attest ssh_password_test "Confirmez une nouvelle connexion par clé après désactivation des mots de passe."
        if [[ "$(jq -r '.steps.ssh.port_change // "not_started"' "$STATE_FILE")" != succeeded ]]; then ssh_change_port "$session_id"; fi
        workflow_attest ssh "Ouvrez une nouvelle session SSH par clé sur le port personnalisé."
    fi
    if [[ "$(workflow_status mfa)" != succeeded ]]; then
        if [[ "$(workflow_status mfa)" == not_started ]]; then mfa_configure "$session_id"; fi
        workflow_attest mfa "Testez une nouvelle connexion avec clé ED25519 et code TOTP."
    fi
    if [[ "$(workflow_status firewall)" != succeeded || "$(workflow_status apparmor)" != succeeded ]]; then
        protection_configure "$session_id"
    fi
    workflow_attest firewall "Vérifiez qu’une nouvelle connexion SSH reste possible après activation du pare-feu."
    workflow_attest external_scan "Depuis un réseau externe, vérifiez que seul le port SSH attendu est exposé."
    workflow_attest fail2ban "Effectuez un test Fail2Ban depuis un poste de test, puis vérifiez le déblocage."

    if [[ "$(workflow_status reboot_validation)" != succeeded ]]; then
        boot_id_before=$(jq -r '.steps.reboot_validation.boot_id_before // empty' "$STATE_FILE")
        current_boot=$(cat /proc/sys/kernel/random/boot_id)
        if [[ -z "$boot_id_before" || "$current_boot" == "$boot_id_before" ]]; then
            warn "Redémarrez le serveur pour vérifier la persistance des protections, puis relancez sudo ./cotcod-installer.sh."
            return 0
        fi
        workflow_attest reboot_validation "Vérifiez après redémarrage l’accès SSH, le pare-feu et les services de protection."
    fi

    audit_final
    generate_session_report "$session_id"
}
