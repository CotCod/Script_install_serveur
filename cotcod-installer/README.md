# Installateur CotCod — Setup Essentiel

L’installateur guide le technicien dans le protocole pour Debian et Ubuntu
Server, sur amd64 ou arm64. Le système et sa version sont détectés
automatiquement depuis `/etc/os-release`. La progression est enregistrée dans
un état JSON protégé, avec sauvegardes des fichiers avant modification.

## Lancer le parcours

Depuis le dossier de l’installateur sur le serveur de test, lancez une seule
commande :

```bash
sudo ./cotcod-installer.sh
```

L’assistant collecte les informations, affiche les valeurs détectées et guide
les étapes dans l’ordre. Il s’arrête aux contrôles qui nécessitent une action du
technicien : vérification des services, partitionnement, tests réseau et SSH,
scan externe, test Fail2Ban et redémarrages. Il demande une confirmation et une
note de preuve pour ces contrôles.

Si l’assistant demande un redémarrage, redémarrez le serveur puis relancez la
même commande. La dernière session inachevée est reprise automatiquement. Pour
commencer volontairement une nouvelle session, utilisez :

```bash
sudo ./cotcod-installer.sh --new-session
```

Au démarrage, l’assistant vérifie les commandes requises pour l’ensemble du
parcours. S’il en manque, il regroupe leurs paquets APT et les installe avant
de commencer, après une confirmation `[Y/n]` (Entrée accepte l’installation).
Il choisit les paquets réseau selon la distribution détectée.

Les autres actions système restent précédées de leurs confirmations propres.
L’assistant ne redémarre jamais la machine de lui-même. Un accès console doit
rester disponible pendant les changements réseau et SSH.

## Parcours automatisé

Le parcours effectue, dans l’ordre :

1. Détection de Debian/Ubuntu, version et architecture; collecte du client, du
   rôle, du hostname, de l’IPv4 principale et des comptes administrateurs.
2. Inventaire puis mise à jour du système, installation des outils CotCod,
   configuration du hostname, de la locale, du clavier et du fuseau horaire.
3. Revue des services, contrôle du stockage et validation manuelle de
   `/etc/fstab`.
4. Configuration réseau IPv4 statique avec retour arrière programmé, puis test
   de connectivité depuis le poste technicien.
5. Politique de mots de passe et comptes administrateurs nominatifs.
6. Configuration SSH progressive : test de clé, désactivation du mot de passe,
   changement de port et nouveau test.
7. Enrôlement TOTP, configuration du pare-feu, Fail2Ban, sysctl et AppArmor.
8. Redémarrage demandé au technicien, audit final de l’état réel et génération
   du rapport PDF dans le répertoire d’état (par défaut
   `/var/lib/cotcod-installer`).

L’installateur intervient sur un système d’exploitation déjà installé; il ne
demande donc pas le chemin d’une image ISO qui n’est généralement pas présente
sur le serveur. La distribution, la version et l’architecture sont détectées
automatiquement.

Le rapport PDF est marqué provisoire tant que l’audit final n’a pas réussi. La
session n’est clôturée qu’après génération du rapport à la suite d’un audit
réussi.

## Options avancées

Le mode assistant est le parcours recommandé. Les options par étape restent
disponibles pour le dépannage et la reprise manuelle; elles nécessitent de
fournir l’identifiant de session avec `--session ID`.

```bash
sudo ./cotcod-installer.sh --help
```

Les mots de passe, secrets TOTP et codes de récupération ne sont pas
enregistrés dans l’état JSON.

La syntaxe Bash et Python a été vérifiée statiquement. L’exécution complète et
la génération réelle du PDF doivent être validées sur le serveur de test avant
toute utilisation opérationnelle.
