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

dependency_package_for() {
    case "$1" in
        apt|apt-get) printf apt ;;
        jq) printf jq ;;
        awk) printf mawk ;;
        bash) printf bash ;;
        blkid|findmnt|lsblk|runuser) printf util-linux ;;
        chage|passwd|useradd|usermod|chpasswd) printf passwd ;;
        chmod|chown|cp|cut|date|df|dirname|head|install|mktemp|mv|nproc|numfmt|paste|shuf|stat|timeout|uname) printf coreutils ;;
        dpkg|dpkg-query) printf dpkg ;;
        fail2ban-client) printf fail2ban ;;
        find) printf findutils ;;
        free|sysctl) printf procps ;;
        getent|iconv|locale) printf libc-bin ;;
        google-authenticator) printf libpam-google-authenticator ;;
        grep) printf grep ;;
        hostname) printf hostname ;;
        hostnamectl|journalctl|localectl|systemctl|systemd-run|timedatectl) printf systemd ;;
        id) printf coreutils ;;
        ifdown|ifup) printf ifupdown ;;
        ip|ss) printf iproute2 ;;
        locale-gen|update-locale) printf locales ;;
        netplan) printf netplan.io ;;
        python3) printf python3 ;;
        resolvconf) printf resolvconf ;;
        sed) printf sed ;;
        ssh-keygen) printf openssh-client ;;
        sshd) printf openssh-server ;;
        sudo|visudo) printf sudo ;;
        tar) printf tar ;;
        ufw) printf ufw ;;
        aa-enforce|aa-status) printf apparmor-utils ;;
        *) return 1 ;;
    esac
}

install_dependency_packages() {
    local -a packages=("$@")
    local confirmation
    ((${#packages[@]})) || return 0

    [[ -r /dev/tty && -w /dev/tty ]] \
        || die "Des dépendances manquent (${packages[*]}). Relancez depuis un terminal interactif pour autoriser leur installation."
    printf 'Dépendances manquantes : %s\nElles seront installées maintenant avant le parcours CotCod.\nTapez INSTALLER-DEPENDANCES pour continuer : ' "${packages[*]}" > /dev/tty
    IFS= read -r confirmation < /dev/tty || die "Confirmation non reçue; aucune dépendance n'a été installée."
    [[ "$confirmation" == INSTALLER-DEPENDANCES ]] \
        || die "Installation des dépendances annulée; le parcours n'a pas commencé."

    log "Actualisation des index APT avant l'installation des dépendances."
    apt-get update || die "Échec d'apt-get update; les dépendances n'ont pas été installées."
    log "Installation groupée des dépendances : ${packages[*]}"
    apt-get install -y --no-install-recommends "${packages[@]}" \
        || die "Échec de l'installation groupée des dépendances."
}

ensure_required_commands() {
    local distro command package
    local -a required_commands missing_packages=()
    declare -A package_seen=()

    command_exists apt-get || die "apt-get est absent; impossible d'installer automatiquement les dépendances."
    command_exists dpkg || die "dpkg est absent; impossible de déterminer l'architecture Debian/Ubuntu."
    source /etc/os-release
    distro=${ID:-unknown}
    required_commands=(
        apt apt-get awk bash blkid chage chmod chown cp cut date df dirname dpkg dpkg-query
        fail2ban-client find findmnt free getent google-authenticator grep head hostname
        hostnamectl iconv id install ip jq journalctl locale locale-gen localectl lsblk mktemp
        mv nproc numfmt passwd paste python3 runuser sed shuf ss sshd ssh-keygen stat sudo
        sysctl systemctl systemd-run tar timedatectl timeout ufw uname update-locale useradd
        usermod chpasswd visudo aa-enforce aa-status
    )
    case "$distro" in
        debian) required_commands+=(ifdown ifup resolvconf) ;;
        ubuntu) required_commands+=(netplan) ;;
    esac

    for command in "${required_commands[@]}"; do
        command_exists "$command" && continue
        package=$(dependency_package_for "$command") \
            || die "Aucun paquet Debian/Ubuntu connu pour la commande requise absente : $command"
        [[ -n "${package_seen[$package]:-}" ]] && continue
        package_seen[$package]=1
        missing_packages+=("$package")
    done

    if ((${#missing_packages[@]})); then
        install_dependency_packages "${missing_packages[@]}"
    fi

    for command in "${required_commands[@]}"; do
        command_exists "$command" \
            || die "La commande requise '$command' reste absente après l'installation de ses dépendances."
    done
    log "Toutes les commandes requises sont disponibles avant le début du parcours."
}

require_command() {
    local command=$1 package
    command_exists "$command" && return 0
    package=$(dependency_package_for "$command") \
        || die "Commande requise absente et paquet non identifié : $command"
    warn "La commande '$command' manque malgré le contrôle initial; installation de '$package'."
    install_dependency_packages "$package"
    command_exists "$command" \
        || die "La commande requise '$command' reste absente après l'installation de '$package'."
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
    state_update '.steps.os_support = {status:"succeeded", completion_type:"automatic_detection", distribution:$distro, version:$version, architecture:$arch, detected_at:$now} | .steps.iso_verification = {status:"not_applicable", reason:"Le système est déjà installé; le média ISO est absent du serveur."}' \
        --arg distro "$distro" --arg version "$version" --arg arch "$arch"
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
    command_exists apt-get || die "Commande requise absente: apt-get (requise pour installer les dépendances)."
    command_exists dpkg || die "Commande requise absente: dpkg (requise pour déterminer l'architecture)."
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
