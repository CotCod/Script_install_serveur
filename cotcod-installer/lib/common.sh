#!/usr/bin/env bash

log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
warn() { printf '[%s] AVERTISSEMENT: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; }
die() { printf '[%s] ERREUR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2; exit 1; }

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Ce programme doit être exécuté avec les privilèges root."
}

validate_state_dir() {
    local dir=$1
    [[ -n "$dir" && "$dir" != / && "$dir" != *$'\n'* ]] || die "Répertoire d'état invalide."
    [[ ! -L "$dir" ]] || die "Le répertoire d'état ne peut pas être un lien symbolique."
    mkdir -p -- "$dir"
    [[ -d "$dir" && ! -L "$dir" ]] || die "Le répertoire d'état doit être un vrai répertoire, pas un lien symbolique."
    chmod 700 -- "$dir"
}

command_exists() { command -v "$1" >/dev/null 2>&1; }
require_command() { command_exists "$1" || die "Commande requise absente: $1"; }

ensure_jq() {
    command_exists jq && return 0

    command_exists apt-get || die "jq est absent et apt-get n'est pas disponible pour l'installer."
    [[ -r /dev/tty && -w /dev/tty ]] || die "jq est absent. Relancez depuis un terminal interactif pour confirmer son installation."

    printf 'jq est requis pour gérer l’état JSON. Le script peut actualiser les index APT puis installer jq.\nTapez CONFIRMER pour continuer : ' > /dev/tty
    local confirmation
    IFS= read -r confirmation < /dev/tty || die "Confirmation non reçue; jq n'a pas été installé."
    [[ "$confirmation" == CONFIRMER ]] || die "Installation de jq annulée; aucune installation n'a été lancée."

    log "Actualisation des index APT (confirmation reçue)."
    apt-get update || die "Échec de l'actualisation APT; jq n'a pas été installé."
    log "Installation de jq (confirmation reçue)."
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends jq \
        || die "Échec de l'installation de jq."
    command_exists jq || die "L'installation s'est terminée, mais jq reste introuvable dans PATH."
}

preflight() {
    local distro version arch
    require_command awk
    require_command date
    require_command find
    require_command id

    [[ -r /etc/os-release ]] || die "/etc/os-release est inaccessible."
    source /etc/os-release
    distro=${ID:-unknown}
    version=${VERSION_ID:-unknown}
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)

    case "$distro" in
        debian|ubuntu) ;;
        *) die "Distribution non supportée: $distro" ;;
    esac
    case "$arch" in
        amd64|arm64|x86_64|aarch64) ;;
        *) die "Architecture non supportée: $arch" ;;
    esac

    command_exists apt || die "Commande requise absente: apt"
    command_exists systemctl || die "Commande requise absente: systemctl"

    state_put_host "$distro" "$version" "$arch" "${PRETTY_NAME:-$distro}"
    log "Système détecté: ${PRETTY_NAME:-$distro} ($arch)"
    log "Préflight non invasif réussi."
}

validate_supported_platform() {
    local distro arch
    [[ -r /etc/os-release ]] || die "/etc/os-release est inaccessible."
    source /etc/os-release
    distro=${ID:-unknown}
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "$distro" in
        debian|ubuntu) ;;
        *) die "Distribution non supportée: $distro" ;;
    esac
    case "$arch" in
        amd64|arm64|x86_64|aarch64) ;;
        *) die "Architecture non supportée: $arch" ;;
    esac
    command_exists apt || die "Commande requise absente: apt"
    command_exists systemctl || die "Commande requise absente: systemctl"
}

valid_ipv4() {
    local address=$1 part
    local -a octets
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$address"
    for part in "${octets[@]}"; do
        [[ ${#part} -eq 1 || ${part:0:1} != 0 ]] || return 1
        ((10#$part <= 255)) || return 1
    done
}

detect_primary_ipv4() {
    command_exists ip || return 1
    local address
    address=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}') || true
    if valid_ipv4 "${address:-}"; then
        printf '%s\n' "$address"
        return 0
    fi
    return 1
}

prompt_value() {
    local __target=$1 prompt=$2 value
    while :; do
        read -r -p "$prompt" value || die "Lecture interrompue."
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        [[ -n "$value" ]] && { printf -v "$__target" '%s' "$value"; return; }
        warn "Cette information est obligatoire."
    done
}

prompt_text() {
    local __target=$1 prompt=$2 value
    while :; do
        read -r -p "$prompt" value || die "Lecture interrompue."
        value=${value#"${value%%[![:space:]]*}"}
        value=${value%"${value##*[![:space:]]}"}
        [[ -n "$value" ]] && { printf -v "$__target" '%s' "$value"; return; }
        warn "Cette information est obligatoire."
    done
}
