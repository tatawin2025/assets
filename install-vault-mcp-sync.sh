#!/bin/bash
# install-vault-mcp-sync.sh — pose le mécanisme de mise à jour automatique du bundle vault-mcp.
#
# Pourquoi : le bundle (server.js, qui expose les outils MCP à Claude) n'était posé QU'AU
# provisioning. Un outil ajouté ensuite n'atteignait jamais un poste déjà en service — il
# fallait un `sudo cp` par machine. Le CLAUDE.md du poste, lui, avait déjà son LaunchAgent de
# sync. Ce script donne au bundle le même traitement.
#
# Ce qu'il installe :
#   /Library/Scripts/tatawin-vault-mcp-sync.sh          le script de sync
#   /Library/LaunchDaemons/com.tatawin.vault-mcp-sync.plist   toutes les heures + au boot
#
# LaunchDaemon (root) et non LaunchAgent : la cible appartient à root.
# Idempotent — le relancer ne fait que remettre les fichiers en place.
#
# Usage (une fois par poste, ou via setup-tatawin.sh) :
#   curl -fsSL https://raw.githubusercontent.com/tatawin2025/assets/main/install-vault-mcp-sync.sh | sudo bash
set -u

SYNC=/Library/Scripts/tatawin-vault-mcp-sync.sh
PLIST=/Library/LaunchDaemons/com.tatawin.vault-mcp-sync.plist
LABEL=com.tatawin.vault-mcp-sync

if [[ $EUID -ne 0 ]]; then
    echo "Ce script doit tourner en root (sudo) : la cible appartient à root." >&2
    exit 1
fi

mkdir -p /Library/Scripts

cat > "$SYNC" << 'SYNCEOF'
#!/bin/bash
# tatawin-vault-mcp-sync — maintient le bundle vault-mcp du poste aligné sur la release assets.
#
# Prudent par construction : au moindre doute il ne touche à rien. Un poste avec un bundle
# légèrement ancien reste utilisable ; un poste avec un server.js corrompu ne l'est plus.
set -u
export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

DIR="/Library/Application Support/Tatawin/vault-mcp"
URL="https://github.com/tatawin2025/assets/releases/download/vault-mcp/vault-mcp.tar.gz"
STAMP="$DIR/.bundle-sha256"
LOG="/var/log/tatawin-vault-mcp-sync.log"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

# Poste non provisionné : ce n'est pas à ce script de l'installer.
[[ -d "$DIR" ]] || exit 0

TMP="$(mktemp -d)" || exit 0
trap 'rm -rf "$TMP"' EXIT

curl -fsSL --max-time 60 -o "$TMP/bundle.tar.gz" "$URL" 2>/dev/null \
    || { log "téléchargement impossible — bundle inchangé"; exit 0; }
[[ -s "$TMP/bundle.tar.gz" ]] || { log "archive vide — bundle inchangé"; exit 0; }

NEW="$(shasum -a 256 "$TMP/bundle.tar.gz" | awk '{print $1}')"
OLD="$(cat "$STAMP" 2>/dev/null || true)"
[[ "$NEW" == "$OLD" ]] && exit 0          # déjà à jour, cas courant

tar -xzf "$TMP/bundle.tar.gz" -C "$TMP" --strip-components=1 2>/dev/null \
    || { log "archive illisible — bundle inchangé"; exit 0; }
[[ -s "$TMP/server.js" ]] || { log "server.js absent de l'archive — bundle inchangé"; exit 0; }

# Garde-fou : on ne remplace jamais par un fichier qui ne parse pas.
# (package.json est extrait à côté, donc node le lit bien comme un module ES.)
node --check "$TMP/server.js" 2>/dev/null \
    || { log "server.js invalide — bundle inchangé"; exit 0; }

cp -p "$DIR/server.js" "$DIR/server.js.prev" 2>/dev/null || true
for f in server.js package.json package-lock.json bootstrap-CLAUDE.md; do
    [[ -f "$TMP/$f" ]] && cp "$TMP/$f" "$DIR/$f"
done

( cd "$DIR" && npm install --omit=dev --no-audit --no-fund >/dev/null 2>&1 ) \
    || log "WARN npm install a échoué — dépendances peut-être en retard"

chmod -R 755 "$DIR"
echo "$NEW" > "$STAMP"
log "bundle mis à jour ($NEW) — actif au prochain lancement de Claude Code"
SYNCEOF

chmod 755 "$SYNC"

cat > "$PLIST" << PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>${SYNC}</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>3600</integer>
</dict></plist>
PLISTEOF

chmod 644 "$PLIST"
chown root:wheel "$PLIST"

launchctl bootout "system/${LABEL}" 2>/dev/null || true
launchctl bootstrap system "$PLIST" 2>/dev/null || launchctl load -w "$PLIST" 2>/dev/null

echo "Sync du bundle vault-mcp installée — vérification toutes les heures et au démarrage."
echo "Journal : /var/log/tatawin-vault-mcp-sync.log"
