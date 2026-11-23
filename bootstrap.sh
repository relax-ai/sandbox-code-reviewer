#!/bin/bash
# bootstrap.sh — install what the review agent needs inside a relaxAI
# sandbox. Uploaded and run (daemonized) by `./demo.sh up`.
#
# The sandbox base image is Ubuntu 22.04 and already ships Node 22, npm, git,
# jq, and curl. Isolation and network egress are handled by the sandbox itself,
# so this script only installs Claude Code and verifies the result.
#
# Environment (injected at sandbox creation by demo.sh):
#   CLAUDE_CODE_VERSION - npm version of Claude Code to install
#
# PINNED ON PURPOSE. Bump only after re-testing inside the sandbox.
set -euo pipefail

export HOME=/root
mkdir -p /workspace

npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

node --version
git --version
claude --version
