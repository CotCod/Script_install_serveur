#!/usr/bin/env bash

STATE_DIR=${STATE_DIR:-}
STATE_FILE=${STATE_FILE:-}

state_init() {
    local id=$1
    jq -n --arg id "$id" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{schema_version:1, protocol_version:"1.0", session_id:$id,
          started_at:$now, updated_at:$now, status:"in_progress",
          host:{}, steps:{preparation:{status:"in_progress",confirmed:false},
            os_support:{status:"not_started"},
            iso_verification:{status:"not_started"},
            base_installation:{status:"not_started"}, storage:{status:"not_started"},
            network:{status:"not_started"}, users:{status:"not_started"},
            ssh:{status:"not_started"}, mfa:{status:"not_started"},
            firewall:{status:"not_started"}, fail2ban:{status:"not_started"},
            sysctl:{status:"not_started"}, apparmor:{status:"not_started"},
            final_audit:{status:"not_started"}}, report:{}, non_conformities:[]}' > "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

state_update() {
    local filter=$1
    shift
    local tmp
    tmp=$(mktemp "$STATE_DIR/.session.XXXXXX")
    jq "$@" --arg now "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$filter | .updated_at = \$now" "$STATE_FILE" > "$tmp" \
        || { rm -f -- "$tmp"; die "Impossible de mettre à jour l'état JSON."; }
    mv -f -- "$tmp" "$STATE_FILE"
    chmod 600 "$STATE_FILE"
}

state_put_host() {
    local distro=$1 version=$2 arch=$3 pretty=$4
    state_update '.host = {distribution:$distro, version:$version, architecture:$arch, pretty_name:$pretty}' \
        --arg distro "$distro" --arg version "$version" --arg arch "$arch" --arg pretty "$pretty"
}

state_set_status() {
    local step=$1 status=$2
    state_update '.steps[$step] = ((.steps[$step] // {}) + {status:$status})' \
        --arg step "$step" --arg status "$status"
}

state_put_preparation() {
    local client=$1 hostname=$2 ip=$3 role=$4 criticality=$5 admins_csv=$6
    state_update '.preparation = {client:$client, hostname:$hostname, ip_address:$ip, role:$role, criticality:$criticality, authorized_admins:($admins|split(",")), collected_at:$now} | .steps.preparation = {status:"prepared", confirmed:false, system_changes:[]}' \
        --arg client "$client" --arg hostname "$hostname" --arg ip "$ip" \
        --arg role "$role" --arg criticality "$criticality" --arg admins "$admins_csv"
}

state_put_base_plan() {
    local hostname=$1 os=$2 kernel=$3 upgradable=$4 missing_packages=$5 reboot_required=$6 packages=$7
    state_update '.steps.base_installation = {status:"prepared", confirmed:false, inventory:{hostname:$hostname, operating_system:$os, kernel:$kernel, upgradable_packages:$upgradable, reboot_required:($reboot_required == "true")}, plan:{system_update:"apt-get update puis apt-get full-upgrade", install_packages:($packages|split(" ")), missing_packages:(if $missing == "" then [] else ($missing|split(",")) end), system_changes:[]}}' \
        --arg hostname "$hostname" --arg os "$os" --arg kernel "$kernel" \
        --arg upgradable "$upgradable" --arg packages "$packages" \
        --arg missing "$missing_packages" --arg reboot_required "$reboot_required"
}

state_show_preparation() {
    jq '{session_id, host, preparation, steps}' "$STATE_FILE"
}

state_confirm_preparation() {
    state_update '.steps.preparation.confirmed = true | .steps.preparation.confirmed_at = $now'
}

state_require_confirmed() {
    local step=$1
    jq -e --arg step "$step" '.steps[$step].confirmed == true' "$STATE_FILE" >/dev/null \
        || die "L'étape '$step' doit être confirmée par le technicien avant toute action."
}

state_record_manual_step() {
    local step=$1 evidence=$2
    state_update '.steps[$step] = ((.steps[$step] // {}) + {status:"succeeded", completion_type:"technician_attestation", evidence:$evidence, completed_at:$now})' \
        --arg step "$step" --arg evidence "$evidence"
}
