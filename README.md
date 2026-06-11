# wipe

Zero-wipe utility for rotational HDD disks.  
Two modes: bash script (quick use) and Rust TUI station (Raspberry Pi kiosk).

```
  ██╗    ██╗██╗██╗  ██╗██╗  ██╗
  ██║    ██║██║██║  ██║██║  ██║
  ██║    ██║██║██████╔╝██████╔╝
  ██║    ██║██║██╔═══╝ ██╔═══╝
  ████████╗██║██║     ██║
  ╚═══════╝╚═╝╚═╝     ╚═╝
```

---

## Bash script (usage ponctuel)

```bash
curl -fsSL https://raw.githubusercontent.com/painteau/wipe/main/launch.sh | sudo bash
```

> Doit etre execute en root.

### Ce que fait le script

1. Detecte et protege tous les disques montes (dont le live USB)
2. Scanne les block devices (`/dev/sd*`, `/dev/hd*`)
3. Ne conserve que les HDD rotatifs (`rotational=1`)
4. Demande une confirmation explicite `YES`
5. Empeche la mise en veille (`systemd-inhibit`)
6. Efface chaque disque avec `dd if=/dev/zero` (blocs 4M)
7. Verifie l'integrite du script via SHA256 avant execution

---

## Station Rust TUI (Raspberry Pi kiosk)

Interface graphique en mode terminal, split-screen, style defrag Windows 98.
Concu pour une boite en bois avec dock SATA 2 baies et boutons GPIO physiques.

### Materiel

| Composant | Detail |
|-----------|--------|
| Pi 4 | ARM64, Ubuntu 24.04 |
| Dock SATA 2 baies | `/dev/sda` + `/dev/sdb` |
| Bouton slot A | GPIO 17 (pin physique 11) |
| Bouton slot B | GPIO 27 (pin physique 13) |
| Ecran | HDMI, pas de clavier |

### Interface

```
+------------------------------------------------------+
|  WIPE STATION v2.1.0  |  2026-06-11 14:32:01  |  [2 boutons 10s = reboot]  |
+---------------------------+---------------------------+
|  SLOT 1                   |  SLOT 2                   |
|  Modele : WD Blue 4TB     |  En attente d'un          |
|  Serie  : WD-12345        |  disque HDD...            |
|  Taille : 4000 GB         |                           |
|                           |                           |
|  ████ ████ ████ ░░░░ ░░░░ |                           |
|  ████ ████ ░░░░ ░░░░ ░░░░ |                           |
|  ░░░░ ░░░░ ░░░░ ░░░░ ░░░░ |                           |
|                           |                           |
|  42.0%  87 MB/s  +18m  -25m                          |
+---------------------------+---------------------------+
```

### Comportement par slot

| Etat | Affichage | Action |
|------|-----------|--------|
| Aucun disque | Gris, message attente | Attendre |
| SSD detecte | Rouge, rejet | Retirer le disque |
| HDD pret | Jaune, clignotant | Appuyer bouton (appui court < 3s) |
| Effacement | Cyan, grille defrag | Automatique |
| Termine | Vert, grille pleine | Retirer le disque |
| Erreur | Rouge, message | Retirer le disque |

### Boutons GPIO

- **Appui court** (relache < 3s) : lance l'effacement du slot
- **Maintenir les 2 boutons 10s** : reboot du Pi

> Les appuis longs (> 3s) sans relachement sont ignores par les slots
> pour ne pas declencher de wipe accidentel lors d'un reboot.

### Installation

```bash
# Telechargement du binaire pre-compile ARM64
curl -fsSL https://github.com/painteau/wipe/releases/latest/download/wipe-station -o /usr/local/bin/wipe-station
curl -fsSL https://github.com/painteau/wipe/releases/latest/download/wipe-station.sha256 -o /tmp/wipe-station.sha256

# Verification SHA256
sha256sum -c /tmp/wipe-station.sha256
chmod +x /usr/local/bin/wipe-station

# Lancer
sudo wipe-station
```

### Service systemd

```ini
[Unit]
Description=Wipe Station TUI
After=multi-user.target

[Service]
ExecStart=/usr/local/bin/wipe-station
Restart=always
StandardInput=tty
StandardOutput=tty
TTYPath=/dev/tty1

[Install]
WantedBy=multi-user.target
```

### Mise a jour automatique

Au demarrage, la station verifie `station-rust/VERSION` sur GitHub.  
Si version plus recente disponible : telechargement, verification SHA256, re-exec automatique.

### Compilation manuelle

```bash
cd station-rust
cargo build --release --features gpio
```

> Cross-compilation ARM64 : voir `.github/workflows/release.yml`

---

## Logique de detection disque

| Type | Action |
|------|--------|
| HDD rotatif non monte | Efface |
| SSD / NVMe / USB flash | Rejete |
| Disque monte | Protege (ignore) |

## Avertissement

**Operation irreversible.** Toutes les donnees sur les disques selectionnes seront definitvement detruites.
