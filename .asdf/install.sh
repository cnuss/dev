#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.asdf/shims:$HOME/go/bin:${PATH}"

cp "$SCRIPT_DIR/.tool-versions" "$HOME/.tool-versions"
cp "$SCRIPT_DIR/.plugin-versions" "$HOME/.plugin-versions"

go install github.com/asdf-vm/asdf/cmd/asdf@v0.18.1
asdf plugin add asdf-plugin-manager https://github.com/asdf-community/asdf-plugin-manager.git
asdf install asdf-plugin-manager 1.5.0
asdf-plugin-manager add-all
asdf install

# Set all installed versions globally
while IFS=' ' read -r tool version; do
  asdf set -u "$tool" "$version"
done < "$SCRIPT_DIR/.tool-versions"