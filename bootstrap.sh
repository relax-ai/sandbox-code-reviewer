#!/bin/bash
# bootstrap.sh — install the toolchain the PR-review agent needs inside a Relax
# sandbox. Invoked by deploy.sh via the /execute endpoint.
#
# The sandbox base image is Ubuntu 22.04 and already ships Node 22, npm, git,
# jq, and curl. Isolation and network egress are handled by the sandbox itself,
# so this script only installs what the base image lacks and verifies the
# result. There is no user creation, iptables, or secret-shredding here — that
# was Civo-specific and is now the sandbox's job.
#
# Environment (injected at sandbox creation by deploy.sh):
#   CLAUDE_CODE_VERSION - npm version of Claude Code to install
#
# PINNED ON PURPOSE. Bump only after re-testing inside the sandbox.
set -euo pipefail

export HOME=/root
mkdir -p /workspace

# gh CLI (not in the Ubuntu 22.04 archive) from GitHub's official apt source.
# Retry the keyring fetch — DNS can be flaky on a fresh sandbox.
mkdir -p -m 755 /etc/apt/keyrings
for i in 1 2 3 4 5; do
  curl -fsSL --retry 3 --retry-delay 2 \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && break
  echo "gh keyring attempt ${i} failed, sleeping..."
  sleep 5
done
chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  > /etc/apt/sources.list.d/github-cli.list
apt-get update -y
apt-get install -y gh

npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

node --version
gh --version | head -1
claude --version
