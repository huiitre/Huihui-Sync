# huihuisync

Orchestrateur de synchronisation robuste via rsync/SSH avec gestion de lock et isolation d'erreurs.

> Ce dépôt GitHub est un miroir en lecture seule. Le développement se fait sur une instance GitLab privée.

## Dépendances

- `rsync`
- `ssh`
- `jq`
- `inotify-tools` (uniquement pour l'auto-push : `huihuisync watch`)

Fedora : `sudo dnf install rsync jq inotify-tools`
Ubuntu / Kubuntu : `sudo apt install rsync jq inotify-tools`

## Installation

```bash
git clone <repo> ~/Huihui-Sync
chmod +x ~/Huihui-Sync/huihuisync.sh
```

### Configuration globale

```bash
cp ~/Huihui-Sync/config.example.json ~/Huihui-Sync/config.json
```

### Alias recommandé

```bash
alias huihuisync='bash ~/Huihui-Sync/huihuisync.sh'
```

## Configuration des profils

Les profils sont définis dans `profiles/*.json`.

```json
{
  "enabled": true,
  "remote_base": "/data/sync/tabby",
  "backup": true,
  "sources": [
    "~/.config/tabby"
  ],
  "exclude": ["*.log", "Cache/"],
  "post_pull": "systemctl --user restart tabby.service",
  "post_push": "",
  "auto_push": false,
  "auto_push_delay": 10
}
```

- `auto_push` : pousse automatiquement le profil après une modification (voir [Auto-push](#auto-push)). `false` si absent.
- `auto_push_delay` : secondes sans modification avant le push, et intervalle entre deux essais. 10 par défaut. En dessous de 5, l'auto-push est ignoré pour ce profil (sécurité).

## Usage

### Synchronisation simple
```bash
huihuisync pull datagrip
huihuisync push dotfiles
```

### Synchronisation multiple
Le script enchaîne les profils et continue même en cas d'erreur sur l'un d'eux.
```bash
huihuisync pull tabby datagrip dotfiles
```

### Synchronisation globale
Synchronise tous les profils ayant `"enabled": true`.
```bash
huihuisync pull all
huihuisync push all
```

### Liste des profils
```bash
huihuisync profile list
huihuisync profile list --verbose
```

### Backups

Avec `"backup": true`, chaque push crée sur le NAS une archive `remote_base/backups/AAAAMMJJ_HHMMSS_<machine>_<profil>.tar.gz` de l'état précédent. Seules les 20 plus récentes sont gardées par profil, toutes machines confondues (`BACKUP_KEEP` dans `lib/backup.sh`) ; les fichiers qui ne suivent pas ce format ne sont jamais supprimés.

### Garde-fous

- `push` est refusé si le NAS a une version plus récente (une autre machine a poussé depuis votre dernier push/pull). Faire un `pull`, ou `push --force` pour écraser.
- `pull` est refusé si le profil a des modifications locales pas encore poussées (profils `auto_push`), car `rsync --delete` les écraserait. Faire un `push`, ou `pull --force` pour les écraser.

## Auto-push

Un service systemd utilisateur surveille les sources des profils `"auto_push": true` et les pousse `auto_push_delay` secondes après la dernière modification.

```bash
huihuisync watch install     # crée le service et le démarre (une fois par machine)
huihuisync watch status      # état du service et profils en attente
huihuisync watch disable     # arrête le service, ne redémarre plus au démarrage
huihuisync watch enable      # le réactive
huihuisync watch restart     # après une mise à jour du script
huihuisync watch uninstall   # supprime le service
```

L'état du service est celui de systemd (`systemctl --user status huihuisync-watch`). Il est aussi affiché en tête de `profile list`. Le service démarre à l'ouverture de session ; sur une machine sans session (NAS) : `sudo loginctl enable-linger $USER`.

Fonctionnement :

- Seuls les fichiers réellement synchronisés comptent : une modification d'un fichier exclu (`exclude`) ou hors des sources ne déclenche rien. La comparaison se fait sur une empreinte locale (liste rsync des fichiers, taille, date) prise au dernier push/pull réussi.
- Une modification détectée est enregistrée dans `.watch/pending/<profil>`. Tant qu'elle existe, le service réessaie toutes les `auto_push_delay` secondes (NAS injoignable, lock pris...). Elle survit à un redémarrage.
- Un push réussi (automatique ou manuel) efface l'attente. Une nouvelle modification la recrée.
- Si le NAS a une version plus récente, le push est refusé et une notification est affichée une fois. Le service ne fait **jamais** de pull, ni au démarrage ni après. Il revérifie toutes les 60 s.
- Au démarrage, le service compare l'empreinte : les modifications faites pendant qu'il était arrêté sont poussées. Pour un profil jamais surveillé, l'état actuel sert de référence.
- Modifier un fichier de `profiles/` redémarre le service, qui relit la liste.
- Logs : `logs/huihuisync.log` et `journalctl --user -u huihuisync-watch`.
- La clé SSH vers le NAS doit être utilisable sans saisie (clé sans passphrase ou agent chargé) : le service utilise `BatchMode=yes`.

## Logs

Localisés dans `logs/huihuisync.log`.  
Utilisez `--verbose` pour le détail des transferts rsync.

## Architecture V2

- **Isolation** : Chaque profil est traité de manière autonome. Un échec sur un profil n'arrête pas la chaîne.
- **Locking** : Verrouillage spécifique par profil sur le serveur distant.
- **Staging Systemd** : (En cours) Les fichiers systemd synchronisés sont isolés pour vérification manuelle avant application.
- **Master Orchestrator** : Conçu pour être piloté par une unité systemd unique gérant le cycle de vie startup/shutdown.