# Installateur CotCod — Setup Essentiel

Parcours guidé du protocole CotCod Setup Essentiel, destiné à Debian Stable et
Ubuntu Server LTS amd64/arm64. L’état de chaque intervention est stocké en JSON
avec des permissions restrictives. Les actions système exigent une confirmation
spécifique et créent une sauvegarde de leurs fichiers de configuration avant
modification.

## Parcours actuel

1. `--prepare` collecte les informations client et détecte l’IPv4 principale.
2. `--confirm-preparation` enregistre la revue du technicien.
3. `--verify-iso` compare l’image avec le SHA-256 officiel (ou
   `--record-manual iso_verification` consigne une vérification faite en amont).
   Avant toute mise à jour, le technicien valide la version Debian Stable ou
   Ubuntu Server LTS détectée avec `--record-manual os_support` et une référence
   de validation.
4. `--prepare-base` inventorie l’OS, le noyau, les paquets à mettre à jour et
   les outils CotCod absents. `--apply-base` sauvegarde `/etc` et l’état des
   paquets, puis demande `APPLIQUER-BASE` avant `apt-get update`,
   `apt-get full-upgrade` et l’installation des outils CotCod. La même étape
   applique le hostname préparé, `fr_FR.UTF-8`, le clavier anglais et le fuseau
   Europe/Paris. Le technicien examine les services actifs après installation
   puis confirme leur revue avec `--record-manual services_review`. Si une mise
   à jour impose un redémarrage, celui-ci est requis avant le stockage; après
   redémarrage, consigner `--record-manual base_reboot`.
5. `--inspect-storage` relève les disques, filesystems, montages et valide
   `/etc/fstab`. Après contrôle du technicien, `--record-manual storage` valide
   le partitionnement. Le script ne repartitionne pas un disque déjà installé.
6. `--inspect-network` relève interfaces, routes, DNS et NTP. `--configure-network`
   propose une IPv4 fixe, la passerelle détectée et les DNS CotCod, puis programme
   un retour arrière automatique après quinze minutes pendant les tests de connectivité. La
   modification n'est conservée qu'après confirmation `GARDER-RESEAU`. Relancez
   `--inspect-network`, testez depuis le poste technicien puis consignez
   `--record-manual network`.
7. `--apply-users` sauvegarde les fichiers PAM et `login.defs`, applique la
   politique de mots de passe, crée les comptes autorisés si nécessaire, leur
   fait saisir leur propre mot de passe et les ajoute au groupe `sudo`.
8. `--configure-ssh` pose la configuration initiale en gardant temporairement
   l’authentification par mot de passe. Après déploiement et test externe de la
   clé, `--record-manual ssh_key_test` permet `--harden-ssh` de désactiver les
   mots de passe seulement. Après un second test, consigner
   `--record-manual ssh_password_test`; `--change-ssh-port` applique ensuite un
   port aléatoire dans 49152–65535. Tester ce port puis consigner
   `--record-manual ssh`.
9. `--configure-mfa` enrôle les administrateurs en TOTP sans enregistrer les
   secrets ni les codes de récupération. Après test de connexion, consigner
   `--record-manual mfa`.
10. `--apply-protections` demande `APPLIQUER-PROTECTIONS`, sauvegarde les
    configurations, puis applique UFW, Fail2Ban, le fichier sysctl CotCod et
    AppArmor. Les vérifications externes du port et des protections sont
    consignées avec `--record-manual firewall`, `external_scan` et `fail2ban`.
11. Après redémarrage et validation de la persistance par le technicien,
    `--record-manual reboot_validation` permet `--final-audit`. L’audit contrôle
    l’état réel du serveur et refuse la conformité si une étape ou une
    vérification échoue.
12. `--generate-report` écrit le PDF dans le répertoire d’état. Avant la
    réussite de l’audit final, il est marqué comme provisoire.

## Première utilisation

Toutes les commandes ci-dessous s’exécutent depuis le dossier de l’installateur
sur le serveur cible. Le script n’est pas conçu pour être lancé sur un serveur
de production sans essai préalable sur une VM.

```bash
sudo ./cotcod-installer.sh --prepare
sudo ./cotcod-installer.sh --confirm-preparation --session ID_SESSION
sudo ./cotcod-installer.sh --verify-iso --session ID_SESSION
sudo ./cotcod-installer.sh --prepare-base --session ID_SESSION
sudo ./cotcod-installer.sh --show-preparation --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual os_support --session ID_SESSION
sudo ./cotcod-installer.sh --apply-base --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual services_review --session ID_SESSION
```

L’identifiant de session est affiché lors de `--prepare`. Les contrôles manuels
se consignent avec `--record-manual ETAPE --session ID_SESSION`; le script
demande une confirmation et une note de preuve sans secret.

Après l’installation de base, la suite des commandes d’intervention est :

```bash
sudo ./cotcod-installer.sh --inspect-storage --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual storage --session ID_SESSION
sudo ./cotcod-installer.sh --inspect-network --session ID_SESSION
sudo ./cotcod-installer.sh --configure-network --session ID_SESSION
sudo ./cotcod-installer.sh --inspect-network --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual network --session ID_SESSION
sudo ./cotcod-installer.sh --apply-users --session ID_SESSION
sudo ./cotcod-installer.sh --configure-ssh --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual ssh_key_test --session ID_SESSION
sudo ./cotcod-installer.sh --harden-ssh --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual ssh_password_test --session ID_SESSION
sudo ./cotcod-installer.sh --change-ssh-port --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual ssh --session ID_SESSION
sudo ./cotcod-installer.sh --configure-mfa --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual mfa --session ID_SESSION
sudo ./cotcod-installer.sh --apply-protections --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual firewall --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual external_scan --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual fail2ban --session ID_SESSION
sudo ./cotcod-installer.sh --record-manual reboot_validation --session ID_SESSION
sudo ./cotcod-installer.sh --final-audit --session ID_SESSION
sudo ./cotcod-installer.sh --generate-report --session ID_SESSION
```

## Périmètre de cette première version

La version applique les étapes configurables après confirmation et sauvegarde,
puis exige une attestation pour les contrôles qui dépendent d'un support ou d'un
poste externe : provenance ISO vérifiée en amont, partitionnement, revue des
services, tests de connexion SSH/MFA, scan du pare-feu, essai Fail2Ban et
validation après redémarrage. Le partitionnement reste manuel après installation
du système. Le rapport PDF suit les quinze rubriques du modèle; il est provisoire
tant que l'audit final n'est pas réussi.

Sur Debian avec ifupdown, `resolvconf` est ajouté à l'installation de base afin
que les directives DNS soient appliquées par le gestionnaire de résolution. Si
un service horaire autre que `systemd-timesyncd` est présent, sa purge demande
une confirmation distincte et ses fichiers sont sauvegardés.

La validation effectuée ici est statique (syntaxe Bash et Python). Le parcours
complet reste à dérouler sur le serveur de test prévu avant toute utilisation
opérationnelle; l'installateur n'a pas été exécuté sur cette machine.

Si `jq` manque, le programme propose son installation et n’actualise les index
APT qu’après la saisie de `CONFIRMER`. L’installateur ne redémarre jamais le
serveur automatiquement et ne sauvegarde jamais les mots de passe, secrets TOTP
ou Recovery Codes.
