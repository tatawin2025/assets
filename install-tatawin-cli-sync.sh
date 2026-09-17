#!/bin/bash
# install-tatawin-cli-sync.sh — pose le mécanisme de mise à jour automatique des wrappers ~/bin.
#
# Pourquoi : les wrappers (gws, fleet, msgraph, primo, slack, notion, abm + _lib/op-cache.sh)
# n'étaient posés QU'AU provisioning, par l'agent de setup, qui s'arrête ensuite. Un wrapper
# ajouté ou corrigé plus tard (abm, token personnel…) n'atteignait jamais un poste déjà en
# service. Même traitement que le bundle vault-mcp (install-vault-mcp-sync.sh) : un LaunchDaemon
# compare la release `tatawin-cli` toutes les heures et ne réinstalle qu'en cas d'écart, pour
# CHAQUE utilisateur du poste.
#
# Ce qu'il installe :
#   /Library/Scripts/tatawin-cli-sync.sh                    le script de sync
#   /Library/LaunchDaemons/com.tatawin.cli-sync.plist       toutes les heures + au boot
#
# Idempotent — le relancer ne fait que remettre les fichiers en place, et déclenche une passe.
#
# Usage (une fois par poste, via setup-tatawin.sh, ou via Fleet pour le parc existant) :
#   curl -fsSL https://raw.githubusercontent.com/tatawin2025/assets/main/install-tatawin-cli-sync.sh | sudo bash
set -u

SYNC=/Library/Scripts/tatawin-cli-sync.sh
PLIST=/Library/LaunchDaemons/com.tatawin.cli-sync.plist
LABEL=com.tatawin.cli-sync

if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit tourner en root (sudo) : il écrit dans /Library." >&2
    exit 1
fi

mkdir -p /Library/Scripts

cat > "$SYNC" << 'SYNCEOF'
#!/bin/bash
# tatawin-cli-sync — maintient les wrappers ~/bin de chaque utilisateur alignés sur la
# release `tatawin-cli` (tatawin2025/assets). Ne touche à rien si la release est injoignable
# ou inchangée. Réinstalle via l'installeur officiel, sous l'identité de chaque utilisateur.
set -u
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

URL="https://github.com/tatawin2025/assets/releases/download/tatawin-cli/tatawin-cli.tar.gz"
INSTALLER="https://raw.githubusercontent.com/tatawin2025/assets/main/install-tatawin-cli.sh"
STAMP="/Library/Application Support/Tatawin/.tatawin-cli-sha256"
LOG="/var/log/tatawin-cli-sync.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

TMP="$(mktemp -d)" || exit 0
trap 'rm -rf "$TMP"' EXIT

curl -fsSL --max-time 60 -o "$TMP/cli.tar.gz" "$URL" 2>/dev/null \
    || { log "téléchargement impossible — wrappers inchangés"; exit 0; }
[[ -s "$TMP/cli.tar.gz" ]] || { log "archive vide — wrappers inchangés"; exit 0; }
tar -tzf "$TMP/cli.tar.gz" >/dev/null 2>&1 || { log "archive illisible — wrappers inchangés"; exit 0; }

NEW="$(shasum -a 256 "$TMP/cli.tar.gz" | awk '{print $1}')"
OLD="$(cat "$STAMP" 2>/dev/null || true)"

# Un utilisateur sans ~/bin/gws (poste jamais passé par l'installeur, ou nouveau compte)
# est traité même si la release n'a pas changé.
need=0
[[ "$NEW" != "$OLD" ]] && need=1
for home in /Users/*; do
    u="$(basename "$home")"
    [[ -d "$home" && "$u" != "Shared" ]] || continue
    uid="$(id -u "$u" 2>/dev/null || echo 0)"; [[ "$uid" -ge 500 ]] || continue
    [[ -x "$home/bin/gws" ]] || need=1
done
[[ "$need" -eq 1 ]] || exit 0

ok=1
for home in /Users/*; do
    u="$(basename "$home")"
    [[ -d "$home" && "$u" != "Shared" ]] || continue
    uid="$(id -u "$u" 2>/dev/null || echo 0)"; [[ "$uid" -ge 500 ]] || continue
    if sudo -u "$u" -H env HOME="$home" PATH="$PATH" bash -c "curl -fsSL '$INSTALLER' | bash" >/dev/null 2>&1; then
        log "wrappers mis à jour pour $u ($NEW)"
    else
        log "WARN installeur en échec pour $u"; ok=0
    fi
done
[[ "$ok" -eq 1 ]] && { mkdir -p "$(dirname "$STAMP")"; echo "$NEW" > "$STAMP"; }
SYNCEOF
chmod 755 "$SYNC"

cat > "$PLIST" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>$SYNC</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>3600</integer>
</dict></plist>
PLIST
chmod 644 "$PLIST"; chown root:wheel "$PLIST"

launchctl bootout system "$PLIST" >/dev/null 2>&1 || true
launchctl bootstrap system "$PLIST" >/dev/null 2>&1 || launchctl load -w "$PLIST" >/dev/null 2>&1 || true
echo "$(date) - LaunchDaemon $LABEL posé (sync des wrappers ~/bin toutes les heures)"
