#!/bin/bash
# =============================================================================
# tatawin-branch-vault — branche le vault Tatawin dans Claude Desktop + Claude Code.
#
# À lancer UNE fois, en Terminal (le Welcome guide te le demande à l'étape Claude).
# POURQUOI en interactif : `op` lancé par un agent en arrière-plan ne peut pas obtenir
# le token de façon fiable — macOS (« op souhaite accéder aux données d'autres apps »)
# ET l'app 1Password (« autoriser l'accès CLI ») demandent une autorisation qui NE COLLE
# PAS en contexte non-interactif → la prompt revient en boucle. Ici, op tourne au premier
# plan : tu approuves la/les demande(s) UNE fois, le token est lu, le vault est branché,
# et c'est fini (un marker empêche toute relance).
# =============================================================================
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

VAULT_MCP_DIR="/Library/Application Support/Tatawin/vault-mcp"
OP_ITEM="Tatawin — Vault Token"
OP_FIELD="credential"
NODE_BIN="$(command -v node || echo /usr/local/bin/node)"

command -v op >/dev/null || { echo "❌ op (1Password CLI) absent — préviens l'IT."; exit 1; }
[[ -f "$VAULT_MCP_DIR/server.js" ]] || { echo "❌ Bundle vault-mcp absent — reboote une fois puis relance."; exit 1; }

echo "→ Connexion à 1Password (approuve la/les demande(s) qui s'affichent)…"
op whoami >/dev/null 2>&1 || eval "$(op signin --account tatawin.1password.eu)"

echo "→ Récupération de ton token vault…"
TOKEN="$(op item get "$OP_ITEM" --fields "$OP_FIELD" --reveal)"
[[ "$TOKEN" == tat_live_* ]] || { echo "❌ Token introuvable — vérifie que 1Password est connecté + l'intégration CLI active, et que l'IT a déposé ton token."; exit 1; }

# Merge non destructif dans les configs Claude présentes : Desktop toujours ; Claude Code si installé.
CFG_DIR="$HOME/Library/Application Support/Claude"; mkdir -p "$CFG_DIR"
TARGETS="$CFG_DIR/claude_desktop_config.json"
if command -v claude >/dev/null 2>&1 || [[ -x "$HOME/.local/bin/claude" ]]; then
    TARGETS="$TARGETS
$HOME/.claude.json"
fi
NODE_BIN="$NODE_BIN" SERVER_JS="$VAULT_MCP_DIR/server.js" VAULT_TOKEN="$TOKEN" TARGETS="$TARGETS" /usr/bin/python3 - <<'PY'
import json, os
entry = {"command": os.environ["NODE_BIN"], "args": [os.environ["SERVER_JS"]], "env": {"VAULT_TOKEN": os.environ["VAULT_TOKEN"]}}
for cfg in os.environ["TARGETS"].splitlines():
    cfg = cfg.strip()
    if not cfg: continue
    try:
        with open(cfg) as f: data = json.load(f)
        if not isinstance(data, dict): data = {}
    except Exception:
        data = {}
    data.setdefault("mcpServers", {})["tatawin-vault"] = entry
    tmp = cfg + ".tmp"
    with open(tmp, "w") as f: json.dump(data, f, indent=2)
    os.replace(tmp, cfg)
    os.chmod(cfg, 0o600)
PY
unset TOKEN
touch "$HOME/.tatawin-claude-configured"
if pgrep -x "Claude" >/dev/null 2>&1; then
    osascript -e 'quit app "Claude"' 2>/dev/null; sleep 2; open -a "Claude" 2>/dev/null
fi
echo "✅ Vault branché dans Claude Desktop et Claude Code. Tu peux fermer ce Terminal."
