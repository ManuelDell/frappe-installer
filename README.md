# Frappe Bench Installer

Ein interaktives Installationsskript für [Frappe Framework](https://frappe.io/framework) auf Debian und Ubuntu — speziell gehärtet für **LXC-Container** (z. B. Proxmox).

Das Skript installiert alle Abhängigkeiten, richtet MariaDB ein, erstellt einen dedizierten Linux-Benutzer, initialisiert eine Bench und konfiguriert ein Production-Setup mit **Supervisor + Nginx** — alles in einem Durchlauf.

## Schnellstart

```bash
wget -O install_frappe_bench.sh https://raw.githubusercontent.com/<user>/<repo>/main/install_frappe_bench.sh
chmod +x install_frappe_bench.sh
sudo bash install_frappe_bench.sh
```

Das Skript fragt alles Nötige interaktiv ab. Keine Argumente nötig.

## Was wird abgefragt?

| Abfrage | Standard | Beispiel |
|---|---|---|
| Ausgabe-Modus | Fortschrittsbalken | Verbose |
| Frappe-Version | version-15 (stable) | version-16 (develop) |
| Linux-Benutzername | `frappe` | `erpnext` |
| Bench-Ordnername | `frappe-bench` | `mein-bench` |
| MariaDB Root-Passwort | — | *(wird abgefragt + bestätigt)* |
| Site erstellen? | Nein | `erp.example.com` |
| Admin-Passwort | — | *(wird abgefragt + bestätigt)* |

## Was wird installiert?

### version-15 (stable)

| Komponente | Version |
|---|---|
| Python | 3.11 (System) |
| Node.js | 18 (NodeSource) |
| MariaDB | 10.x (Debian/Ubuntu Repo) |
| Redis | System-Paket |

### version-16 (develop)

| Komponente | Version |
|---|---|
| Python | 3.14 (via uv, als User — **zwingend erforderlich**) |
| Node.js | 24 (NodeSource — **zwingend erforderlich**) |
| MariaDB | 11.8 (offizielles MariaDB Repo) |
| Redis | System-Paket |
| uv | aktuell (als User installiert) |

## Installationsschritte

```
 1/10  System aktualisieren
 2/10  Abhängigkeiten installieren
 3/10  MariaDB installieren
 4/10  MariaDB konfigurieren (Charset, Root-PW, Absicherung)
 5/10  Redis konfigurieren
 6/10  Node.js + Yarn installieren
 7/10  System-Python prüfen
 8/10  wkhtmltopdf installieren
 9/10  Benutzer erstellen, uv/Python/Bench CLI + bench init
10/10  Production-Setup (Supervisor + Nginx)
```

## Features

### LXC-kompatibel

- **D-Bus-Fehler abgefangen**: `systemctl` schlägt in LXC-Containern oft mit D-Bus-Fehlern fehl, obwohl der Dienst läuft. Das Skript prüft per `pgrep` ob der Prozess tatsächlich aktiv ist und fällt bei Bedarf auf `service` oder direkten Prozessstart zurück.
- **Fehlende Pakete**: Auf minimalen Debian-Installationen (LXC-Templates) fehlen Pakete wie `software-properties-common`. Diese werden als optional behandelt — das Skript installiert jedes Paket einzeln und loggt nicht verfügbare als Warnung.
- **Keine interaktiven dpkg-Dialoge**: `DEBIAN_FRONTEND=noninteractive` verhindert Prompts wie den MariaDB Feedback-Plugin-Dialog.

### Saubere User-Isolation

Alles was bench betrifft läuft als dedizierter User:

- `uv` wird als Bench-User installiert (nicht als root)
- Python wird im User-Home installiert (`~/.local/share/uv/python/`)
- `bench` CLI wird per `uv tool install` im User-Kontext eingerichtet
- Keine Dateien unter `/root/` die der Bench-User nicht erreichen kann

### Ausgabe-Modi

**Fortschrittsbalken** — saubere Anzeige mit Spinner, alle Details im Logfile:

```
  [████████████████░░░░░░░░░░░░░░] 53%  Benutzer & Bench initialisieren
    ⠹ Benutzer & Bench initialisieren
```

**Verbose** — alle Ausgaben live auf dem Terminal + Logfile.

In beiden Modi wird ein vollständiges Logfile geschrieben:

```
/var/log/install_frappe_bench_YYYYMMDD_HHMMSS.log
```

### Automatische Validierung

Nach `bench init` prüft das Skript:

1. Existiert `apps/frappe/`?
2. Existiert `env/bin/python` (venv)?
3. Kann `import frappe` im venv ausgeführt werden?

Falls der Import fehlschlägt, wird automatisch `pip install -e apps/frappe` als Reparatur versucht — das verhindert den berüchtigten `No module named 'frappe'`-Fehler bei `bench start`.

## Nach der Installation

### Dienste verwalten

```bash
# Prozesse anzeigen
supervisorctl status

# Alles neustarten
supervisorctl restart all

# Einzelnen Prozess neustarten
supervisorctl restart frappe-bench-web:frappe-bench-frappe-web
```

> **Wichtig**: Verwende `supervisorctl` — nicht `bench start`! `bench start` ist nur für die Entwicklung gedacht.

### Als Bench-User arbeiten

```bash
sudo -u frappe bash
cd ~/frappe-bench
```

### ERPNext hinzufügen

```bash
bench get-app erpnext --branch version-15   # oder version-16
bench --site <site-name> install-app erpnext
```

### HTTPS einrichten

```bash
bench setup lets-encrypt <site-name>
```

### Site erstellen (falls bei Installation übersprungen)

```bash
bench new-site erp.example.com \
    --mariadb-root-password <pw> \
    --admin-password <pw>
bench use erp.example.com
sudo bench setup production frappe --yes
```

### Logs

```bash
tail -f ~/frappe-bench/logs/*.log
```

## Voraussetzungen

- **OS**: Debian 12+ oder Ubuntu 22.04+ (inkl. LXC)
- **Ausführung**: Als `root` oder mit `sudo`
- **Netzwerk**: Internetzugang (für apt, npm, pip, git clone)
- **RAM**: Mindestens 2 GB empfohlen
- **Disk**: Mindestens 10 GB frei

## Fehlerbehebung

### Logfile prüfen

```bash
cat /var/log/install_frappe_bench_*.log
```

### MariaDB antwortet nicht

```bash
# Prozess prüfen
pgrep mariadbd

# Manuell starten
systemctl start mariadb
# oder in LXC:
service mariadb start
```

### bench --version schlägt fehl

`bench` versucht immer das aktuelle Verzeichnis als Bench-Directory zu lesen. Aus `/root/` oder einem Verzeichnis ohne Zugriff kommt ein `PermissionError`. Lösung:

```bash
cd /tmp && bench --version
# oder besser:
sudo -u frappe bash -c "cd /tmp && bench --version"
```

### "No module named 'frappe'"

Falls das trotz Validierung auftritt:

```bash
cd ~/frappe-bench
./env/bin/pip install -e apps/frappe
```

## Lizenz

MIT

## Autor

**Dells Dienste** — [diedells.de](https://diedells.de)
