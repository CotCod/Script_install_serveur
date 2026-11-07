#!/usr/bin/env bash

ssh_initial_configure() {
    local session_id=$1 confirmation ssh_config effective
    state_require_confirmed preparation
    [[ "$(jq -r '.steps.base_installation.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Terminez d'abord l'installation initiale."
    [[ "$(jq -r '.steps.users.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Configurez d'abord les comptes administrateurs."
    [[ "$(jq -r '.steps.ssh.status // "not_started"' "$STATE_FILE")" == not_started ]] \
        || die "La configuration SSH a déjà commencé; vérifiez l'état et les sauvegardes."

    printf 'Première étape SSH : root interdit, mais le mot de passe reste temporairement actif pour déployer et tester les clés.\n'
    read -r -p "Tapez CONFIGURER-SSH pour continuer : " confirmation || die "Lecture interrompue."
    [[ "$confirmation" == CONFIGURER-SSH ]] || die "Configuration SSH annulée."

    local backup_dir="$STATE_DIR/backups/$session_id"
    mkdir -p -- "$backup_dir"
    chmod 700 -- "$STATE_DIR/backups" "$backup_dir"
    backup_file /etc/ssh "$backup_dir"
    if ! apt-get install -y --no-install-recommends openssh-server; then
        state_set_status ssh failed
        die "Échec de l'installation d'OpenSSH."
    fi

    ssh_config=$(cat <<'EOF'
# Configuration CotCod - Setup Essentiel
Port 22
PermitRootLogin no
PubkeyAuthentication yes
PasswordAuthentication yes
KbdInteractiveAuthentication yes
UsePAM yes
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2
StrictModes yes
EOF
)
    write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$ssh_config"
    if ! sshd -t; then
        state_set_status ssh failed
        die "sshd -t a rejeté la configuration; restaurez la sauvegarde avant de poursuivre."
    fi
    effective=$(sshd -T 2>/dev/null)
    [[ "$effective" == *$'permitrootlogin no'* && "$effective" == *$'pubkeyauthentication yes'* && "$effective" == *$'passwordauthentication yes'* ]] \
        && [[ "$(awk '$1 == "port" {print $2; exit}' <<< "$effective")" == 22 ]] \
        || { state_set_status ssh failed; die "La configuration effective ne respecte pas les paramètres SSH CotCod."; }
    systemctl enable --now ssh || { state_set_status ssh failed; die "Impossible d'activer le service SSH."; }
    systemctl is-active --quiet ssh || { state_set_status ssh failed; die "Le service SSH n'est pas actif après rechargement."; }

    state_update '.steps.ssh = {status:"in_progress", initial_configuration:"succeeded", key_test:"pending", port_test:"pending", mfa_test:"pending", config_file:"/etc/ssh/sshd_config.d/99-cotcod.conf"} | .report.ssh = {version:$version, config_file:"/etc/ssh/sshd_config.d/99-cotcod.conf", root_login:"no", pubkey_authentication:"yes", password_authentication:"yes (temporary)", configured_at:$now}' \
        --arg version "$(sshd -V 2>&1 | head -n1)"
    log "Configuration SSH initiale appliquée. Gardez cette session ouverte."
    log "Déployez une clé ED25519 pour chaque administrateur, ouvrez une nouvelle session, puis consignez le test avec --record-manual ssh_key_test."
}

ssh_harden() {
    local session_id=$1 confirmation old_config new_config effective
    state_require_confirmed preparation
    [[ "$(jq -r '.steps.ssh.initial_configuration // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Appliquez d'abord la configuration SSH initiale."
    [[ "$(jq -r '.steps.ssh_key_test.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Validez une connexion ED25519 dans une nouvelle session avant de désactiver le mot de passe."
    [[ "$(jq -r '.steps.ssh.hardening // "not_started"' "$STATE_FILE")" == not_started ]] \
        || die "Le durcissement SSH a déjà commencé."

    printf 'Cette étape désactive uniquement l’authentification SSH par mot de passe. Le port ne change pas encore.\n'
    printf 'La session actuelle doit rester ouverte; testez ensuite une nouvelle connexion par clé.\n'
    read -r -p "Tapez DESACTIVER-MOTDEPASSE-SSH pour continuer : " confirmation || die "Lecture interrompue."
    [[ "$confirmation" == DESACTIVER-MOTDEPASSE-SSH ]] || die "Durcissement SSH annulé."

    local backup_dir="$STATE_DIR/backups/$session_id"
    mkdir -p -- "$backup_dir"
    chmod 700 -- "$STATE_DIR/backups" "$backup_dir"
    backup_file /etc/ssh/sshd_config.d/99-cotcod.conf "$backup_dir"
    old_config=$(cat /etc/ssh/sshd_config.d/99-cotcod.conf)
    new_config=$(awk '
        $1 == "PasswordAuthentication" { if (!pw) print "PasswordAuthentication no"; pw=1; next }
        { print }
        END { if (!pw) print "PasswordAuthentication no" }
    ' <<< "$old_config")
    write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$new_config"
    if ! sshd -t; then
        write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$old_config"
        state_set_status ssh failed
        die "sshd -t a rejeté le durcissement; la configuration précédente a été restaurée."
    fi
    effective=$(sshd -T 2>/dev/null)
    [[ "$effective" == *$'passwordauthentication no'* && "$effective" == *$'permitrootlogin no'* && "$effective" == *$'pubkeyauthentication yes'* ]] \
        || { write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$old_config"; state_set_status ssh failed; die "Les valeurs effectives de sshd ne correspondent pas au plan; la configuration précédente a été restaurée."; }
    systemctl reload ssh || { write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$old_config"; systemctl reload ssh || true; state_set_status ssh failed; die "Le rechargement SSH a échoué; la configuration précédente a été restaurée."; }
    state_update '.steps.ssh.hardening = "succeeded" | .steps.ssh.status = "in_progress" | .report.ssh.password_authentication = "no" | .report.ssh.root_login = "no" | .report.ssh.public_key_authentication = "yes" | .report.ssh.configured_at = $now'
    log "Authentification par mot de passe désactivée. Gardez la session actuelle ouverte."
    log "Testez une nouvelle connexion par clé sur le port 22 puis utilisez --record-manual ssh_password_test --session $session_id."
}

ssh_change_port() {
    local session_id=$1 confirmation port old_config new_config effective backup_dir effective_port_count attempts
    state_require_confirmed preparation
    [[ "$(jq -r '.steps.ssh.hardening // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Désactivez d'abord l'authentification par mot de passe."
    [[ "$(jq -r '.steps.ssh_password_test.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Validez d'abord une nouvelle connexion par clé sur le port actuel."
    [[ "$(jq -r '.steps.ssh.port_change // "not_started"' "$STATE_FILE")" == not_started ]] \
        || die "Le changement de port SSH a déjà commencé."
    require_command shuf
    require_command ss
    attempts=0
    while ((attempts < 50)); do
        port=$(shuf -i 49152-65535 -n 1) || die "Impossible de choisir un port SSH aléatoire."
        if ! ss -H -ltn | awk -v port="$port" '$4 ~ (":" port "$") {used=1} END {exit used}'; then
            attempts=$((attempts + 1))
            continue
        fi
        break
    done
    ((attempts < 50)) || die "Aucun port libre n'a été trouvé dans la plage CotCod."
    printf 'Le port SSH va passer de 22 à %s/tcp. Gardez cette session ouverte et vérifiez l’accès console.\n' "$port"
    read -r -p "Tapez CHANGER-PORT-SSH pour continuer : " confirmation || die "Lecture interrompue."
    [[ "$confirmation" == CHANGER-PORT-SSH ]] || die "Changement de port annulé."
    backup_dir="$STATE_DIR/backups/$session_id"
    mkdir -p -- "$backup_dir"
    chmod 700 -- "$STATE_DIR/backups" "$backup_dir"
    backup_file /etc/ssh/sshd_config.d/99-cotcod.conf "$backup_dir"
    old_config=$(cat /etc/ssh/sshd_config.d/99-cotcod.conf)
    new_config=$(awk -v port="$port" '
        $1 == "Port" { if (!seen++) print "Port " port; next }
        { print }
        END { if (!seen) print "Port " port }
    ' <<< "$old_config")
    write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$new_config"
    if ! sshd -t; then
        state_set_status ssh failed
        die "sshd -t a rejeté le nouveau port; la sauvegarde est dans $backup_dir."
    fi
    effective=$(sshd -T 2>/dev/null) || die "Impossible de lire la configuration SSH effective."
    effective_port_count=$(awk '$1 == "port" {count++; if ($2 != expected) wrong=1} END {print count+0; exit wrong}' expected="$port" <<< "$effective") || effective_port_count=0
    [[ "$effective_port_count" == 1 ]] && grep -Fqx 'passwordauthentication no' <<< "$effective" \
        || { write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$old_config"; state_set_status ssh failed; die "La configuration SSH effective ne correspond pas uniquement au port prévu; configuration restaurée."; }
    systemctl reload ssh || { write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$old_config"; systemctl reload ssh || true; state_set_status ssh failed; die "Le rechargement de SSH a échoué; configuration précédente restaurée."; }
    if ! ss -H -ltn | awk -v port="$port" '$4 ~ (":" port "$") {found=1} END {exit !found}' \
        || ss -H -ltn | awk '$4 ~ /:22$/ {found=1} END {exit !found}'; then
        write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$old_config"
        systemctl reload ssh || true
        state_set_status ssh failed
        die "Le nouveau port n'est pas seul à l'écoute (activation par socket possible); configuration précédente restaurée."
    fi
    state_update '.steps.ssh.port_change = "succeeded" | .steps.ssh.port = $port | .steps.ssh.status = "in_progress" | .report.ssh.port = $port | .report.ssh.port_changed_at = $now' --arg port "$port"
    log "SSH écoute désormais sur le port $port. Gardez la session actuelle ouverte."
    log "Testez une nouvelle connexion par clé sur ce port puis consignez --record-manual ssh."
}

mfa_configure() {
    local session_id=$1 confirmation user auth_pam ssh_config existing_pam auth_effective mfa_state old_auth_pam old_ssh_config
    local -a admins
    state_require_confirmed preparation
    [[ "$(jq -r '.steps.ssh.status // ""' "$STATE_FILE")" == succeeded ]] \
        || die "Validez d'abord la nouvelle connexion SSH par clé sur le port personnalisé."
    mfa_state=$(jq -r '.steps.mfa.status // "not_started"' "$STATE_FILE")
    [[ "$mfa_state" == not_started || "$mfa_state" == in_progress ]] \
        || die "L'étape MFA est en état '$mfa_state'; vérifiez les comptes et sauvegardes avant reprise."
    mapfile -t admins < <(jq -r '.preparation.authorized_admins[]' "$STATE_FILE")
    for user in "${admins[@]}"; do
        [[ -f "/home/$user/.ssh/authorized_keys" ]] || die "La clé SSH de $user est absente; corrigez l'accès avant d'activer le MFA."
    done

    printf 'Le secret TOTP et les codes de récupération seront présentés à chaque utilisateur et ne seront pas enregistrés par CotCod.\n'
    read -r -p "Tapez CONFIGURER-MFA pour continuer : " confirmation || die "Lecture interrompue."
    [[ "$confirmation" == CONFIGURER-MFA ]] || die "Configuration MFA annulée."

    local backup_dir="$STATE_DIR/backups/$session_id"
    mkdir -p -- "$backup_dir"
    chmod 700 -- "$STATE_DIR/backups" "$backup_dir"
    backup_file /etc/pam.d/sshd "$backup_dir"
    backup_file /etc/ssh/sshd_config.d/99-cotcod.conf "$backup_dir"
    if ! apt-get install -y --no-install-recommends libpam-google-authenticator; then
        state_set_status mfa failed
        die "Échec de l'installation de libpam-google-authenticator."
    fi

    state_set_status mfa in_progress
    for user in "${admins[@]}"; do
        if [[ ! -f "/home/$user/.google_authenticator" ]]; then
            printf '\nEnrôlement TOTP de %s. L’utilisateur doit conserver lui-même ses codes de récupération.\n' "$user"
            runuser --login "$user" --command google-authenticator
        else
            printf 'TOTP déjà initialisé pour %s; vérification des permissions.\n' "$user"
        fi
        [[ -f "/home/$user/.google_authenticator" ]] || { state_set_status mfa failed; die "Fichier TOTP absent pour $user."; }
        chmod 600 "/home/$user/.google_authenticator"
        chown "$user:$user" "/home/$user/.google_authenticator"
    done

    auth_pam=$(cat /etc/pam.d/sshd)
    old_auth_pam=$auth_pam
    if [[ "$auth_pam" != *pam_google_authenticator.so* ]]; then
        auth_pam=$'auth required pam_google_authenticator.so\n'"$auth_pam"
        write_config_file /etc/pam.d/sshd "$auth_pam"
    fi
    ssh_config=$(cat /etc/ssh/sshd_config.d/99-cotcod.conf)
    old_ssh_config=$ssh_config
    existing_pam=$(awk '$1 == "AuthenticationMethods" {found=1} END {print found+0}' <<< "$ssh_config")
    if [[ "$existing_pam" == 1 ]]; then
        ssh_config=$(awk '$1 == "AuthenticationMethods" {$0="AuthenticationMethods publickey,keyboard-interactive"} {print}' <<< "$ssh_config")
    else
        ssh_config+=$'\nAuthenticationMethods publickey,keyboard-interactive'
    fi
    write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$ssh_config"
    if ! sshd -t; then
        write_config_file /etc/pam.d/sshd "$old_auth_pam"
        write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$old_ssh_config"
        state_set_status mfa failed
        die "sshd -t a rejeté l'activation MFA; les configurations SSH et PAM précédentes ont été restaurées."
    fi
    auth_effective=$(sshd -T 2>/dev/null)
    [[ "$auth_effective" == *$'authenticationmethods publickey,keyboard-interactive'* ]] \
        || { write_config_file /etc/pam.d/sshd "$old_auth_pam"; write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$old_ssh_config"; state_set_status mfa failed; die "sshd n'impose pas la clé et le MFA; les configurations précédentes ont été restaurées."; }
    systemctl reload ssh || { write_config_file /etc/pam.d/sshd "$old_auth_pam"; write_config_file /etc/ssh/sshd_config.d/99-cotcod.conf "$old_ssh_config"; systemctl reload ssh || true; state_set_status mfa failed; die "Rechargement SSH impossible; configurations précédentes restaurées."; }

    state_update '.steps.mfa = {status:"in_progress", configured:true, accounts:$accounts, pam_file:"/etc/pam.d/sshd", configured_at:$now} | .report.mfa = {solution:"libpam-google-authenticator (TOTP)", accounts:$accounts, recovery_codes:"remis aux utilisateurs; non conservés par CotCod", configured_at:$now}' \
        --argjson accounts "$(printf '%s\n' "${admins[@]}" | jq -R . | jq -s .)"
    log "MFA configuré. Ne fermez pas la session SSH actuelle."
    log "Testez depuis une nouvelle session : clé ED25519 puis code TOTP, puis consignez avec --record-manual mfa."
}
