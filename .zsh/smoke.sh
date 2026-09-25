#!/usr/bin/env bash
set -e

[ "$(getent passwd ubuntu | cut -d: -f7)" = /bin/zsh ]
[ -O /home/ubuntu/.zshrc ] || [ "$(stat -c %U /home/ubuntu/.zshrc)" = ubuntu ]

# An interactive zsh as ubuntu must load oh-my-zsh (and not hit the wizard).
sudo -Hu ubuntu zsh -ic 'echo "omz=$ZSH"' | grep -q '^omz=/home/ubuntu/.oh-my-zsh$'
