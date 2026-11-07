#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
readonly SCRIPT_DIR
umask 077

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/state.sh"
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/base.sh"
source "$SCRIPT_DIR/lib/manual.sh"
source "$SCRIPT_DIR/lib/audit.sh"
source "$SCRIPT_DIR/lib/protections.sh"
source "$SCRIPT_DIR/lib/users.sh"
source "$SCRIPT_DIR/lib/storage.sh"
source "$SCRIPT_DIR/lib/network.sh"
source "$SCRIPT_DIR/lib/ssh.sh"
source "$SCRIPT_DIR/lib/report.sh"

usage() {
    cat <<'EOF'
Usage: cotcod-installer.sh [options]

Options:
  --check-only          Run non-invasive prerequisite checks only
  --prepare             Collecter et enregistrer les informations de préparation
  --show-preparation    Afficher les informations et étapes préparées
  --confirm-preparation Confirmer la revue de la préparation (aucune action système)
  --prepare-base        Préparer l'inventaire et le plan d'installation initial
  --apply-base          Appliquer le plan initial après confirmation explicite
  --record-manual STEP  Consigner un contrôle manuel après vérification
  --final-audit        Contrôler la conformité finale et clôturer la session
  --apply-protections  Configurer UFW, Fail2Ban, sysctl et AppArmor
  --apply-users        Configurer la politique des mots de passe et comptes sudo
  --inspect-storage    Relever les disques, montages et valider fstab (lecture seule)
  --inspect-network    Relever interfaces, routes, DNS et synchronisation (lecture seule)
  --configure-network  Configurer l'IPv4 statique avec retour arrière programmé
  --verify-iso          Vérifier le SHA-256 d'une image ISO
  --configure-ssh       Installer SSH et configurer les paramètres initiaux
  --harden-ssh          Désactiver le mot de passe SSH après le test de clé
  --change-ssh-port     Déplacer SSH vers un port aléatoire après test séparé
  --configure-mfa       Enrôler les administrateurs et activer le TOTP
  --generate-report     Générer un rapport PDF de l'état de la session
  --state-dir DIR       Store session data in DIR (default: /var/lib/cotcod-installer)
  --session ID          Resume the specified session
  --help                Show this help
EOF
}

main() {
    local action= state_dir=/var/lib/cotcod-installer session_id= manual_step=

    while (($#)); do
        case "$1" in
            --check-only) action=check ;;
            --prepare) action=prepare ;;
            --show-preparation) action=show ;;
            --confirm-preparation) action=confirm ;;
            --prepare-base) action=base ;;
            --apply-base) action=apply_base ;;
            --record-manual) [[ $# -ge 2 ]] || die "--record-manual attend un nom d'étape"; action=manual; manual_step=$2; shift ;;
            --final-audit) action=audit ;;
            --apply-protections) action=protections ;;
            --apply-users) action=users ;;
            --inspect-storage) action=storage ;;
            --inspect-network) action=network ;;
            --configure-network) action=network_apply ;;
            --verify-iso) action=iso ;;
            --configure-ssh) action=ssh_initial ;;
            --harden-ssh) action=ssh_harden ;;
            --change-ssh-port) action=ssh_port ;;
            --configure-mfa) action=mfa ;;
            --generate-report) action=report ;;
            --state-dir) [[ $# -ge 2 ]] || die "--state-dir attend un chemin"; state_dir=$2; shift ;;
            --session) [[ $# -ge 2 ]] || die "--session attend un identifiant"; session_id=$2; shift ;;
            --help|-h) usage; return 0 ;;
            *) die "Option inconnue: $1" ;;
        esac
        shift
    done

    [[ -n "$action" ]] || { usage; return 2; }
    [[ "$action" != prepare || -z "$session_id" ]] || die "--prepare crée une nouvelle session; ne passez pas --session."
    if [[ "$action" == show || "$action" == confirm || "$action" == base || "$action" == apply_base || "$action" == report || "$action" == manual || "$action" == audit || "$action" == protections || "$action" == users || "$action" == storage || "$action" == network || "$action" == network_apply || "$action" == iso || "$action" == ssh_initial || "$action" == ssh_harden || "$action" == ssh_port || "$action" == mfa ]]; then
        [[ -n "$session_id" ]] || die "--session est requis pour cette action."
    fi

    require_root
    validate_supported_platform
    ensure_jq
    validate_state_dir "$state_dir"
    STATE_DIR=$state_dir
    export STATE_DIR

    if [[ -n "$session_id" ]]; then
        [[ "$session_id" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]] || die "Identifiant de session invalide."
        STATE_FILE="$STATE_DIR/$session_id.json"
        export STATE_FILE
        [[ -f "$STATE_FILE" && ! -L "$STATE_FILE" ]] || die "Session introuvable ou invalide: $session_id"
        jq -e --arg id "$session_id" '.session_id == $id' "$STATE_FILE" >/dev/null || die "Le fichier d'état ne correspond pas à la session demandée."
        log "Reprise explicite de la session $session_id"
    else
        session_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
        STATE_FILE="$STATE_DIR/$session_id.json"
        export STATE_FILE
        state_init "$session_id"
        log "Nouvelle session: $session_id"
    fi

    if [[ "$action" == show || "$action" == confirm ]]; then
        [[ -n "$session_id" ]] || die "--session est requis avec --show-preparation et --confirm-preparation."
        jq -e '.preparation != null' "$STATE_FILE" >/dev/null || die "Aucune préparation n'est enregistrée dans cette session."
        if [[ "$action" == show ]]; then
            state_show_preparation
            return 0
        fi
        [[ "$(jq -r '.steps.preparation.confirmed // false' "$STATE_FILE")" == false ]] || die "La préparation est déjà confirmée."
        local confirmation
        read -r -p "Tapez CONFIRMER après revue des informations : " confirmation || die "Lecture interrompue."
        [[ "$confirmation" == CONFIRMER ]] || die "Confirmation annulée; aucune modification effectuée."
        state_confirm_preparation
        log "Préparation confirmée et enregistrée. Aucune modification système n'a été effectuée."
        return 0
    fi

    if [[ "$action" == base ]]; then
        state_require_confirmed preparation
        [[ "$(jq -r '.steps.base_installation.status // "not_started"' "$STATE_FILE")" == not_started || "$(jq -r '.steps.base_installation.status // "not_started"' "$STATE_FILE")" == prepared ]] \
            || die "L'installation initiale a déjà commencé; son plan ne peut pas être réinitialisé."
        preflight
        base_prepare
        return 0
    fi

    if [[ "$action" == apply_base ]]; then
        require_command apt-get
        require_command dpkg
        require_command cp
        base_apply "$session_id"
        return 0
    fi

    if [[ "$action" == manual ]]; then
        state_require_confirmed preparation
        record_manual_step "$manual_step"
        return 0
    fi

    if [[ "$action" == audit ]]; then
        state_require_confirmed preparation
        audit_final
        return 0
    fi

    if [[ "$action" == protections ]]; then
        protection_configure "$session_id"
        return 0
    fi

    if [[ "$action" == users ]]; then
        users_apply "$session_id"
        return 0
    fi

    if [[ "$action" == storage ]]; then
        storage_inspect "$session_id"
        return 0
    fi

    if [[ "$action" == network ]]; then
        network_inspect "$session_id"
        return 0
    fi
    if [[ "$action" == network_apply ]]; then
        network_configure "$session_id"
        return 0
    fi

    if [[ "$action" == iso ]]; then
        verify_installation_iso "$session_id"
        return 0
    fi

    if [[ "$action" == ssh_initial ]]; then
        ssh_initial_configure "$session_id"
        return 0
    fi
    if [[ "$action" == ssh_harden ]]; then
        ssh_harden "$session_id"
        return 0
    fi
    if [[ "$action" == ssh_port ]]; then
        ssh_change_port "$session_id"
        return 0
    fi
    if [[ "$action" == mfa ]]; then
        mfa_configure "$session_id"
        return 0
    fi

    if [[ "$action" == report ]]; then
        generate_session_report "$session_id"
        return 0
    fi

    preflight
    if [[ "$action" == check ]]; then
        state_set_status "preflight" "succeeded"
        log "Contrôles préalables terminés; aucune modification système effectuée."
        return 0
    fi

    if [[ "$action" == prepare ]]; then
        local client hostname ip role criticality admins detected_ip choice admin_index other_index
        local -a admin_list
        while :; do
            prompt_value client "Nom du client : "
            [[ "$client" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && break
            warn "Nom client invalide : utilisez 1 à 32 minuscules, chiffres ou tirets, en commençant par une lettre ou un chiffre."
        done
        while :; do
            prompt_value hostname "Nom du serveur (srv-${client}-roleXX) : "
            [[ "$hostname" =~ ^srv-${client}-[a-z0-9-]+[0-9]{2}$ ]] && break
            warn "Nom de serveur invalide : il doit respecter le format srv-${client}-roleXX et se terminer par deux chiffres."
        done
        detected_ip=$(detect_primary_ipv4) || detected_ip=
        if [[ -n "$detected_ip" ]]; then
            log "Adresse IPv4 principale détectée : $detected_ip"
            while :; do
                read -r -p "Utiliser cette adresse ? [O/n] " choice || die "Lecture interrompue."
                choice=${choice,,}
                case "$choice" in
                    ""|o|oui|y|yes) ip=$detected_ip; break ;;
                    n|non|no) ip=; break ;;
                    *) warn "Répondez par O (oui) ou n (non)." ;;
                esac
            done
        else
            warn "Aucune adresse IPv4 principale n'a pu être détectée; saisissez-la manuellement."
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
            prompt_value role "Rôle du serveur : "
            [[ "$role" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] && break
            warn "Rôle invalide : utilisez 1 à 32 minuscules, chiffres ou tirets, en commençant par une lettre ou un chiffre."
        done
        while :; do
            prompt_value criticality "Criticité (faible/moyenne/haute/critique) : "
            [[ "$criticality" =~ ^(faible|moyenne|haute|critique)$ ]] && break
            warn "Niveau de criticité invalide : choisissez faible, moyenne, haute ou critique."
        done
        while :; do
            prompt_value admins "Comptes administrateurs autorisés (séparés par des virgules) : "
            if [[ ${#admins} -gt 512 || ! "$admins" =~ ^[a-z_][a-z0-9_-]*[a-z0-9_](,[a-z_][a-z0-9_-]*[a-z0-9_])*$ ]]; then
                warn "Liste invalide : saisissez des identifiants Linux séparés par des virgules, sans tiret final."
                continue
            fi
            if [[ ",$admins," =~ ,(admin|administrator|support|tech|user|test|cotcod)(,|,) ]]; then
                warn "La liste contient un compte interdit par le protocole (admin, administrator, support, tech, user, test ou cotcod)."
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
        while [[ ! "$hostname" =~ ^srv-${client}-${role}[0-9]{2}$ ]]; do
            warn "Le hostname doit refléter le rôle choisi et respecter srv-${client}-${role}XX."
            while :; do
                prompt_value hostname "Nom du serveur (srv-${client}-${role}XX) : "
                [[ "$hostname" =~ ^srv-${client}-[a-z0-9-]+[0-9]{2}$ ]] && break
                warn "Nom de serveur invalide : utilisez minuscules, chiffres et tirets, avec deux chiffres finaux."
            done
        done
        state_put_preparation "$client" "$hostname" "$ip" "$role" "$criticality" "$admins"
        log "Préparation enregistrée pour $hostname. Aucun changement système n'a été effectué."
        log "Consultez-la avec --show-preparation --session $session_id, puis validez sa revue avec --confirm-preparation."
        return 0
    fi
}

main "$@"
