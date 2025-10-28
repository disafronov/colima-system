#!/bin/sh
# setup.sh — configures Colima as a system daemon on macOS.
# Runs without GUI, creates hidden colima user and configures launchd units.
# Author: Dmitrii Safronov <dhameoelin@gmail.com>

set -e

################################################################################

set -a
# <configuration
# names
COLIMA_DAEMON_LOG_NAME="daemon"
COLIMA_PERMISSIONS_LOG_NAME="permissions"
COLIMA_DAEMON_PLIST_NAME="colima.daemon"
COLIMA_PERMISSIONS_PLIST_NAME="colima.socket.permissions"

# user/paths
COLIMA_USER="colima"
COLIMA_GROUP="docker"
COLIMA_HOME="/var/lib/colima"
COLIMA_BIN="/opt/homebrew/bin/colima"

# logs
COLIMA_DAEMON_LOG_OUT="${COLIMA_HOME}/${COLIMA_DAEMON_LOG_NAME}.log"
COLIMA_DAEMON_LOG_ERR="${COLIMA_HOME}/${COLIMA_DAEMON_LOG_NAME}.err"
COLIMA_PERMISSIONS_LOG_OUT="${COLIMA_HOME}/${COLIMA_PERMISSIONS_LOG_NAME}.log"
COLIMA_PERMISSIONS_LOG_ERR="${COLIMA_HOME}/${COLIMA_PERMISSIONS_LOG_NAME}.err"
# configuration>
set +a

# Make exported configuration immutable
readonly \
    COLIMA_DAEMON_LOG_NAME COLIMA_PERMISSIONS_LOG_NAME \
    COLIMA_DAEMON_PLIST_NAME COLIMA_PERMISSIONS_PLIST_NAME \
    COLIMA_USER COLIMA_GROUP COLIMA_HOME COLIMA_BIN \
    COLIMA_DAEMON_LOG_OUT COLIMA_DAEMON_LOG_ERR \
    COLIMA_PERMISSIONS_LOG_OUT COLIMA_PERMISSIONS_LOG_ERR

################################################################################

# <internal
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
LAUNCHD_DIR="/Library/LaunchDaemons"

COLIMA_DAEMON_PLIST_TEMPLATE="${SCRIPT_DIR}/${COLIMA_DAEMON_PLIST_NAME}.plist"
COLIMA_DAEMON_PLIST_LAUNCHD="${LAUNCHD_DIR}/${COLIMA_DAEMON_PLIST_NAME}.plist"
COLIMA_PERMISSIONS_PLIST_TEMPLATE="${SCRIPT_DIR}/${COLIMA_PERMISSIONS_PLIST_NAME}.plist"
COLIMA_PERMISSIONS_PLIST_LAUNCHD="${LAUNCHD_DIR}/${COLIMA_PERMISSIONS_PLIST_NAME}.plist"

DOCKER_SOCK="/var/run/docker.sock"
# internal>

# Ensure plist names are exported for envsubst
export COLIMA_DAEMON_PLIST_NAME COLIMA_PERMISSIONS_PLIST_NAME

# Make internal variables immutable
readonly SCRIPT_DIR LAUNCHD_DIR DOCKER_SOCK \
    COLIMA_DAEMON_PLIST_TEMPLATE COLIMA_DAEMON_PLIST_LAUNCHD \
    COLIMA_PERMISSIONS_PLIST_TEMPLATE COLIMA_PERMISSIONS_PLIST_LAUNCHD

################################################################################

# Log function - POSIX compliant
log_info() {
    echo "$*"
}

log_error() {
    echo "$*" >&2
}

################################################################################

# Render plist from template, set ownership/permissions, validate
gen_plist() {
    tpl_path="$1"
    out_path="$2"
    envsubst < "$tpl_path" > "$out_path"
    chown root:wheel "$out_path"
    chmod 644 "$out_path"
    if ! plutil -lint "$out_path" >/dev/null 2>&1; then
        log_error "[-] Invalid plist: $out_path"
        exit 1
    fi
}

################################################################################

# Check if running on macOS as root
check_prerequisites() {
    if [ "$(uname -s)" != "Darwin" ]; then
        log_error "[-] This script is for macOS only"
        exit 1
    fi
    
    if [ "$(id -u)" -ne 0 ]; then
        log_error "[-] This script must be run as root"
        exit 1
    fi
    
    if ! command -v "${COLIMA_BIN}" >/dev/null 2>&1; then
        log_error "[-] Colima not found at ${COLIMA_BIN}. Please install it first."
        exit 1
    fi
    
    if [ ! -f "${COLIMA_DAEMON_PLIST_TEMPLATE}" ]; then
        log_error "[-] Colima plist template not found at ${COLIMA_DAEMON_PLIST_TEMPLATE}"
        exit 1
    fi
    
    if [ ! -f "${COLIMA_PERMISSIONS_PLIST_TEMPLATE}" ]; then
        log_error "[-] Permissions plist not found at ${COLIMA_PERMISSIONS_PLIST_TEMPLATE}"
        exit 1
    fi
    
    if ! command -v envsubst >/dev/null 2>&1; then
        log_error "[-] envsubst not found. Please install gettext."
        exit 1
    fi
    
    log_info "[=] Prerequisites check passed"
}

################################################################################

# Check if group exists
group_exists() {
    dscl . -read /Groups/"${COLIMA_GROUP}" >/dev/null 2>&1
}

# Create colima group if it doesn't exist
group_create() {
    if group_exists; then
        log_info "[=] Group ${COLIMA_GROUP} already exists"
        return 0
    fi
    
    log_info "[+] Creating group ${COLIMA_GROUP}"
    
    # Get next available GID
    MAX_GID=$(dscl . -list /Groups PrimaryGroupID | awk '{print $2}' | sort -n | tail -1)
    NEW_GID=$((MAX_GID + 1))
    
    # Create group
    dscl . -create /Groups/"${COLIMA_GROUP}"
    dscl . -create /Groups/"${COLIMA_GROUP}" PrimaryGroupID "${NEW_GID}"
    
    log_info "[+] Group ${COLIMA_GROUP} created with GID ${NEW_GID}"
}

# Get group GID
group_get_gid() {
    dscl . -read /Groups/"${COLIMA_GROUP}" PrimaryGroupID | awk '{print $2}'
}

# Check if user exists
user_exists() {
    dscl . -read /Users/"${COLIMA_USER}" >/dev/null 2>&1
}

# Create colima user if it doesn't exist
user_create() {
    if user_exists; then
        log_info "[=] User ${COLIMA_USER} already exists"
        return 0
    fi
    
    log_info "[+] Creating user ${COLIMA_USER}"
    
    # Get next available UID
    MAX_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | tail -1)
    NEW_UID=$((MAX_UID + 1))
    
    # Get group GID
    GROUP_GID=$(group_get_gid)
    
    # Create user
    dscl . -create /Users/"${COLIMA_USER}"
    dscl . -create /Users/"${COLIMA_USER}" UserShell /usr/bin/false
    dscl . -create /Users/"${COLIMA_USER}" UniqueID "${NEW_UID}"
    dscl . -create /Users/"${COLIMA_USER}" PrimaryGroupID "${GROUP_GID}"
    dscl . -create /Users/"${COLIMA_USER}" NFSHomeDirectory "${COLIMA_HOME}"
    dscl . -create /Users/"${COLIMA_USER}" IsHidden 1
    
    log_info "[+] User ${COLIMA_USER} created with UID ${NEW_UID}"
}

################################################################################

# Setup directories
setup_directories() {
    log_info "[+] Setting up directories"
    
    # Create home directory
    if [ ! -d "${COLIMA_HOME}" ]; then
        mkdir -p "${COLIMA_HOME}"
    fi
    chmod 750 "${COLIMA_HOME}"
    chown "${COLIMA_USER}:${COLIMA_GROUP}" "${COLIMA_HOME}"

    log_info "[+] Directories set up"
}

################################################################################

# Create launchd plist from template using envsubst
daemon_create_plist() {
    log_info "[+] Creating launchd plist from template"
    gen_plist "${COLIMA_DAEMON_PLIST_TEMPLATE}" "${COLIMA_DAEMON_PLIST_LAUNCHD}"
    log_info "[+] Launchd plist created"
}

# Check if daemon is loaded in launchd
daemon_is_loaded() {
    launchctl print system/"${COLIMA_DAEMON_PLIST_NAME}" >/dev/null 2>&1
}

# Unload daemon if loaded
daemon_unload() {
    log_info "[+] Unloading existing daemon (if any)"
    launchctl bootout system/"${COLIMA_DAEMON_PLIST_NAME}" 2>&1 || true
}

# Load daemon into launchd
daemon_load() {
    log_info "[+] Loading daemon into launchd"
    launchctl bootstrap system "${COLIMA_DAEMON_PLIST_LAUNCHD}" 2>&1
    
    if ! daemon_is_loaded; then
        log_error "[-] Failed to load daemon"
        return 1
    fi
    
    log_info "[+] Daemon loaded successfully"
}

# Setup launchd
daemon_setup() {
    daemon_create_plist
    daemon_unload
    daemon_load
}

################################################################################

# Setup docker socket symlink
docker_socket_setup() {
    sock_target="${COLIMA_HOME}/.colima/default/docker.sock"
    
    # Remove existing symlink or file if exists
    rm -f "${DOCKER_SOCK}"
    
    # Create symlink
    ln -s "${sock_target}" "${DOCKER_SOCK}"
    log_info "[+] Docker socket symlink created"
}

################################################################################

# Check if permissions daemon is loaded in launchd
permissions_is_loaded() {
    launchctl print system/"${COLIMA_PERMISSIONS_PLIST_NAME}" >/dev/null 2>&1
}

# Install permissions launchd plist
permissions_create_plist() {
    log_info "[+] Creating permissions launchd plist from template"
    gen_plist "${COLIMA_PERMISSIONS_PLIST_TEMPLATE}" "${COLIMA_PERMISSIONS_PLIST_LAUNCHD}"
    log_info "[+] Permissions launchd plist created"
}

# Load permissions daemon into launchd
permissions_load() {
    log_info "[+] Loading permissions daemon into launchd"
    launchctl bootstrap system "${COLIMA_PERMISSIONS_PLIST_LAUNCHD}" 2>&1
    
    if ! permissions_is_loaded; then
        log_error "[-] Failed to load permissions daemon"
        return 1
    fi
    
    log_info "[+] Permissions daemon loaded successfully"
}

# Unload permissions daemon if loaded
permissions_unload() {
    log_info "[+] Unloading existing permissions daemon (if any)"
    launchctl bootout system/"${COLIMA_PERMISSIONS_PLIST_NAME}" 2>&1 || true
}

# Setup permissions launchd unit
permissions_setup() {
    permissions_create_plist
    permissions_unload
    permissions_load
}

################################################################################

# Main function
main() {
    check_prerequisites
    group_create
    user_create
    setup_directories
    daemon_setup
    docker_socket_setup
    permissions_setup
    
    log_info "[+] Colima daemon setup completed"
}

################################################################################

# Run main function
main "$@"
