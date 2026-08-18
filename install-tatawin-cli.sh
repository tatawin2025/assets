#!/usr/bin/env bash
# =============================================================================
# install-tatawin-cli.sh — pose les wrappers Tatawin dans ~/bin.
#
# Wrappers : gws, fleet, notion, primo, slack (+ op-cached, _lib/op-cache.sh).
# Chacun appelle une edge function proxy (auth + allowlist + audit) et lit son
# token app dans 1Password (coffre « Tatawin / Interne ») à l'exécution.
#
# AUCUN SECRET dans les scripts (juste l'URL Supabase + l'anon key publique) :
# le package est donc hébergé en clair sur tatawin2025/assets. Les wrappers sont
# INERTES tant que la personne n'a pas accès aux items token dans 1Password —
# c'est là (appartenance au coffre « Tatawin / Interne ») que se joue l'accès
# réel aux API clients, pas dans la présence des scripts.
#
# Prérequis : op (1Password CLI) installé + intégration app activée. jq est
# fourni par macOS 15+ ; sinon on pose un binaire statique dans ~/bin.
#
# Usage : curl -fsSL <raw>/install-tatawin-cli.sh | bash
# =============================================================================
set -euo pipefail

PKG_URL="https://github.com/tatawin2025/assets/releases/download/tatawin-cli/tatawin-cli.tar.gz"

mkdir -p "$HOME/bin"
curl -fsSL "$PKG_URL" -o /tmp/tatawin-cli.tar.gz
tar -xzf /tmp/tatawin-cli.tar.gz -C "$HOME/bin"
rm -f /tmp/tatawin-cli.tar.gz
for w in gws fleet notion primo slack op-cached; do
  [[ -f "$HOME/bin/$w" ]] && chmod +x "$HOME/bin/$w"
done
echo "→ wrappers posés dans ~/bin"

# PATH : on écrit dans ~/.zshenv (lu par TOUS les shells zsh, y compris les shells
# non-interactifs de Claude Code — .zshrc n'est lu que par les shells interactifs,
# d'où des « command not found » sinon). On couvre ~/bin (wrappers) + ~/.local/bin (claude).
if ! grep -q 'HOME/bin' "$HOME/.zshenv" 2>/dev/null; then
  echo 'export PATH="$HOME/bin:$HOME/.local/bin:$PATH"' >> "$HOME/.zshenv"
  echo "→ ~/bin + ~/.local/bin ajoutés au PATH (.zshenv)"
fi

# jq : macOS 15+ le fournit ; sinon binaire statique dans ~/bin
if ! command -v jq >/dev/null 2>&1 && [[ ! -x /usr/bin/jq ]]; then
  A="$(uname -m)"; [[ "$A" == "arm64" ]] && JQA="arm64" || JQA="amd64"
  curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-macos-$JQA" -o "$HOME/bin/jq" \
    && chmod +x "$HOME/bin/jq" && echo "→ jq posé dans ~/bin"
fi

# op : session (intégration app 1Password → Touch ID)
if command -v op >/dev/null 2>&1; then
  op whoami >/dev/null 2>&1 || eval "$(op signin --account tatawin.1password.eu 2>/dev/null)" || true
else
  echo "⚠ op (1Password CLI) absent — installe-le d'abord (le zero-touch le pose via OP_PKG_URL)."
fi

echo "✅ Terminé. Ouvre un nouveau terminal (ou 'source ~/.zshrc'), puis teste :"
echo "     gws tatawin directory GET '/groups?maxResults=1'"
echo "   Accès effectif = être membre du coffre 1Password « Tatawin / Interne »."
