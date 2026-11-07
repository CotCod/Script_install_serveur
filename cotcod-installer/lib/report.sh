#!/usr/bin/env bash

generate_session_report() {
    local session_id=$1 final_status report_path technician company contact reference
    local start_date end_date date_input infrastructure provider receiver receiver_role observations
    final_status=$(jq -r '.steps.final_audit.status // "not_started"' "$STATE_FILE")
    if [[ "$final_status" == succeeded ]] && jq -e '.report.general == null' "$STATE_FILE" >/dev/null; then
        prompt_text technician "Nom du technicien : "
        prompt_text company "Société cliente : "
        prompt_text contact "Contact technique : "
        prompt_text reference "Référence d'intervention : "
        prompt_text infrastructure "Type d'infrastructure (VPS/dédié/VM/cloud) : "
        prompt_text provider "Hébergeur : "
        start_date=$(TZ=Europe/Paris date -d "$(jq -r '.started_at' "$STATE_FILE")" +%F)
        while :; do
            read -r -p "Date de début [$start_date] : " date_input || die "Lecture interrompue."
            start_date=${date_input:-$start_date}
            start_date=$(date -d "$start_date" +%F 2>/dev/null) && break
            warn "Date invalide; utilisez AAAA-MM-JJ."
        done
        end_date=$(TZ=Europe/Paris date +%F)
        while :; do
            read -r -p "Date de fin [$end_date] : " date_input || die "Lecture interrompue."
            end_date=${date_input:-$end_date}
            end_date=$(date -d "$end_date" +%F 2>/dev/null) && break
            warn "Date invalide; utilisez AAAA-MM-JJ."
        done
        prompt_text receiver "Nom du représentant client (ou Non renseigné) : "
        prompt_text receiver_role "Fonction du représentant client (ou Non renseigné) : "
        read -r -p "Observations (laisser vide si aucune) : " observations || die "Lecture interrompue."
        state_update '.report.general = {company:$company, technical_contact:$contact, intervention_reference:$reference, technician:$technician, start_date:$start, end_date:$end, infrastructure:$infrastructure, provider:$provider} | .report.technician = $technician | .report.validated_at = $end | .report.validation = {client_representative:$receiver, representative_role:$role} | .report.observations = $observations' \
            --arg company "$company" --arg contact "$contact" --arg reference "$reference" \
            --arg technician "$technician" --arg start "$start_date" --arg end "$end_date" \
            --arg infrastructure "$infrastructure" --arg provider "$provider" \
            --arg receiver "$receiver" --arg role "$receiver_role" --arg observations "$observations"
    fi

    require_command python3
    report_path="$STATE_DIR/$session_id.pdf"
    local temporary_pdf="$report_path.tmp"
    if ! python3 "$SCRIPT_DIR/lib/report.py" "$STATE_FILE" "$temporary_pdf"; then
        die "La génération du rapport PDF a échoué; la session n'est pas clôturée."
    fi
    mv -f -- "$temporary_pdf" "$report_path" || die "Impossible de placer le rapport PDF final."
    state_update '.report.pdf_path = $path | .report.pdf_generated_at = $now | .status = (if .steps.final_audit.status == "succeeded" then "complete" else .status end)' --arg path "$report_path"
    log "Rapport PDF généré : $report_path"
}
