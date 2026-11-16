#!/bin/bash
# =============================================================================
# tatawin-branch-vault — pose ton token personnel pour les outils Tatawin (~/bin).
#
# À lancer UNE fois, en Terminal (le Welcome guide te le demande à l'étape Claude).
#
# Depuis le 16/11/2026, le VAULT ne passe plus par cette commande : il se branche
# dans Claude comme connecteur (claude.ai › Personnaliser › Connecteurs › Vault
# Tatawin › Connecter, avec ton compte Google). Cette commande ne sert plus qu'aux
# OUTILS en ligne de commande (gws, fleet, primo, msgraph, slack, notion, abm) :
# elle lit ton token personnel `tat_live_…` dans 1Password et le dépose dans
# ~/.config/tatawin/token (lisible par toi seul). Elle ne touche plus aux configs
# de Claude (plus de serveur MCP local).
#
# POURQUOI en interactif : `op` lancé en arrière-plan ne peut pas obtenir le token
# de façon fiable (autorisation macOS + 1Password en boucle). Ici, op tourne au
# premier plan : tu approuves la/les demande(s) UNE fois.
#
# Source : tools/primo/scripts/tatawin-branch-vault.sh (vault). Publication :
# tatawin2025/assets/tatawin-branch-vault.sh. Chantier :
# projects/todo/2026-11-16-vault-connecteur-distant.md.
# =============================================================================
set -euo pipefail
export PATH="/usr/local/bin:/usr/bin:/bin:$HOME/.local/bin"

OP_ITEM="Tatawin — Vault Token"
OP_FIELD="credential"
DEST_DIR="$HOME/.config/tatawin"
DEST="$DEST_DIR/token"

command -v op >/dev/null || { echo "❌ op (1Password CLI) absent — préviens l'IT."; exit 1; }

echo "→ Connexion à 1Password (approuve la/les demande(s) qui s'affichent)…"
op whoami >/dev/null 2>&1 || eval "$(op signin --account tatawin.1password.eu)"

echo "→ Récupération de ton token personnel…"
TOKEN="$(op item get "$OP_ITEM" --fields "$OP_FIELD" --reveal)"
[[ "$TOKEN" == tat_live_* ]] || { echo "❌ Token introuvable — vérifie que 1Password est connecté + l'intégration CLI active, et que l'IT a déposé ton token."; exit 1; }

( umask 077; mkdir -p "$DEST_DIR"; printf '%s\n' "$TOKEN" > "$DEST.tmp"; mv -f "$DEST.tmp" "$DEST" )
chmod 600 "$DEST"
unset TOKEN
touch "$HOME/.tatawin-claude-configured"

echo "✅ Token posé pour les outils Tatawin (~/bin)."
echo "   Test : fleet tatawin GET '/hosts?per_page=1'"
echo ""
echo "Pour le VAULT dans Claude : claude.ai › Personnaliser › Connecteurs › Vault Tatawin › Connecter."
