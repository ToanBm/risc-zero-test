#!/bin/bash

# check rust installation - edited
check_rust() {
    if ! rustup --version &> /dev/null; then
        echo "Rust not found. Installing now..."
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source $HOME/.cargo/env
        rustup --version
        echo "Rust has been installed."
    else
        echo "Rust is already installed."
    fi
}

# check forge installation, suggest installation if not found - edited
check_foundry() {
    if ! foundryup --version &> /dev/null; then
        echo "Foundry not found. Installing now..."
        curl -L https://foundry.paradigm.xyz | bash
        source /home/codespace/.bashrc # Dùng trên codespace (VPS thì edit lại)
        foundryup
        echo "Foundry has been installed."
    else
        echo "Foundry is already installed."
    fi
}

# Install rzup
curl -L https://risczero.com/install | bash
source ~/.bashrc
rzup install

# function to get risc0 version
get_risc0_version() {
    RISC0_VERSION=$(cargo risczero --version 2>/dev/null | awk '{print $2}' || echo "")
    if [[ -z "$RISC0_VERSION" ]]; then
        echo "cargo risczero not found. Please see installation instructions by visiting: https://dev.risczero.com/api/zkvm/install"
        exit 1
    fi
    echo "detected risc0 version: $RISC0_VERSION"

    # map version to branch
    if [[ "$RISC0_VERSION" =~ ^1\.1\. ]]; then
        BRANCH="release-1.1"
    else
        echo "unsupported risc0 version. version 1.1 is supported"
        BRANCH=""
    fi
}

select_branch() {
    get_risc0_version
    
    # NOTE: Only 1.1 is currently supported.

    BRANCH="release-1.1"
    echo "selected branch: ${BRANCH:?}"

    # Logic below can be used when more than one version is supported.
    #if [[ -n "$BRANCH" ]]; then
    #    echo "using branch: $BRANCH based on installed risc0 version"
    #    read -p "do you want to use a different release? (y/N): " change_branch
    #    if [[ "$change_branch" =~ ^[Yy]$ ]]; then
    #        BRANCH=""
    #    else
    #        echo "selected branch: $BRANCH"
    #        return
    #    fi
    #fi
    #
    #while [[ -z "$BRANCH" ]]; do
    #    echo "select the branch you want to use:"
    #    echo "1) release-1.1"
    #    read -p "enter 1: " choice
    #    case $choice in
    #        1) BRANCH="release-1.1"; break;;
    #        *) echo "invalid option. please try again.";;
    #    esac
    #done
    #
    #echo "selected branch: $BRANCH"
}

get_folder_name() {
    while true; do
        read -p "Enter the name for the project folder: " FOLDER_NAME
        if [[ -n "$FOLDER_NAME" ]]; then
            break
        else
            echo "Folder name cannot be empty. Please try again."
        fi
    done
}

if [ "$(uname)" = "Darwin" ]; then
  # MacOS expects an argument for `-i` (empty string is used for no backup)
  sed_i() {
    sed -i '' "$@"
  }
else
  # Linux accepts `-i` without an argument
  sed_i() {
    sed -i "$@"
  }
fi

check_rust
check_foundry
select_branch
get_folder_name

set -e  # exit on any error

# clone the repo without checking out files
git clone -b $BRANCH https://github.com/risc0/risc0-ethereum.git "$FOLDER_NAME"
cd "$FOLDER_NAME"

# set up sparse checkout for 'examples/erc20-counter' 
git sparse-checkout set examples/erc20-counter 
git checkout

# move erc20-counter out of examples/
mv examples/erc20-counter ./
rm -rf examples/
find . -maxdepth 1 -type f -delete

# move ALL contents of erc20-counter up one level, including hidden files
mv erc20-counter/{.,}* ./ 2>/dev/null || true

# remove the erc20-counter directory
rm -r erc20-counter
echo "done. erc20-counter contents and steel directory are now in the root of $FOLDER_NAME."

# update Cargo.toml files with git dependencies
## apps requires Steel to have "features = ["host"]"
find . -name Cargo.toml -type f | while read -r file; do
    if [[ "$file" == *"/apps/"* ]]; then
        sed_i \
            -e "s|^risc0-build-ethereum = .*$|risc0-build-ethereum = { git = \"https://github.com/risc0/risc0-ethereum\", branch = \"$BRANCH\" }|" \
            -e "s|^risc0-ethereum-contracts = .*$|risc0-ethereum-contracts = { git = \"https://github.com/risc0/risc0-ethereum\", branch = \"$BRANCH\" }|" \
            -e "s|^risc0-steel = .*$|risc0-steel = { git = \"https://github.com/risc0/risc0-ethereum\", branch = \"$BRANCH\", features = [\"host\"] }|" \
            "$file"
    else
        sed_i \
            -e "s|^risc0-build-ethereum = .*$|risc0-build-ethereum = { git = \"https://github.com/risc0/risc0-ethereum\", branch = \"$BRANCH\" }|" \
            -e "s|^risc0-ethereum-contracts = .*$|risc0-ethereum-contracts = { git = \"https://github.com/risc0/risc0-ethereum\", branch = \"$BRANCH\" }|" \
            -e "s|^risc0-steel = .*$|risc0-steel = { git = \"https://github.com/risc0/risc0-ethereum\", branch = \"$BRANCH\" }|" \
            "$file"
    fi
    echo "updated $file"
done
echo "all Cargo.toml files have been updated with git dependencies."

# update the foundry.toml file to use the lib directory and disable auto_detect_remappings to avoid conflicts
if [ -f "foundry.toml" ]; then
    sed_i \
        -e 's|libs = \["../../lib", "../../contracts/src"\]|libs = ["lib"]|' \
        -e '/\[profile\.default\]/a\'$'\n''auto_detect_remappings = false' \
        foundry.toml
    echo "updated foundry.toml"
else
    echo "foundry.toml not found"
fi

# forge dependencies/remappings
# remove git conflicts
rm -rf .git
git init

## create lib directory if it doesn't exist
mkdir -p lib

## initialize submodules for forge remappings
git submodule init
git submodule add https://github.com/foundry-rs/forge-std lib/forge-std
git submodule add https://github.com/OpenZeppelin/openzeppelin-contracts lib/openzeppelin-contracts
git submodule add https://github.com/risc0/risc0-ethereum lib/risc0-ethereum
git submodule update --init --recursive --quiet

# update remappings in remappings.txt
if [ -f "remappings.txt" ]; then
    sed_i \
        -e 's|forge-std/=../../lib/forge-std/src/|forge-std/=lib/forge-std/src/|' \
        -e 's|openzeppelin/=../../lib/openzeppelin-contracts/|openzeppelin/=lib/openzeppelin-contracts/|' \
        -e 's|risc0/=../../contracts/src/|risc0/=lib/risc0-ethereum/contracts/src/|' \
        remappings.txt
    echo "openzeppelin-contracts/=lib/openzeppelin-contracts/contracts" >> remappings.txt
    echo "updated remappings in remappings.txt"
else
    echo "remappings.txt not found"
fi

echo "done. $FOLDER_NAME is ready for development."
