#!/usr/bin/env bash
set -e

# oh-my-zsh for the runtime user, cloned the way its installer does but
# without the chsh/RUNZSH prompts. Its template ~/.zshrc also keeps zsh's
# first-run wizard from firing for a non-root user.
git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /home/ubuntu/.oh-my-zsh
cp /home/ubuntu/.oh-my-zsh/templates/zshrc.zsh-template /home/ubuntu/.zshrc
chown -R ubuntu:ubuntu /home/ubuntu/.oh-my-zsh /home/ubuntu/.zshrc

chsh -s /bin/zsh ubuntu
