# frappe-installer

Ein robustes Bash-Skript zur vollautomatischen Installation von [Frappe Bench](https://frappeframework.com) auf Debian/Ubuntu — inklusive Production-Setup mit Nginx und Supervisor.

Entwickelt und gepflegt von **[Dells Dienste](https://diedells.de)**.

---

## Schnellstart

```bash
wget -O install_frappe_bench.sh https://raw.githubusercontent.com/ManuelDell/frappe-installer/main/install_frappe_bench.sh
chmod +x install_frappe_bench.sh
sudo bash install_frappe_bench.sh
```

---

## Features

- 🌐 **Zweisprachig** — Deutsch (Standard) und Englisch wählbar
- ⚡ **Quick-Install-Modus** — vollautomatisch ohne Eingaben, Passwörter werden generiert und gespeichert
- 🎛️ **Interaktiver Modus** — individuelle Konfiguration von Version, Benutzer, Pfad, Passwörtern
- 📊 **Fortschrittsbalken oder Verbose-Ausgabe** wählbar
- 📋 **Vollständiges Logfile** unter `/var/log/install_frappe_bench_*.log`
- 🔄 **Idempotent** — erkennt vorherige Installationen und räumt sauber auf
- 🗄️ **MariaDB-Reset** — bei Neuinstallation wird MariaDB immer per `purge` entfernt und neu installiert, damit keine alten Datenbanken oder Passwörter stören
- 🐳 **LXC-kompatibel** — funktioniert in Proxmox LXC-Containern (D-Bus-Fallbacks für `systemctl`)
- 🔧 **Auto-Repair** — repariert automatisch fehlerhafte `bench init`-Zustände

---

## Unterstützte Systeme

| OS | Version |
|---|---|
| Debian | 12 (Bookworm), 13 (Trixie) |
| Ubuntu | 22.04 LTS, 24.04 LTS |

> Muss als **root** ausgeführt werden.

---

## Unterstützte Frappe-Versionen

| Branch | Python | Node.js | MariaDB |
|---|---|---|---|
| `version-15` (stable) | 3.10+ | 20 LTS | 10.x (System) |
| `version-16` (develop) | 3.14 (exakt) | 24 | 11.8 (offizielles Repo) |

---

## Installations-Modi

### 1. Quick-Install

Vollautomatisch ohne weitere Eingaben. Startet nach einem 3-Sekunden-Countdown (Abbruch: `Ctrl+C`).

**Feste Vorkonfiguration:**
- Branch: `version-16`
- Linux-Benutzer: `frappe`
- Bench-Pfad: `/home/frappe/frappe-bench`
- Site: `frappe.localhost`
- Passwörter: automatisch generiert, gespeichert in `/home/frappe/pwd.txt`

### 2. Interaktiv

Alle Parameter werden abgefragt:
- Ausgabe-Modus (Fortschrittsbalken / Verbose)
- Frappe-Version (v15 / v16)
- Linux-Benutzername
- Bench-Ordnername
- MariaDB Root-Passwort
- Optional: Site-Name und Admin-Passwort

---

## Was installiert wird

Das Skript führt **10 Schritte** aus:

1. System aktualisieren (`apt update && apt upgrade`)
2. Abhängigkeiten installieren (Build-Tools, Python-Dev, Redis, Nginx, Supervisor, ...)
3. MariaDB installieren (purge & Neuinstallation, für v16: MariaDB 11.8 aus offiziellem Repo)
4. MariaDB konfigurieren (UTF-8, InnoDB-Tuning, Root-Passwort setzen)
5. Redis konfigurieren
6. Node.js installieren (via NodeSource, v20 oder v24)
7. Python prüfen (System-Python oder via `uv` installiert)
8. wkhtmltopdf installieren (für PDF-Generierung)
9. Benutzer anlegen, `uv` installieren, `bench init` ausführen, optional Site erstellen
10. Production-Setup (`bench setup production`, Nginx + Supervisor aktivieren)

---

## Passwörter (Quick-Install)

Die generierten Passwörter werden in `/home/frappe/pwd.txt` gespeichert (Berechtigungen: `600`).  
Am Ende der Installation werden sie zusätzlich direkt im Terminal angezeigt.

```
# Frappe Bench — Generierte Passwörter
MariaDB Root-Passwort : <generiert>
Frappe Admin-Passwort : <generiert>

Site     : frappe.localhost
Login    : http://<IP>  →  Administrator / <admin-passwort>
```

> ⚠️ Datei nach dem Sichern löschen: `rm /home/frappe/pwd.txt`

---

## Nach der Installation

```bash
# Prozess-Status anzeigen
supervisorctl status

# Alles neustarten
supervisorctl restart all

# Als Bench-Benutzer wechseln
sudo -u frappe bash

# ERPNext installieren
cd /home/frappe/frappe-bench
bench get-app erpnext --branch version-16
bench --site frappe.localhost install-app erpnext

# HTTPS einrichten
bench setup lets-encrypt frappe.localhost

# Logs verfolgen
tail -f /home/frappe/frappe-bench/logs/*.log
```

> ⚠️ **Immer `supervisorctl` verwenden** — nicht `bench start`. Der Production-Modus läuft über Supervisor.

---

## Logfile

Jeder Durchlauf erzeugt ein vollständiges Logfile:

```
/var/log/install_frappe_bench_YYYYMMDD_HHMMSS.log
```

Bei Fehlern werden die letzten 30 Zeilen direkt im Terminal angezeigt.

---

## Bekannte Eigenheiten

**LXC-Container (Proxmox):**  
`systemctl` schlägt in unprivilegierten Containern wegen fehlendem D-Bus manchmal fehl. Das Skript fängt das ab und prüft den Prozess-Status direkt via `pgrep`.

**MariaDB wird immer neu installiert:**  
Bei jedem Skript-Durchlauf wird MariaDB per `apt purge` entfernt und neu installiert. Das garantiert einen sauberen Zustand ohne alte Passwörter oder verwaiste Datenbanken. Bestehende Frappe-Daten werden dabei gelöscht.

**Python 3.14 für v16:**  
Frappe v16 benötigt exakt Python 3.14. Das Skript installiert es automatisch über [`uv`](https://github.com/astral-sh/uv) im User-Kontext des Bench-Benutzers.

---

## Lizenz

MIT — siehe [LICENSE](LICENSE)

---

*Dells Dienste · [diedells.de](https://diedells.de)*
