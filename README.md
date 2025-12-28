# Ubuntu bootstrap

Skrypt do szybkiego przygotowania świeżego serwera Ubuntu:
- `apt update/upgrade`
- ustawienie hostname + lokalne FQDN (primary + aliasy)
- instalacja i uruchomienie Tailscale
- utworzenie użytkownika (domyślnie `veloadmin`) + sudo
- wgranie `authorized_keys` (z GitHub `.keys`, URL albo lokalnie)
- konfiguracja UFW
- hardening SSH (domyślnie port 10022, bez haseł, bez root)
- `unattended-upgrades`

## Wymagania
- Ubuntu
- uruchomienie jako `root` lub z `sudo`

## Zmienne środowiskowe

Wymagane:
- `HOSTNAME_SHORT` – krótka nazwa hosta (np. `lwe-bael`)
- `TS_AUTHKEY` – Tailscale auth key (`tskey-auth-...`)

Opcjonalne:
- `PRIMARY_DOMAIN` – domena kanoniczna (domyślnie: `archax.eu`)
- `EXTRA_DOMAINS` – dodatkowe domeny (comma-separated), np. `ts.archax.eu,example.net`
- `NEW_USER` – nazwa użytkownika (domyślnie: `veloadmin`)
- `SSH_PORT` – port SSH (domyślnie: `10022`)
- `KEEP_SSH_PORT_22` – czy zostawić 22 otwarty w UFW jako „safety net” (`true/false`, domyślnie `true`)

Źródło kluczy SSH (jedno z poniższych):
- `GITHUB_KEYS_USER` – pobiera klucze z `https://github.com/<user>.keys`
- `AUTHORIZED_KEYS_URL` – pobiera plik `authorized_keys` z podanego URL (np. raw z GitHub)
- jeśli oba puste, skrypt próbuje skopiować lokalne `~/.ssh/authorized_keys` z użytkownika uruchamiającego `sudo` lub z `/root`

## Uruchomienie (zalecane – z pliku .env)

Utwórz plik `.env` (NIE commituj go do repo):

```bash
cat > .env <<'EOF'
HOSTNAME_SHORT="lwe-bael"
PRIMARY_DOMAIN="shase.eu"
EXTRA_DOMAINS="ts.archax.eu"
TS_AUTHKEY="tskey-auth-REDACTED"

# opcjonalnie:
# NEW_USER="veloadmin"
# SSH_PORT="10022"
# KEEP_SSH_PORT_22="true"

# klucze SSH (wybierz jedno):
GITHUB_KEYS_USER="senecjusz"
# AUTHORIZED_KEYS_URL="https://raw.githubusercontent.com/<org>/<repo>/<ref>/authorized_keys"
EOF

chmod 600 .env


## Quick start

```bash
sudo HOSTNAME_SHORT="xxx-host" \
  PRIMARY_DOMAIN="domian.eu" \
  EXTRA_DOMAINS="ts.domain.eu" \
  TS_AUTHKEY="tskey-auth-REDACTED" \
  GITHUB_KEYS_USER="senecjusz" \
  ./bootstrap.sh
