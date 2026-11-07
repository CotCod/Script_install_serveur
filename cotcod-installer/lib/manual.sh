#!/usr/bin/env bash

record_manual_step() {
    local step=$1 label confirmation evidence required_step
    case "$step" in
        iso_verification) label="Vérification de provenance et checksum ISO (chapitre 3)" ;;
        os_support) label="Validation de la distribution, version LTS/Stable et adéquation à la demande (chapitres 2 à 4)" ;;
        base_reboot) label="Redémarrage requis après mise à jour initiale (chapitre 4)" ;;
        services_review) label="Revue des services actifs et désactivation des services inutiles (chapitre 4)" ;;
        storage) label="Contrôle/validation du partitionnement et des montages (chapitre 5)" ;;
        network) label="Test de connectivité et validation réseau depuis le poste technicien (chapitre 6)" ;;
        users) label="Validation des comptes nominatifs, de sudo et des permissions (chapitre 7)" ;;
        ssh_key_test) label="Test d'une nouvelle connexion SSH ED25519 sur le port 22 avant durcissement (chapitre 8)" ;;
        ssh_password_test) label="Test d'une nouvelle connexion SSH par clé après désactivation du mot de passe (chapitre 8)" ;;
        ssh) label="Test d'une nouvelle connexion SSH par clé sur le port final (chapitre 8)" ;;
        mfa) label="Test de connexion SSH avec clé ED25519 et code TOTP (chapitre 9)" ;;
        firewall) label="Test de connectivité SSH après activation du pare-feu (chapitre 10)" ;;
        external_scan) label="Vérification externe qu'uniquement SSH est exposé (chapitre 10)" ;;
        fail2ban) label="Test de bannissement puis déblocage Fail2Ban depuis un poste de test (chapitre 11)" ;;
        reboot_validation) label="Validation après redémarrage du serveur (chapitres 10, 12 et 13)" ;;
        *) die "Étape manuelle inconnue : $step" ;;
    esac

    case "$step" in
        iso_verification)
            [[ "$(jq -r '.steps.iso_verification.status // "not_started"' "$STATE_FILE")" != failed ]] \
                || die "Une vérification SHA-256 a échoué; cette non-conformité critique ne peut pas être annulée par une attestation."
            ;;
        os_support)
            [[ -n "$(jq -r '.host.distribution // empty' "$STATE_FILE")" && -n "$(jq -r '.host.version // empty' "$STATE_FILE")" ]] \
                || die "L'inventaire du système est absent."
            printf 'Système détecté : %s %s (%s)\n' "$(jq -r '.host.distribution' "$STATE_FILE")" "$(jq -r '.host.version' "$STATE_FILE")" "$(jq -r '.host.architecture' "$STATE_FILE")"
            ;;
        storage)
            [[ "$(jq -r '.steps.base_installation.status // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Terminez l'installation initiale avant de valider le stockage."
            [[ "$(jq -r '.steps.storage.audit_status // ""' "$STATE_FILE")" == inspected ]] \
                || die "Lancez d'abord l'inventaire avec --inspect-storage."
            ;;
        services_review)
            [[ "$(jq -r '.steps.base_installation.status // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Terminez l'installation initiale avant de revoir les services."
            jq -e '.steps.base_installation.inventory.running_services != null' "$STATE_FILE" >/dev/null \
                || die "L'inventaire des services actifs est absent; relancez --prepare-base."
            local running_services
            running_services=$(systemctl list-units --type=service --state=running --no-legend --no-pager) \
                || die "Impossible de relever les services actifs après installation."
            state_update '.steps.base_installation.inventory.running_services_after_install = $services | .report.system.running_services_after_install = $services' --arg services "$running_services"
            printf 'Services actifs après installation :\n%s\n' "$running_services"
            printf 'Désactivez et arrêtez après examen les services inutiles, puis attestez la revue.\n'
            ;;
        base_reboot)
            [[ "$(jq -r '.steps.base_reboot.status // ""' "$STATE_FILE")" == required ]] || die "Aucun redémarrage initial n'est requis dans cette session."
            [[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(jq -r '.steps.base_reboot.boot_id_before' "$STATE_FILE")" ]] || die "Le noyau n'a pas redémarré depuis la mise à jour."
            ;;
        network)
            [[ "$(jq -r '.steps.storage.status // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Validez d'abord le partitionnement et les montages."
            [[ "$(jq -r '.steps.network.audit_status // ""' "$STATE_FILE")" == inspected ]] \
                || die "Lancez d'abord l'inventaire avec --inspect-network."
            [[ "$(jq -r '.steps.network.configuration // "not_started"' "$STATE_FILE")" != in_progress && "$(jq -r '.steps.network.configuration // "not_started"' "$STATE_FILE")" != failed ]] \
                || die "Le retour arrière réseau doit être terminé et sa restauration vérifiée avant validation."
            [[ "$(jq -r '.steps.network.configuration // "not_started"' "$STATE_FILE")" == succeeded ]] \
                || die "Appliquez et confirmez d'abord la configuration réseau avec --configure-network."
            ;;
        users)
            [[ "$(jq -r '.steps.network.status // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Validez d'abord la configuration réseau."
            ;;
        ssh)
            [[ "$(jq -r '.steps.users.status // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Configurez et validez d'abord les comptes administrateurs."
            [[ "$(jq -r '.steps.ssh.hardening // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Désactivez d'abord l'authentification SSH par mot de passe."
            [[ "$(jq -r '.steps.ssh.port_change // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Changez d'abord le port SSH après le test intermédiaire."
            ;;
        ssh_password_test)
            [[ "$(jq -r '.steps.ssh.hardening // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Désactivez d'abord l'authentification SSH par mot de passe."
            ;;
        ssh_key_test)
            [[ "$(jq -r '.steps.ssh.initial_configuration // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Appliquez d'abord la configuration SSH initiale."
            ;;
        mfa)
            [[ "$(jq -r '.steps.ssh.status // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Validez d'abord l'accès SSH par clé sur son port final."
            ;;
        firewall|external_scan)
            [[ "$(jq -r '.steps.firewall.status // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Configurez d'abord UFW et validez l'accès SSH."
            if [[ "$step" == external_scan ]]; then
                [[ "$(jq -r '.steps.firewall.completion_type // ""' "$STATE_FILE")" == technician_attestation ]] \
                    || die "Consignez d'abord le test SSH après activation du pare-feu."
            fi
            ;;
        fail2ban)
            [[ "$(jq -r '.steps.fail2ban.status // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Configurez d'abord Fail2Ban."
            [[ "$(jq -r '.steps.external_scan.status // ""' "$STATE_FILE")" == succeeded ]] \
                || die "Consignez d'abord le scan externe après activation du pare-feu."
            ;;
        reboot_validation)
            for required_step in firewall external_scan fail2ban sysctl apparmor; do
                [[ "$(jq -r --arg step "$required_step" '.steps[$step].status // ""' "$STATE_FILE")" == succeeded ]] \
                    || die "Terminez d'abord l'étape '$required_step'."
            done
            [[ -n "$(jq -r '.steps.reboot_validation.boot_id_before // empty' "$STATE_FILE")" ]] \
                || die "La configuration n'a pas enregistré l'identifiant de démarrage avant le redémarrage."
            [[ "$(cat /proc/sys/kernel/random/boot_id)" != "$(jq -r '.steps.reboot_validation.boot_id_before' "$STATE_FILE")" ]] \
                || die "Le serveur n'a pas redémarré depuis la configuration des protections."
            ;;
    esac

    printf 'Étape manuelle à valider : %s\n' "$label"
    printf 'Ne confirmez qu’après avoir réalisé et vérifié ce contrôle.\n'
    read -r -p "Tapez CONFIRMER pour consigner sa réussite : " confirmation \
        || die "Lecture interrompue."
    [[ "$confirmation" == CONFIRMER ]] || die "Validation annulée."
    prompt_text evidence "Note ou référence de preuve (sans secret) : "
    state_record_manual_step "$step" "$evidence"
    log "Étape manuelle '$step' consignée comme validée par le technicien."
}
