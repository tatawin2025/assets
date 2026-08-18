#!/bin/zsh
# =============================================================================
# Tatawin — Setup Experience Script (zero-touch) — POSTE EMPLOYÉ TATAWIN
# Chantier 4. Déployer via Fleet (tenant/team MDM TATAWIN, tatawin.mdm.getprimo.com) :
#   Controls → Setup experience → Run script.
#
# Fait, au 1er boot d'un Mac neuf enrôlé :
#   - Wallpaper Tatawin
#   - Dock : Dia, Slack, 1Password, Claude, Tatawin
#   - Fuseau horaire automatique
#   - Node + bundle vault-mcp, puis (au 1er login) branchement de Claude au vault
#     via le token tat_live_ de l'employé (récupéré depuis 1Password).
#
# WiFi « Les Complices » = profil .mobileconfig séparé (Custom settings),
#   PAS dans ce script (cf. tools/fleet-mdm/profiles/tw-wifi-lescomplices.mobileconfig).
# Apps (1Password, Slack, AnyDesk, Claude Code, Dia) = install-during-setup Fleet.
#
# SHEBANG : Fleet n'accepte QUE #!/bin/sh ou #!/bin/zsh (bash rejeté → boucle 600s).
# Les sous-scripts user gardent #!/bin/bash (lancés par LaunchAgent, pas par Fleet).
#
# POSTURE : le token employé est minté MINIMAL (L1/lecture, deny-by-default C2).
# Le script installe le token tel quel — il ne pose aucun droit.
# =============================================================================

exec > /var/log/tatawin-setup.log 2>&1
echo "$(date) - Début setup Tatawin"

# === CONFIG =================================================================
# Wallpaper hébergé sur tatawin2025/assets (branche main).
WALLPAPER_URL="https://raw.githubusercontent.com/tatawin2025/assets/main/tatawin-wallpaper.jpg"
WALLPAPER_DIR="/Library/Desktop Pictures/Tatawin"
WALLPAPER_PATH="${WALLPAPER_DIR}/tatawin-wallpaper.jpg"
DESKTOPPR_URL="https://github.com/scriptingosx/desktoppr/releases/download/v0.5/desktoppr-0.5-218.pkg"
DESKTOPPR_PATH="/usr/local/bin/desktoppr"
DOCKUTIL_URL="https://github.com/kcrawford/dockutil/releases/download/3.0.2/dockutil-3.0.2.pkg"
DOCKUTIL_PATH="/usr/local/bin/dockutil"
NODE_PKG_URL="https://nodejs.org/dist/v20.17.0/node-v20.17.0.pkg"
# Bundle vault-mcp = release "vault-mcp" sur tatawin2025/assets (server.js + bootstrap, sans secret).
VAULT_MCP_DIST_URL="https://github.com/tatawin2025/assets/releases/download/vault-mcp/vault-mcp.tar.gz"
VAULT_MCP_DIR="/Library/Application Support/Tatawin/vault-mcp"
# Favoris Dia = tarball {dia-deploy-bookmarks.py + bookmarks/*.json} sur tatawin2025/assets (sans secret).
DIA_BM_DIST_URL="https://github.com/tatawin2025/assets/releases/download/dia-bookmarks/dia-bookmarks.tar.gz"
DIA_DIR="/Library/Application Support/Tatawin/dia"
# Guide de bienvenue = HTML autonome public (assets), ouvert au 1er login.
WELCOME_URL="https://raw.githubusercontent.com/tatawin2025/assets/main/welcome-tatawin.html"
WELCOME_PATH="/Library/Application Support/Tatawin/welcome.html"

# === ATTENTE RÉSEAU =========================================================
echo "$(date) - Attente réseau..."
MAX_WAIT=120; COUNT=0
while ! ping -c 1 -W 2 google.com &>/dev/null; do
    COUNT=$((COUNT + 1)); [[ $COUNT -ge $MAX_WAIT ]] && { echo "ERREUR : pas de réseau"; exit 1; }
    sleep 1
done
echo "$(date) - Réseau OK"

# === OUTILS (desktoppr, dockutil) ==========================================
if [[ ! -f "$DESKTOPPR_PATH" ]]; then
    curl -L -o /tmp/desktoppr.pkg "$DESKTOPPR_URL" && installer -pkg /tmp/desktoppr.pkg -target / && rm -f /tmp/desktoppr.pkg
fi
if [[ ! -f "$DOCKUTIL_PATH" ]]; then
    curl -L -o /tmp/dockutil.pkg "$DOCKUTIL_URL" && installer -pkg /tmp/dockutil.pkg -target / && rm -f /tmp/dockutil.pkg
fi

# === WALLPAPER (non fatal si l'asset n'est pas encore uploadé) ==============
mkdir -p "$WALLPAPER_DIR"
if curl -fL -o "$WALLPAPER_PATH" "$WALLPAPER_URL" && [[ -s "$WALLPAPER_PATH" ]]; then
    chmod 644 "$WALLPAPER_PATH"
    [[ -f "$DESKTOPPR_PATH" ]] && "$DESKTOPPR_PATH" "$WALLPAPER_PATH"
    cat > /Library/LaunchAgents/com.tatawin.wallpaper.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tatawin.wallpaper</string>
  <key>ProgramArguments</key><array>
    <string>/usr/local/bin/desktoppr</string>
    <string>/Library/Desktop Pictures/Tatawin/tatawin-wallpaper.jpg</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
    chmod 644 /Library/LaunchAgents/com.tatawin.wallpaper.plist
    chown root:wheel /Library/LaunchAgents/com.tatawin.wallpaper.plist
    echo "$(date) - Wallpaper OK"
else
    echo "$(date) - WARN : wallpaper indisponible (asset à uploader), on continue"
fi

# === APP TATAWIN (PWA → wrapper .app pour le dock) =========================
# Tatacontrol est une PWA (vite-plugin-pwa). On crée un wrapper .app léger qui
# ouvre app.tatawin.io — dock-able, déployable en zero-touch. Packaging natif
# (Electron/Tauri) = éventuel plus tard, pas nécessaire pour le dock.
if [[ ! -d "/Applications/Tatawin.app" ]]; then
    osacompile -o "/Applications/Tatawin.app" -e 'open location "https://app.tatawin.io"' 2>/dev/null \
      && echo "$(date) - Tatawin.app (web-app) créé" \
      || echo "$(date) - WARN : création Tatawin.app échouée"
fi

# === DOCK (au 1er login de chaque user) ====================================
cat > /Library/Scripts/tatawin-dock-setup.sh << 'DOCKSCRIPT'
#!/bin/bash
DOCKUTIL="/usr/local/bin/dockutil"
MARKER="$HOME/.tatawin-dock-configured"
[[ -f "$MARKER" ]] && exit 0
MAX_WAIT=120; COUNT=0
while ! pgrep -x "Dock" &>/dev/null || ! pgrep -x "Finder" &>/dev/null; do
    COUNT=$((COUNT + 1)); [[ $COUNT -ge $MAX_WAIT ]] && exit 1; sleep 1
done
sleep 5
"$DOCKUTIL" --remove all --no-restart
# Dia, Slack, 1Password, Claude (Desktop), Tatawin. On n'ajoute que les .app présents.
for app in "/Applications/Dia.app" "/Applications/Slack.app" "/Applications/1Password.app" "/Applications/Claude.app" "/Applications/Tatawin.app"; do
    [[ -d "$app" ]] && "$DOCKUTIL" --add "$app" --no-restart
done
defaults write com.apple.dock tilesize -integer 46
defaults write com.apple.dock show-recents -bool false
killall Dock
touch "$MARKER"
DOCKSCRIPT
chmod 755 /Library/Scripts/tatawin-dock-setup.sh
cat > /Library/LaunchAgents/com.tatawin.dock.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tatawin.dock</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>/Library/Scripts/tatawin-dock-setup.sh</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
chmod 644 /Library/LaunchAgents/com.tatawin.dock.plist
chown root:wheel /Library/LaunchAgents/com.tatawin.dock.plist
echo "$(date) - Dock configuré"

# === NODE + BUNDLE vault-mcp (sans secret) =================================
if ! command -v node &>/dev/null; then
    curl -L -o /tmp/node.pkg "$NODE_PKG_URL" && installer -pkg /tmp/node.pkg -target / && rm -f /tmp/node.pkg
fi
mkdir -p "$VAULT_MCP_DIR"
if curl -fL -o /tmp/vault-mcp.tar.gz "$VAULT_MCP_DIST_URL" && [[ -s /tmp/vault-mcp.tar.gz ]]; then
    tar -xzf /tmp/vault-mcp.tar.gz -C "$VAULT_MCP_DIR" --strip-components=1
    ( cd "$VAULT_MCP_DIR" && npm install --omit=dev --no-audit --no-fund ) || echo "WARN npm install"
    chmod -R 755 "$VAULT_MCP_DIR"
    echo "$(date) - Bundle vault-mcp déposé"
else
    echo "$(date) - WARN : bundle vault-mcp indisponible (à publier), Claude non branché"
fi
rm -f /tmp/vault-mcp.tar.gz

# === CLAUDE au vault (au 1er login, APRÈS login 1Password) =================
cat > /Library/Scripts/tatawin-claude-setup.sh << 'USERSCRIPT'
#!/bin/bash
exec >> "$HOME/Library/Logs/tatawin-claude-setup.log" 2>&1
MARKER="$HOME/.tatawin-claude-configured"
[[ -f "$MARKER" ]] && exit 0
VAULT_MCP_DIR="/Library/Application Support/Tatawin/vault-mcp"
# Convention figée (2026-08-17) : le token vault de l'employé est déposé par l'IT
# dans un COFFRE 1Password PARTAGÉ par employé (Luc + l'employé), item type
# « Identifiant d'API », nommé EXACTEMENT « Tatawin — Vault Token », champ « credential ».
# Coffre par employé = l'employé n'y voit qu'un seul item de ce nom (pas de collision
# du lookup `op item get`) et le token reste cloisonné. Ne PAS mettre dans un coffre
# d'équipe partagé (collision + fuite entre employés). Token minté dans Tatacontrol
# (bouton « Token vault » du panneau droits → create_app_token_for, affiché 1×).
OP_ITEM="Tatawin — Vault Token"
OP_FIELD="credential"
[[ -f "$VAULT_MCP_DIR/server.js" ]] || { echo "$(date) bundle absent, on retentera"; exit 0; }

# On branche le vault dans l'APP Claude Desktop (les employés n'utilisent pas le
# CLI). L'app lit ses serveurs MCP dans :
#   ~/Library/Application Support/Claude/claude_desktop_config.json
# Node (posé par le setup) fait tourner le serveur MCP.
NODE_BIN="$(command -v node || echo /usr/local/bin/node)"
[[ -x "$NODE_BIN" ]] || { echo "$(date) node absent, on retentera"; exit 0; }

OP_WAIT=0
until op whoami &>/dev/null; do
    OP_WAIT=$((OP_WAIT + 1)); [[ $OP_WAIT -ge 60 ]] && { echo "1Password pas connecté, retry prochain login"; exit 0; }
    sleep 30
done
TOKEN="$(op item get "$OP_ITEM" --fields "$OP_FIELD" --reveal 2>/dev/null)"
[[ "$TOKEN" == tat_live_* ]] || { echo "token 1Password introuvable, retry prochain login"; exit 0; }

# Merge NON destructif : préserve les autres serveurs MCP, (ré)écrit tatawin-vault.
CFG_DIR="$HOME/Library/Application Support/Claude"
CFG="$CFG_DIR/claude_desktop_config.json"
mkdir -p "$CFG_DIR"
CFG="$CFG" NODE_BIN="$NODE_BIN" SERVER_JS="$VAULT_MCP_DIR/server.js" VAULT_TOKEN="$TOKEN" /usr/bin/python3 <<'PY'
import json, os
cfg = os.environ["CFG"]
try:
    with open(cfg) as f: data = json.load(f)
    if not isinstance(data, dict): data = {}
except Exception:
    data = {}
data.setdefault("mcpServers", {})["tatawin-vault"] = {
    "command": os.environ["NODE_BIN"],
    "args": [os.environ["SERVER_JS"]],
    "env": {"VAULT_TOKEN": os.environ["VAULT_TOKEN"]},
}
tmp = cfg + ".tmp"
with open(tmp, "w") as f: json.dump(data, f, indent=2)
os.replace(tmp, cfg)
PY
chmod 600 "$CFG"
unset TOKEN VAULT_TOKEN
# L'app relit sa config au démarrage : si elle tourne déjà, on la relance.
if pgrep -x "Claude" >/dev/null 2>&1; then
    osascript -e 'quit app "Claude"' 2>/dev/null; sleep 2; open -a "Claude" 2>/dev/null
fi
touch "$MARKER"
echo "$(date) - Vault branché dans l'app Claude Desktop"
USERSCRIPT
chmod 755 /Library/Scripts/tatawin-claude-setup.sh
cat > /Library/LaunchAgents/com.tatawin.claude-setup.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tatawin.claude-setup</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>/Library/Scripts/tatawin-claude-setup.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>900</integer>
</dict></plist>
PLIST
chmod 644 /Library/LaunchAgents/com.tatawin.claude-setup.plist
chown root:wheel /Library/LaunchAgents/com.tatawin.claude-setup.plist
echo "$(date) - LaunchAgent Claude posé"

# === FAVORIS DIA (remplissage auto des profils créés à la main) ============
# L'employé crée ses profils Dia à la main (verrou compte Dia). Cet agent MERGE
# les favoris Tatawin dans chaque profil (par nom → référentiel), quand Dia est
# fermé. Idempotent, ne touche jamais aux favoris perso. Non fatal si absent.
mkdir -p "$DIA_DIR"
if curl -fL -o /tmp/dia-bm.tar.gz "$DIA_BM_DIST_URL" && [[ -s /tmp/dia-bm.tar.gz ]]; then
    tar -xzf /tmp/dia-bm.tar.gz -C "$DIA_DIR" --strip-components=1
    chmod -R 755 "$DIA_DIR"
    cat > /Library/LaunchAgents/com.tatawin.dia-sync.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tatawin.dia-sync</string>
  <key>ProgramArguments</key><array>
    <string>/usr/bin/python3</string>
    <string>/Library/Application Support/Tatawin/dia/dia-deploy-bookmarks.py</string>
    <string>--refs</string><string>/Library/Application Support/Tatawin/dia/bookmarks</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
</dict></plist>
PLIST
    chmod 644 /Library/LaunchAgents/com.tatawin.dia-sync.plist
    chown root:wheel /Library/LaunchAgents/com.tatawin.dia-sync.plist
    echo "$(date) - Favoris Dia : agent posé"
else
    echo "$(date) - WARN : tarball dia-bookmarks indisponible (à publier), favoris Dia non déployés"
fi
rm -f /tmp/dia-bm.tar.gz

# === GUIDE DE BIENVENUE (ouvert au 1er login) ==============================
# HTML autonome (aucune dépendance réseau une fois posé). Ouvert UNE SEULE fois
# au premier login de chaque employé = l'assistant de config des comptes.
mkdir -p "$(dirname "$WELCOME_PATH")"
if curl -fL -o "$WELCOME_PATH" "$WELCOME_URL" && [[ -s "$WELCOME_PATH" ]]; then
    chmod 644 "$WELCOME_PATH"
    cat > /Library/Scripts/tatawin-welcome.sh << 'WSCRIPT'
#!/bin/bash
MARKER="$HOME/.tatawin-welcome-shown"
[[ -f "$MARKER" ]] && exit 0
# attendre le bureau puis ouvrir le guide dans le navigateur par défaut
for i in $(seq 1 90); do pgrep -x Dock &>/dev/null && break; sleep 1; done
sleep 6
open "/Library/Application Support/Tatawin/welcome.html"
touch "$MARKER"
WSCRIPT
    chmod 755 /Library/Scripts/tatawin-welcome.sh
    cat > /Library/LaunchAgents/com.tatawin.welcome.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tatawin.welcome</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>/Library/Scripts/tatawin-welcome.sh</string></array>
  <key>RunAtLoad</key><true/>
</dict></plist>
PLIST
    chmod 644 /Library/LaunchAgents/com.tatawin.welcome.plist
    chown root:wheel /Library/LaunchAgents/com.tatawin.welcome.plist
    echo "$(date) - Guide de bienvenue posé (ouverture au 1er login)"
else
    echo "$(date) - WARN : guide de bienvenue indisponible (asset à publier)"
fi

# === FUSEAU HORAIRE AUTOMATIQUE ============================================
defaults write /var/db/locationd/Library/Preferences/ByHost/com.apple.locationd LocationServicesEnabled -int 1
chown -R _locationd:_locationd /var/db/locationd; killall locationd 2>/dev/null
defaults write /private/var/db/timed/Library/Preferences/com.apple.timed TMAutomaticTimeZoneEnabled -bool YES
chown -R _timed:_timed /private/var/db/timed; killall timed 2>/dev/null

echo "$(date) - Setup Tatawin terminé"
exit 0
