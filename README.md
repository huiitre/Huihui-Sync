# huihuisync

Outil de synchronisation de fichiers/dossiers entre machines via rsync/SSH.

## Dépendances

- `rsync`
- `ssh`
- `jq`

Fedora : `sudo dnf install rsync jq`

## Installation

```bash
git clone <repo> ~/huihuisync
chmod +x ~/huihuisync/huihuisync.sh
```

Copier et remplir la config :

```bash
cp ~/huihuisync/config.example.json ~/huihuisync/config.json
```

Ajouter dans `~/.bashrc.d/30-aliases.sh` (ou `~/.bashrc`) :

```bash
alias huihuisync='bash ~/huihuisync/huihuisync.sh'
```

## Configuration

### config.json

Config globale, à remplir sur chaque machine. Ne pas committer ce fichier.

```json
{
  "remote_host": "user@host",
  "remote_port": 22,
  "lock_timeout": 30
}
```

### profiles/

Créer un fichier `<nom>.json` par profil à synchroniser. Les fichiers de profil ne sont pas versionnés (sauf `example.json`).

```json
{
  "enabled": true,
  "remote_base": "/data/sync/example",
  "backup": true,
  "sources": [
    "~/.local/share/ExampleData"
  ],
  "exclude": [],
  "post_pull": "",
  "post_push": ""
}
```

| Champ | Description |
|---|---|
| `enabled` | `true` pour activer le profil. Absent ou `false` = ignoré. |
| `remote_base` | Chemin de base sur le serveur distant |
| `backup` | Crée une archive tar.gz avant chaque push |
| `sources` | Fichiers ou dossiers à synchroniser |
| `exclude` | Patterns à exclure (rsync) |
| `post_pull` | Commande exécutée après un pull (ex: `source ~/.bashrc`) |
| `post_push` | Commande exécutée après un push |

Les champs `remote_host` et `remote_port` sont optionnels dans le profil — ils surchargent la config globale si présents.

## Usage

```bash
huihuisync push dbeaver
huihuisync pull dbeaver
huihuisync --verbose push dotfiles
huihuisync pull dotfiles
```

## Logs

Les logs sont écrits dans `logs/huihuisync.log` à la racine du projet.

Par défaut : messages essentiels (début, fin, statut).  
Avec `--verbose` : détails rsync, commandes SSH, chaque étape.

## Intégration .desktop

```
Exec=/bin/bash -c '/home/<user>/huihuisync/huihuisync.sh pull dbeaver; dbeaver-ce %U; /home/<user>/huihuisync/huihuisync.sh push dbeaver'
```

## Structure remote

```
/data/sync/<profil>/
├── current/        # données actuelles
├── backups/        # archives tar.gz horodatées
└── lock            # fichier de lock temporaire
```