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
source "$SCRIPT_DIR/lib/workflow.sh"

usage() {
    cat <<'EOF'
Usage: cotcod-installer.sh [options]

Sans option, lance l’assistant complet. Relancez la même commande après un
redémarrage demandé; l’assistant reprend automatiquement la session en cours.

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
  --new-session         Démarrer une nouvelle session au lieu de reprendre
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
    local action=wizard state_dir=/var/lib/cotcod-installer session_id= manual_step= new_session=false

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
            --configure-ssh) action=ssh_initial ;;
            --harden-ssh) action=ssh_harden ;;
            --change-ssh-port) action=ssh_port ;;
            --configure-mfa) action=mfa ;;
            --generate-report) action=report ;;
            --state-dir) [[ $# -ge 2 ]] || die "--state-dir attend un chemin"; state_dir=$2; shift ;;
            --session) [[ $# -ge 2 ]] || die "--session attend un identifiant"; session_id=$2; shift ;;
            --new-session) new_session=true ;;
            --help|-h) usage; return 0 ;;
            *) die "Option inconnue: $1" ;;
        esac
        shift
    done

    [[ -n "$action" ]] || { usage; return 2; }
    [[ "$action" != prepare || -z "$session_id" ]] || die "--prepare crée une nouvelle session; ne passez pas --session."
    if [[ "$action" == show || "$action" == confirm || "$action" == base || "$action" == apply_base || "$action" == report || "$action" == manual || "$action" == audit || "$action" == protections || "$action" == users || "$action" == storage || "$action" == network || "$action" == network_apply || "$action" == ssh_initial || "$action" == ssh_harden || "$action" == ssh_port || "$action" == mfa ]]; then
        [[ -n "$session_id" ]] || die "--session est requis pour cette action."
    fi

    set_system_path
    require_root
    validate_supported_platform
    ensure_required_commands
    validate_state_dir "$state_dir"
    STATE_DIR=$state_dir
    export STATE_DIR

    if [[ -z "$session_id" && "$action" == wizard && "$new_session" != true ]]; then
        local candidate candidate_status latest_candidate=
        for candidate in "$STATE_DIR"/*.json; do
            [[ -f "$candidate" && ! -L "$candidate" ]] || continue
            candidate_status=$(jq -r '.status // "in_progress"' "$candidate" 2>/dev/null || printf complete)
            if [[ "$candidate_status" != complete ]]; then latest_candidate=$candidate; fi
        done
        if [[ -n "$latest_candidate" ]]; then
            session_id=${latest_candidate##*/}
            session_id=${session_id%.json}
            log "Session inachevée reprise automatiquement : $session_id"
        fi
    fi

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
        confirm_yes_no "Confirmer la préparation après revue des informations ?" \
            || die "Confirmation annulée; aucune modification effectuée."
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

    if [[ "$action" == wizard ]]; then
        run_installation_workflow "$session_id"
        return 0
    fi

    preflight
    if [[ "$action" == check ]]; then
        state_set_status "preflight" "succeeded"
        log "Contrôles préalables terminés; aucune modification système effectuée."
        return 0
    fi

    if [[ "$action" == prepare ]]; then collect_preparation "$session_id"; return 0; fi
}

main "$@"
