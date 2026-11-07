#!/usr/bin/env bash

set_login_parameter() {
    local key=$1 value=$2 tmp
    tmp=$(mktemp /etc/.login.defs.cotcod.XXXXXX)
    awk -v key="$key" -v value="$value" '
        $1 == key { if (!done) print key "\t" value; done=1; next }
        { print }
        END { if (!done) print key "\t" value }
    ' /etc/login.defs > "$tmp"
    chmod --reference=/etc/login.defs "$tmp"
    chown --reference=/etc/login.defs "$tmp"
    mv -f -- "$tmp" /etc/login.defs
}

users_apply() {
    local session_id=$1 confirmation user pwquality_line pam_tmp group_list created_at
    local first_name last_name first_norm last_norm base expected_id collision_count idx j
    local corrected_id admin_json name_json
    local -a admins display_names bases first_norms last_norms

    state_require_confirmed preparation
    [[ "$(jq -r '.steps.base_installation.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Terminez d'abord l'installation initiale (chapitre 4)."
    [[ "$(jq -r '.steps.network.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Validez d'abord la configuration réseau (chapitre 6)."
    [[ "$(jq -r '.steps.users.status // "not_started"' "$STATE_FILE")" == not_started ]] \
        || die "L'étape comptes a déjà commencé; inspectez l'état et restaurez les sauvegardes avant toute reprise."
    mapfile -t admins < <(jq -r '.preparation.authorized_admins[]' "$STATE_FILE")
    ((${#admins[@]} > 0)) || die "Aucun administrateur autorisé n'est enregistré."
    require_command iconv
    for user in "${admins[@]}"; do
        [[ "$user" =~ ^[a-z_][a-z0-9_-]*[a-z0-9_]$ ]] || die "Identifiant administrateur invalide : $user"
        case "$user" in admin|administrator|support|tech|user|test|cotcod)
            die "Compte interdit par le protocole : $user"
            ;;
        esac
    done
    for ((idx=0; idx<${#admins[@]}; idx++)); do
        for ((j=idx+1; j<${#admins[@]}; j++)); do
            [[ "${admins[$idx]}" != "${admins[$j]}" ]] || die "Le compte ${admins[$idx]} est répété dans la liste des administrateurs."
        done
    done

    for idx in "${!admins[@]}"; do
        user=${admins[$idx]}
        while :; do
            prompt_value first_name "Prénom de $user : "
            [[ "$first_name" =~ ^[[:alpha:]][[:alpha:]-]*$ ]] || { warn "Saisissez un prénom en lettres, éventuellement avec tiret."; continue; }
            prompt_value last_name "Nom de famille de $user : "
            [[ "$last_name" =~ ^[[:alpha:]][[:alpha:]-]*$ ]] || { warn "Saisissez un nom en lettres, éventuellement avec tiret."; continue; }
            first_norm=$(printf '%s' "$first_name" | iconv -f UTF-8 -t ASCII//TRANSLIT | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z')
            last_norm=$(printf '%s' "$last_name" | iconv -f UTF-8 -t ASCII//TRANSLIT | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z')
            if [[ -z "$first_norm" || -z "$last_norm" ]]; then
                warn "Le prénom et le nom doivent produire des lettres latines pour appliquer la convention de compte CotCod."
                continue
            fi
            base="${first_norm:0:1}${last_norm:0:8}"
            display_names[$idx]="$first_name $last_name"
            bases[$idx]=$base
            first_norms[$idx]=$first_norm
            last_norms[$idx]=$last_norm
            break
        done
    done

    for idx in "${!admins[@]}"; do
        user=${admins[$idx]}
        collision_count=0
        for j in "${!bases[@]}"; do [[ "${bases[$j]}" != "${bases[$idx]}" ]] || collision_count=$((collision_count + 1)); done
        if ((collision_count == 1)) || [[ "$user" == "${bases[$idx]}" ]]; then
            expected_id=${bases[$idx]}
        else
            expected_id="${first_norms[$idx]:0:2}${last_norms[$idx]:0:8}"
        fi
        while [[ "$user" != "$expected_id" ]]; do
            warn "Convention de nommage : l'identifiant attendu pour ${display_names[$idx]} est $expected_id."
            prompt_value corrected_id "Identifiant Linux à utiliser : "
            [[ "$corrected_id" =~ ^[a-z_][a-z0-9_-]*[a-z0-9_]$ ]] || { warn "Identifiant invalide."; continue; }
            case "$corrected_id" in admin|administrator|support|tech|user|test|cotcod) warn "Compte interdit par le protocole."; continue ;; esac
            for j in "${!admins[@]}"; do [[ "$j" == "$idx" || "${admins[$j]}" != "$corrected_id" ]] || die "L'identifiant $corrected_id est déjà utilisé dans la liste."; done
            admins[$idx]=$corrected_id
            user=$corrected_id
        done
    done

    local existing_record existing_uid existing_home reuse_confirmation
    for user in "${admins[@]}"; do
        if getent passwd "$user" >/dev/null; then
            existing_record=$(getent passwd "$user")
            existing_uid=$(cut -d: -f3 <<< "$existing_record")
            existing_home=$(cut -d: -f6 <<< "$existing_record")
            ((existing_uid >= 1000)) || die "Le compte $user est un compte système (UID $existing_uid); il ne peut pas être un administrateur nominatif."
            [[ "$existing_home" == "/home/$user" ]] || die "Le répertoire de $user est '$existing_home', attendu '/home/$user'; régularisez-le manuellement."
            [[ -d "$existing_home" ]] || die "Le répertoire personnel de $user est absent; régularisez-le manuellement."
            read -r -p "Le compte $user existe déjà. Tapez REUTILISER-COMPTE après avoir vérifié son propriétaire : " reuse_confirmation \
                || die "Lecture interrompue."
            [[ "$reuse_confirmation" == REUTILISER-COMPTE ]] || die "Réutilisation du compte $user annulée."
        fi
    done

    printf 'Comptes administrateurs à contrôler/créer : %s\n' "${admins[*]}"
    printf 'Les mots de passe seront saisis directement par passwd et ne seront pas enregistrés.\n'
    read -r -p "Tapez APPLIQUER-COMPTES pour continuer : " confirmation || die "Lecture interrompue."
    [[ "$confirmation" == APPLIQUER-COMPTES ]] || die "Configuration des comptes annulée."
    admin_json=$(printf '%s\n' "${admins[@]}" | jq -R . | jq -s .)
    name_json=$(printf '%s\n' "${display_names[@]}" | jq -R . | jq -s .)
    state_update '.preparation.authorized_admins = $admins | .report.users = {identities:[$admins|to_entries[]|{username:.value,display_name:$names[.key]}]}' \
        --argjson admins "$admin_json" --argjson names "$name_json"

    local backup_dir="$STATE_DIR/backups/$session_id"
    mkdir -p -- "$backup_dir"
    chmod 700 -- "$STATE_DIR/backups" "$backup_dir"
    backup_file /etc/login.defs "$backup_dir"
    backup_file /etc/pam.d/common-password "$backup_dir"
    backup_file /etc/security/pwquality.conf "$backup_dir"
    backup_file /etc/passwd "$backup_dir"
    backup_file /etc/group "$backup_dir"
    backup_file /etc/shadow "$backup_dir"
    backup_file /etc/gshadow "$backup_dir"

    state_set_status users in_progress
    if apt-get install -y --no-install-recommends libpam-pwquality; then
        :
    else
        state_set_status users failed
        die "Échec de l'installation de libpam-pwquality."
    fi

    set_login_parameter PASS_MAX_DAYS 30
    set_login_parameter PASS_MIN_DAYS 1
    set_login_parameter PASS_WARN_AGE 7

    pwquality_line='password requisite pam_pwquality.so retry=3 minlen=8 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1 usercheck=1'
    pam_tmp=$(mktemp /etc/pam.d/.common-password.cotcod.XXXXXX)
    awk -v line="$pwquality_line" '
        /pam_pwquality\.so/ { next }
        /pam_unix\.so/ && !inserted { print line; inserted=1 }
        { print }
        END { if (!inserted) print line }
    ' /etc/pam.d/common-password > "$pam_tmp"
    chmod --reference=/etc/pam.d/common-password "$pam_tmp"
    chown --reference=/etc/pam.d/common-password "$pam_tmp"
    mv -f -- "$pam_tmp" /etc/pam.d/common-password

    for idx in "${!admins[@]}"; do
        user=${admins[$idx]}
        if ! getent passwd "$user" >/dev/null; then
            printf 'Création du compte %s : le technicien devra définir son mot de passe.\n' "$user"
            adduser --disabled-password --gecos "${display_names[$idx]}" "$user"
            passwd "$user"
            created_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        else
            created_at="déjà présent"
        fi
        usermod -c "${display_names[$idx]}" "$user"
        usermod -aG sudo "$user"
        chage -M 30 -m 1 -W 7 "$user"
        [[ -d "/home/$user" ]] && chmod 750 "/home/$user"
        group_list=$(id -nG "$user")
        [[ " $group_list " == *" sudo "* ]] || { state_set_status users failed; die "Le compte $user n'est pas membre du groupe sudo."; }
        state_update '.report.users.accounts[$user] = {display_name:$display, groups:$groups, home_permissions:$home, account_created:$created, password_policy:"pwquality minlen=8 upper/lower/digit/special; max age 30d; warning 7d"}' \
            --arg user "$user" --arg display "${display_names[$idx]}" --arg groups "$group_list" \
            --arg home "$(stat -c '%a' "/home/$user" 2>/dev/null || printf absent)" \
            --arg created "$created_at"
    done
    chage -M 30 -m 1 -W 7 root

    state_set_status users succeeded
    state_update '.report.users.password_policy = {PASS_MAX_DAYS:30, PASS_MIN_DAYS:1, PASS_WARN_AGE:7, pam_pwquality:"retry=3 minlen=8 ucredit=-1 lcredit=-1 dcredit=-1 ocredit=-1 usercheck=1"} | .report.users.configured_at = $now'
    log "Comptes administrateurs et politique de mots de passe configurés."
}
