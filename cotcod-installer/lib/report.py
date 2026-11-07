#!/usr/bin/env python3
"""Create a dependency-free CotCod installation report PDF from session JSON."""

import json
import sys
import textwrap
from datetime import datetime, timezone
from pathlib import Path


def pdf_string(value):
    raw = str(value).encode("cp1252", errors="replace")
    out = bytearray(b"(")
    for byte in raw:
        if byte in (ord("("), ord(")"), ord("\\")):
            out.extend(b"\\" + bytes((byte,)))
        elif byte < 32 or byte >= 127:
            out.extend(("\\%03o" % byte).encode("ascii"))
        else:
            out.append(byte)
    out.extend(b")")
    return bytes(out)


def sections(state):
    preparation = state.get("preparation", {})
    host = state.get("host", {})
    steps = state.get("steps", {})
    report = state.get("report", {})
    return [
        ("1. INFORMATIONS GÉNÉRALES", {
            "Session": state.get("session_id", ""),
            "Client": preparation.get("client", "Non renseigné"),
            "Serveur": preparation.get("hostname", "Non renseigné"),
            "Adresse IPv4": preparation.get("ip_address", "Non renseignée"),
            "Rôle": preparation.get("role", "Non renseigné"),
            "Criticité": preparation.get("criticality", "Non renseignée"),
            "Administrateurs autorisés": ", ".join(preparation.get("authorized_admins", [])) or "Non renseignés",
            "Début de session": state.get("started_at", ""),
            "Généré le": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC"),
            **report.get("general", {}),
        }),
        ("2. INSTALLATION DU SYSTÈME", {
            "Distribution": host.get("pretty_name", "Non relevée"),
            "Version": host.get("version", ""),
            "Architecture": host.get("architecture", ""),
            "Noyau": report.get("kernel", "Non relevé"),
            "Hostname constaté": report.get("hostname", "Non relevé"),
            "Inventaire initial": steps.get("base_installation", {}),
            **report.get("system", {}),
        }),
        ("3. CONFIGURATION RÉSEAU", report.get("network", {"État": "À renseigner"})),
        ("4. CONFIGURATION DU STOCKAGE", report.get("storage", {"État": "À renseigner"})),
        ("5. COMPTES ADMINISTRATEURS", report.get("users", {"État": "À renseigner"})),
        ("6. CONFIGURATION SSH", report.get("ssh", {"État": "À renseigner"})),
        ("7. PARE-FEU", report.get("firewall", {"État": "À renseigner"})),
        ("8. AUTHENTIFICATION MULTIFACTEUR", report.get("mfa", {"État": "À renseigner"})),
        ("9. PROTECTION SSH (FAIL2BAN)", report.get("fail2ban", {"État": "À renseigner"})),
        ("10. DURCISSEMENT SYSTÈME", report.get("sysctl", {"État": "À renseigner"})),
        ("11. JOURNALISATION", report.get("logging", {"État": "À renseigner"})),
        ("12. APPARMOR", report.get("apparmor", {"État": "À renseigner"})),
        ("13. CONTRÔLE DE FIN D'INSTALLATION", {
            "Étapes": steps,
            **report.get("final_audit", {}),
        }),
        ("14. OBSERVATIONS", {
            "Non-conformités": state.get("non_conformities", []),
            "Observations": report.get("observations", "Aucune observation saisie."),
        }),
        ("15. VALIDATION", {
            "Statut du protocole": "complete" if steps.get("final_audit", {}).get("status") == "succeeded" else state.get("status", "in_progress"),
            "Technicien": report.get("technician", "À compléter"),
            "Date de validation": report.get("validated_at", "À compléter"),
            "Signature technicien": "________________________________________",
            "Nom du représentant client": report.get("validation", {}).get("client_representative", "À compléter"),
            "Fonction": report.get("validation", {}).get("representative_role", "À compléter"),
            "Signature réception": "________________________________________",
        }),
    ]


def flatten(value, prefix=""):
    if isinstance(value, dict):
        rows = []
        for key, item in value.items():
            label = f"{prefix}.{key}" if prefix else str(key)
            rows.extend(flatten(item, label))
        return rows or [f"{prefix}: {{}}"]
    if isinstance(value, list):
        if not value:
            return [f"{prefix}: aucun"]
        rows = []
        for index, item in enumerate(value, 1):
            rows.extend(flatten(item, f"{prefix}[{index}]"))
        return rows
    if isinstance(value, bool):
        value = "oui" if value else "non"
    return [f"{prefix}: {value}"]


def make_pdf(state, destination):
    required = ("os_support", "iso_verification", "base_installation", "services_review", "storage", "network", "users", "ssh_key_test", "ssh_password_test", "ssh", "mfa",
                "firewall", "external_scan", "fail2ban", "sysctl", "apparmor", "reboot_validation", "final_audit")
    steps = state.get("steps", {})
    missing = [name for name in required if steps.get(name, {}).get("status") != "succeeded"]
    if steps.get("base_reboot", {}).get("status") == "required" and steps.get("base_reboot", {}).get("completion_type") != "technician_attestation":
        missing.append("base_reboot")
    title = "RAPPORT PROVISOIRE — PROTOCOLE INCOMPLET" if missing else "RAPPORT D'INSTALLATION — SETUP ESSENTIEL"

    pages = []
    lines = [(title, True), ("Référentiel CotCod Setup Essentiel — version 1.0", False), ("", False)]
    if missing:
        lines.append(("Étapes non validées : " + ", ".join(missing), True))
        lines.append(("Ce document ne vaut pas déclaration de conformité.", True))
        lines.append(("", False))
    for heading, content in sections(state):
        lines.append((heading, True))
        for line in flatten(content):
            lines.extend((part, False) for part in textwrap.wrap(line, width=92, subsequent_indent="  ") or [""])
        lines.append(("", False))

    page = []
    for line, bold in lines:
        if len(page) >= 48:
            pages.append(page)
            page = []
        page.append((line, bold))
    if page:
        pages.append(page)

    objects = [None, None,
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>"]
    page_refs = []
    for page_lines in pages:
        content = bytearray()
        y = 790
        for line, bold in page_lines:
            font = b"F2" if bold else b"F1"
            size = 12 if bold else 9
            content.extend(b"BT /" + font + b" " + str(size).encode() + b" Tf 44 " + str(y).encode() + b" Td ")
            content.extend(pdf_string(line) + b" Tj ET\n")
            y -= 15
        page_id = len(objects) + 1
        stream_id = page_id + 1
        page_refs.append(page_id)
        objects.extend([
            f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents {stream_id} 0 R >>".encode(),
            b"<< /Length " + str(len(content)).encode() + b" >>\nstream\n" + content + b"endstream",
        ])
    objects[0] = ("<< /Type /Catalog /Pages 2 0 R >>").encode()
    kids = " ".join(f"{reference} 0 R" for reference in page_refs)
    objects[1] = f"<< /Type /Pages /Kids [{kids}] /Count {len(page_refs)} >>".encode()

    output = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, body in enumerate(objects, 1):
        offsets.append(len(output))
        output.extend(f"{index} 0 obj\n".encode() + body + b"\nendobj\n")
    xref_offset = len(output)
    output.extend(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode())
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode())
    output.extend(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref_offset}\n%%EOF\n".encode())
    Path(destination).write_bytes(output)
    Path(destination).chmod(0o600)
    return missing


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: report.py SESSION.json OUTPUT.pdf")
    source, destination = map(Path, sys.argv[1:])
    state = json.loads(source.read_text(encoding="utf-8"))
    missing = make_pdf(state, destination)
    print(f"PDF créé: {destination}")
    if missing:
        print("Rapport provisoire : étapes manquantes = " + ", ".join(missing))


if __name__ == "__main__":
    main()
