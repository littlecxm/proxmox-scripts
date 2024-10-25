#!/usr/bin/env bash

# This script automates the creation and registration of a Github self-hosted runner within a Proxmox LXC (Linux Container).
# The runner is based on Ubuntu 23.04. Before running the script, ensure you have your GH_TOKEN
# and the OWNERREPO (github owner/repository) available.

set -e

# Variables
GH_RUNNER_VER="2.320.0"
GH_RUNNER_URL="https://github.com/actions/runner/releases/download/v${GH_RUNNER_VER}/actions-runner-linux-x64-${GH_RUNNER_VER}.tar.gz"
TMPL_URL="http://download.proxmox.com/images/system/debian-12-standard_12.7-1_amd64.tar.zst"
PCTSIZE="20G"
PCT_ARCH="amd64"
PCT_CORES="4"
PCT_MEMORY="4096"
PCT_SWAP="4096"
PCT_STORAGE="local-lvm"
DEFAULT_IP_ADDR="192.168.1.101/24"
DEFAULT_GATEWAY="192.168.1.1"

# get latest version
GH_RUNNER_VER=$(curl --silent "https://api.github.com/repos/actions/runner/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v([^"]+)".*/\1/')
echo "Latest github runner version: $GH_RUNNER_VER"

# Ask for GitHub token and owner/repo if they're not set
if [ -z "$GH_TOKEN" ]; then
    read -r -p "Enter github token: " GH_TOKEN
    echo
fi
if [ -z "$OWNERREPO" ]; then
    read -r -p "Enter github owner/repo: " OWNERREPO
    echo
fi

# log function prints text in yellow
log() {
    local text="$1"
    echo -e "\033[33m$text\033[0m"
}

# Prompt for network details
read -r -e -p "Container Address IP (CIDR format) [$DEFAULT_IP_ADDR]: " input_ip_addr
IP_ADDR=${input_ip_addr:-$DEFAULT_IP_ADDR}
read -r -e -p "Container Gateway IP [$DEFAULT_GATEWAY]: " input_gateway
GATEWAY=${input_gateway:-$DEFAULT_GATEWAY}

# Get filename from the URLs
TMPL_FILE=$(basename $TMPL_URL)
GH_RUNNER_FILE=$(basename $GH_RUNNER_URL)

# Get the next available ID from Proxmox
PCTID=$(pvesh get /cluster/nextid)

# Download Ubuntu template
log "-- Downloading $TMPL_FILE template..."
curl -q -C - -o "$TMPL_FILE" $TMPL_URL

# Create LXC container
log "-- Creating LXC container with ID:$PCTID"
pct create "$PCTID" "$TMPL_FILE" \
    -arch $PCT_ARCH \
    -ostype debian \
    -hostname gh-runner-proxmox-$(openssl rand -hex 3) \
    -cores $PCT_CORES \
    -memory $PCT_MEMORY \
    -swap $PCT_SWAP \
    -storage $PCT_STORAGE \
    -features nesting=1,keyctl=1 \
    -net0 name=eth0,bridge=vmbr0,gw="$GATEWAY",ip="$IP_ADDR",type=veth

# Resize the container
log "-- Resizing container to $PCTSIZE"
pct resize "$PCTID" rootfs $PCTSIZE

# Start the container & run updates inside it
log "-- Starting container"
pct start "$PCTID"
sleep 10
log "-- Running updates"
pct exec "$PCTID" -- bash -c "apt update -y && apt install -y git curl zip \
liblttng-ust1 libkrb5-3 zlib1g libicu-dev libssl-dev \
&& passwd -d root"

# Get runner installation token
log "-- Getting runner installation token"
RES=$(curl -q -L \
    -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    https://api.github.com/repos/$OWNERREPO/actions/runners/registration-token)

RUNNER_TOKEN=$(echo $RES | grep -o '"token": "[^"]*' | grep -o '[^"]*$')

# Install and start the runner
log "-- Installing runner"
pct exec "$PCTID" -- bash -c "mkdir actions-runner && cd actions-runner &&\
    curl -o $GH_RUNNER_FILE -L $GH_RUNNER_URL &&\
    tar xzf $GH_RUNNER_FILE &&\
    RUNNER_ALLOW_RUNASROOT=1 ./config.sh --unattended --url https://github.com/$OWNERREPO --token $RUNNER_TOKEN &&\
    ./svc.sh install root &&\
    ./svc.sh start"

# Delete the downloaded Debian template
rm "$TMPL_FILE"
