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
# 1Password CLI (op) = REQUIS : la commande interactive `tatawin-branch-vault` (lancée UNE fois
# par l'employé) récupère le token vault via `op item get` au premier plan (jamais via Fleet, jamais
# en agent — cf. boucle TCC résolue 19/08). Sans op, le vault ne se branche jamais. Pkg officiel.
OP_PKG_URL="https://cache.agilebits.com/dist/1P/op2/pkg/v2.34.0/op_apple_universal_v2.34.0.pkg"
# Bundle vault-mcp = release "vault-mcp" sur tatawin2025/assets (server.js + bootstrap, sans secret).
VAULT_MCP_DIST_URL="https://github.com/tatawin2025/assets/releases/download/vault-mcp/vault-mcp.tar.gz"
VAULT_MCP_DIR="/Library/Application Support/Tatawin/vault-mcp"
# Favoris Dia = tarball {dia-deploy-bookmarks.py + bookmarks/*.json} sur tatawin2025/assets (sans secret).
DIA_BM_DIST_URL="https://github.com/tatawin2025/assets/releases/download/dia-bookmarks/dia-bookmarks.tar.gz"
DIA_DIR="/Library/Application Support/Tatawin/dia"
# Guide de bienvenue = HTML autonome public (assets), ouvert au 1er login.
WELCOME_URL="https://raw.githubusercontent.com/tatawin2025/assets/main/welcome-tatawin.html"
WELCOME_PATH="/Library/Application Support/Tatawin/welcome.html"
# Dia + Claude Desktop = installés par FLEET (Software → Custom package). Les .pkg ont
# été buildés depuis les dmg officiels (Dia-latest.dmg ; Claude universal
# com.anthropic.claudefordesktop — le build validé, PAS le nest ni claude-science). Les
# deux s'auto-updatent ensuite via leur updater intégré. Retirés du script le 18/08 pour
# ne pas charger ~1 Go de download dans le budget ~600s du setup experience (risque timeout).
# Tatawin.app + Welcome guide.app = vraies apps natives (WKWebView, fenêtre standalone,
# menu Édition ⌘C/⌘V), pré-buildées + signées ad-hoc, hébergées sur assets. Remplace l'ancien
# wrapper osacompile qui ouvrait app.tatawin.io dans Safari.
# ⚠️ SOURCE + BUILD REPRODUCTIBLE : tools/primo/tatawin-app/{Tatawin,Welcome}.swift + build-apps.sh.
# Après toute modif d'un .swift : `./build-apps.sh --publish` (rebuild universal+signé + upload
# assets, avec garde-fou menu). Sans ça, le republish manuel ne prend pas et les onboardings
# réinstallent l'ancienne version cassée (cas vécu 20/08 : menu Édition perdu sur assets).
TATAWIN_APP_URL="https://github.com/tatawin2025/assets/releases/download/tatawin-app/tatawin-app.tar.gz"
# App native du guide de bienvenue (WKWebView du welcome.html local, icône 👋) posée sur le Bureau
WELCOME_APP_URL="https://github.com/tatawin2025/assets/releases/download/welcome-app/welcome-app.tar.gz"

# === ATTENTE RÉSEAU =========================================================
echo "$(date) - Attente réseau..."
MAX_WAIT=120; COUNT=0
while ! ping -c 1 -W 2 google.com &>/dev/null; do
    COUNT=$((COUNT + 1)); [[ $COUNT -ge $MAX_WAIT ]] && { echo "ERREUR : pas de réseau"; exit 1; }
    sleep 1
done
echo "$(date) - Réseau OK"

# === APPS ===================================================================
# 1Password/Slack/AnyDesk/Chrome/Drive/Granola/Todoist/Adobe = Fleet (install software).
# Dia + Claude Desktop = Fleet aussi (Custom package .pkg, cf. CONFIG plus haut).
# Le script n'installe plus aucune app directement → pas de gros download ici.

# === COMMAND LINE TOOLS (python3, requis par l'agent favoris Dia + config Claude) =
if ! /usr/bin/python3 --version &>/dev/null; then
    touch /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    CLT_LBL=$(softwareupdate -l 2>/dev/null | awk '/\* Label:.*Command Line Tools/{sub(/^ *\* Label: /,""); print}' | sort -V | tail -1)
    [[ -n "$CLT_LBL" ]] && softwareupdate -i "$CLT_LBL" --verbose
    rm -f /tmp/.com.apple.dt.CommandLineTools.installondemand.in-progress
    echo "$(date) - Command Line Tools (python3) : ${CLT_LBL:-non trouvé}"
fi

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
    if curl -fL -o /tmp/tatawin-app.tar.gz "$TATAWIN_APP_URL" && [[ -s /tmp/tatawin-app.tar.gz ]]; then
        tar -xzf /tmp/tatawin-app.tar.gz -C /Applications/
        xattr -dr com.apple.quarantine /Applications/Tatawin.app 2>/dev/null
        echo "$(date) - Tatawin.app (native WKWebView) installée"
    else
        echo "$(date) - WARN : Tatawin.app indisponible (asset à publier)"
    fi
    rm -f /tmp/tatawin-app.tar.gz
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
# Désactiver les widgets sur le bureau (comme Evaneos/Hublo/Homa…). Sur macOS 26,
# StandardHideWidgets/StageManagerHideWidgets ne suffisent PAS : il faut AUSSI
# HideDesktopWidgets (vérifié pilote M4 18/08). killall WindowManager pour appliquer.
defaults write com.apple.WindowManager StandardHideWidgets -bool true
defaults write com.apple.WindowManager StageManagerHideWidgets -bool true
defaults write com.apple.WindowManager HideDesktopWidgets -bool true
killall Dock
killall WindowManager 2>/dev/null
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
# Le pkg Node installe node+npm dans /usr/local/bin — pas forcément dans le PATH
# de la setup experience (root, PATH minimal). On l'ajoute pour que `npm install` marche.
export PATH="/usr/local/bin:$PATH"
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

# === 1Password CLI (op) — requis par l'agent Claude pour lire le token vault ===
if ! command -v op &>/dev/null && [[ ! -x /usr/local/bin/op ]]; then
    curl -fL -o /tmp/op.pkg "$OP_PKG_URL" && installer -pkg /tmp/op.pkg -target / && echo "$(date) - op (1Password CLI) installé"
    rm -f /tmp/op.pkg
fi

# === CLAUDE au vault (au 1er login, APRÈS login 1Password) =================
cat > /Library/Scripts/tatawin-claude-setup.sh << 'USERSCRIPT'
#!/bin/bash
# PATH minimal en LaunchAgent → on ajoute les emplacements de op/node/claude.
export PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$HOME/.local/bin"
exec >> "$HOME/Library/Logs/tatawin-claude-setup.log" 2>&1
# Cet agent installe l'OUTILLAGE (Claude Code + wrappers + commande de branchement).
# Il NE fait PLUS le branchement du vault : op en LaunchAgent ne peut pas obtenir le
# token de façon fiable (autorisations TCC macOS + accès CLI 1Password ne collent pas
# en non-interactif → prompt en boucle). Le branchement = commande interactive
# `tatawin-branch-vault` lancée par l'employé (Welcome guide, étape Claude).
MARKER="$HOME/.tatawin-tooling-installed"
[[ -f "$MARKER" ]] && exit 0
VAULT_MCP_DIR="/Library/Application Support/Tatawin/vault-mcp"
[[ -f "$VAULT_MCP_DIR/server.js" ]] || { echo "$(date) bundle absent, on retentera"; exit 0; }

# Node (posé par le setup) fait tourner le serveur MCP vault (utilisé par la commande
# de branchement interactive `tatawin-branch-vault`, posée plus bas).
NODE_BIN="$(command -v node || echo /usr/local/bin/node)"
[[ -x "$NODE_BIN" ]] || { echo "$(date) node absent, on retentera"; exit 0; }

# Claude Code (CLI) — installé sur TOUS les postes (choix 2026-08-18). Installeur
# natif officiel → ~/.local/bin/claude. Idempotent (skip si déjà présent). L'agent
# le branchera au vault plus bas (TARGETS inclut ~/.claude.json si claude présent).
if ! command -v claude &>/dev/null && [[ ! -x "$HOME/.local/bin/claude" ]]; then
    curl -fsSL https://claude.ai/install.sh | bash >/dev/null 2>&1 && echo "$(date) - Claude Code installé" || echo "$(date) WARN install Claude Code"
fi

# Wrappers Tatawin (gws/fleet/notion/primo/slack + op-cached) → ~/bin, via l'installeur
# publié (pose aussi jq + PATH). Aucun secret dans les scripts : ils lisent leur token
# dans 1Password « Tatawin / Interne » à l'exécution → INERTES tant que la personne n'y
# a pas accès. C'est l'appartenance à ce coffre 1Password (que gère l'IT), pas la présence
# des scripts, qui ouvre l'accès aux API clients.
if [[ ! -x "$HOME/bin/gws" || ! -x "$HOME/bin/fleet" ]]; then
    curl -fsSL "https://raw.githubusercontent.com/tatawin2025/assets/main/install-tatawin-cli.sh" | bash >/dev/null 2>&1 && echo "$(date) - wrappers Tatawin posés" || echo "$(date) WARN install wrappers"
fi

# Commande de branchement du vault (INTERACTIVE) → ~/bin. Le branchement N'EST PLUS
# fait par cet agent (op en arrière-plan = prompt TCC/1Password en boucle). L'employé
# lance `tatawin-branch-vault` UNE fois en Terminal (Welcome guide, étape Claude) : op
# tourne au premier plan, il approuve la/les demande(s) une fois, le vault est branché.
mkdir -p "$HOME/bin"
curl -fsSL "https://raw.githubusercontent.com/tatawin2025/assets/main/tatawin-branch-vault.sh" -o "$HOME/bin/tatawin-branch-vault" 2>/dev/null \
  && chmod +x "$HOME/bin/tatawin-branch-vault" && echo "$(date) - commande tatawin-branch-vault posée"

# Marker quand l'outillage est prêt (Claude Code + wrappers + commande de branchement)
# → l'agent s'arrête (plus aucun appel op, donc plus de prompt en boucle).
if { command -v claude &>/dev/null || [[ -x "$HOME/.local/bin/claude" ]]; } && [[ -x "$HOME/bin/gws" && -x "$HOME/bin/tatawin-branch-vault" ]]; then
    touch "$MARKER"
    echo "$(date) - outillage prêt — branchement vault = commande interactive tatawin-branch-vault"
fi
USERSCRIPT
chmod 755 /Library/Scripts/tatawin-claude-setup.sh
cat > /Library/LaunchAgents/com.tatawin.claude-setup.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tatawin.claude-setup</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>/Library/Scripts/tatawin-claude-setup.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>300</integer>
</dict></plist>
PLIST
chmod 644 /Library/LaunchAgents/com.tatawin.claude-setup.plist
chown root:wheel /Library/LaunchAgents/com.tatawin.claude-setup.plist
echo "$(date) - LaunchAgent Claude posé"

# === DOSSIER DE TRAVAIL + CLAUDE.md DE CADRAGE (enforcement one-way) ========
# Le poste accède au vault via MCP (pas de clone) : sans un CLAUDE.md chargé, Claude
# Code répond « brut ». On pose ~/tatawin/CLAUDE.md et on l'ENFORCE : agent qui le
# re-synchronise depuis la source canonique (assets) et le rend immuable (chflags uchg)
# → les modifs de l'employé sont écrasées, les MAJ du template se propagent. Sync one-way.
cat > /Library/Scripts/tatawin-claude-md-sync.sh << 'MDSYNC'
#!/bin/bash
export PATH="/usr/local/bin:/usr/bin:/bin"
DIR="$HOME/tatawin"; F="$DIR/CLAUDE.md"
URL="https://raw.githubusercontent.com/tatawin2025/assets/main/employe-CLAUDE.md"
mkdir -p "$DIR"
TMP="$(mktemp)"
if curl -fsSL "$URL" -o "$TMP" && [[ -s "$TMP" ]]; then
    if ! cmp -s "$TMP" "$F" 2>/dev/null; then
        chflags nouchg "$F" 2>/dev/null
        cp "$TMP" "$F"
    fi
    chflags uchg "$F" 2>/dev/null   # immuable : blocage des éditions casual (Finder/éditeur)
fi
rm -f "$TMP"
MDSYNC
chmod 755 /Library/Scripts/tatawin-claude-md-sync.sh
cat > /Library/LaunchAgents/com.tatawin.claude-md-sync.plist << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.tatawin.claude-md-sync</string>
  <key>ProgramArguments</key><array><string>/bin/bash</string><string>/Library/Scripts/tatawin-claude-md-sync.sh</string></array>
  <key>RunAtLoad</key><true/>
  <key>StartInterval</key><integer>600</integer>
</dict></plist>
PLIST
chmod 644 /Library/LaunchAgents/com.tatawin.claude-md-sync.plist
chown root:wheel /Library/LaunchAgents/com.tatawin.claude-md-sync.plist
echo "$(date) - LaunchAgent claude-md-sync posé (enforce ~/tatawin/CLAUDE.md)"

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
# 1) le HTML autonome (lu par l'app native)
curl -fL -o "$WELCOME_PATH" "$WELCOME_URL" && chmod 644 "$WELCOME_PATH"
# 2) l'app native du guide (icône 👋), stagée pour être posée sur le Bureau au 1er login
curl -fL -o /tmp/welcome-app.tar.gz "$WELCOME_APP_URL" && tar -xzf /tmp/welcome-app.tar.gz -C "/Library/Application Support/Tatawin/" && rm -f /tmp/welcome-app.tar.gz
if [[ -s "$WELCOME_PATH" && -d "/Library/Application Support/Tatawin/Welcome guide.app" ]]; then
    cat > /Library/Scripts/tatawin-welcome.sh << 'WSCRIPT'
#!/bin/bash
MARKER="$HOME/.tatawin-welcome-shown"
[[ -f "$MARKER" ]] && exit 0
# attendre le bureau
for i in $(seq 1 90); do pgrep -x Dock &>/dev/null && break; sleep 1; done
sleep 6
# poser l'app native du guide sur le Bureau (owned user, sans quarantaine), centrée
rm -rf "$HOME/Desktop/Welcome guide.app"
cp -R "/Library/Application Support/Tatawin/Welcome guide.app" "$HOME/Desktop/Welcome guide.app"
/usr/bin/xattr -dr com.apple.quarantine "$HOME/Desktop/Welcome guide.app" 2>/dev/null
/usr/sbin/chown -R "$(id -un):staff" "$HOME/Desktop/Welcome guide.app"
osascript -e 'tell application "Finder" to set b to bounds of window of desktop' \
          -e 'tell application "Finder" to set position of file "Welcome guide.app" of desktop to {((item 3 of b) div 2) - 40, ((item 4 of b) div 2) - 40}' 2>/dev/null
# ouvrir le guide une seule fois
open "$HOME/Desktop/Welcome guide.app"
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
