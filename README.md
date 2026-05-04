# huihuisync

Orchestrateur de synchronisation robuste via rsync/SSH avec gestion de lock et isolation d'erreurs.

## Dépendances

- `rsync`
- `ssh`
- `jq`

Fedora : `sudo dnf install rsync jq`

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
  "post_push": ""
}
```

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

## Logs

Localisés dans `logs/huihuisync.log`.  
Utilisez `--verbose` pour le détail des transferts rsync.

## Architecture V2

- **Isolation** : Chaque profil est traité de manière autonome. Un échec sur un profil n'arrête pas la chaîne.
- **Locking** : Verrouillage spécifique par profil sur le serveur distant.
- **Staging Systemd** : (En cours) Les fichiers systemd synchronisés sont isolés pour vérification manuelle avant application.
- **Master Orchestrator** : Conçu pour être piloté par une unité systemd unique gérant le cycle de vie startup/shutdown.