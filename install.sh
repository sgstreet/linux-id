#!/bin/bash

set -o pipefail

executable=linux-id
release_url="https://github.com/sgstreet/linux-id/releases/latest/download/linux-id_Linux_x86_64.tar.gz"
script_dir="$(cd "$(dirname "$0")" && pwd)"

auth_mode="pinentry"
auth_given=false
uninstall=false
purge=false

cred_dir="$HOME/.config/linux-id"
unit_dropin_dir=/usr/lib/systemd/user/linux-id.service.d
userns_dropin="$unit_dropin_dir/10-apparmor-userns.conf"
# Where 'systemctl --user edit linux-id.service' saves overrides.
user_dropin_dir="$HOME/.config/systemd/user/linux-id.service.d"

function usage() {
    cat <<EOF
Usage: $0 [--auth pinentry|fprintd] [-h|--help]
       $0 --uninstall [--purge]

Options:
  --auth pinentry   Confirm presence with a click dialog.
  --auth fprintd    Confirm presence with a fingerprint scan.
                    Requires fprintd installed and a fingerprint enrolled
                    via 'fprintd-enroll'. Sets the WebAuthn UV flag.
                    Without --auth, fprintd is used if you have a
                    fingerprint enrolled, otherwise pinentry.
  --uninstall       Remove linux-id from this system. Asks for confirmation
                    twice before changing anything.
  --purge           With --uninstall, also permanently delete the stored
                    resident credentials in $cred_dir.
  -h, --help        Show this help.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --auth)
            auth_mode="$2"
            auth_given=true
            shift 2
            ;;
        --auth=*)
            auth_mode="${1#--auth=}"
            auth_given=true
            shift
            ;;
        --uninstall)
            uninstall=true
            shift
            ;;
        --purge)
            purge=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if $purge && ! $uninstall; then
    echo "--purge is only valid together with --uninstall" >&2
    exit 1
fi

if $uninstall && $auth_given; then
    echo "--auth cannot be combined with --uninstall" >&2
    exit 1
fi

# fprintd-list prints one " - #N: <finger>" line per enrolled finger.
function fingerprint_enrolled() {
    command -v fprintd-list &>/dev/null || return 1
    timeout 10 fprintd-list "$USER" 2>/dev/null | grep -Eq '^[[:space:]]*- #[0-9]+:'
}

if ! $uninstall && ! $auth_given && fingerprint_enrolled; then
    echo "Found an enrolled fingerprint; using --auth fprintd (pass --auth pinentry to override)."
    auth_mode="fprintd"
fi

case "$auth_mode" in
    pinentry|fprintd) ;;
    *)
        echo "Invalid --auth value: $auth_mode (must be 'pinentry' or 'fprintd')" >&2
        exit 1
        ;;
esac

if [ "$auth_mode" = "fprintd" ]; then
    auth_arg=" --auth fprintd"
else
    auth_arg=""
fi

function handle() {
    if [ $? -ne 0 ]; then
        echo "$1" >&2
        exit 1
    fi
}

function check_prereqs() {
    if [ ! -d /sys/class/tpm/tpm0 ]; then
        echo "TPM is not present, make sure to enable it in BIOS/UEFI" >&2
        exit 1
    fi

    # Either we're in a source clone (go.mod + go) and build, or we download
    # the latest release tarball with curl/wget. No stale local binary path,
    # so re-running install.sh always picks up the latest published version.
    if [ -f "$script_dir/go.mod" ] && command -v go &>/dev/null; then
        :
    elif command -v curl &>/dev/null || command -v wget &>/dev/null; then
        :
    else
        echo "Need (go.mod + go) to build, or curl/wget to download the binary" >&2
        exit 1
    fi

    if ! command -v pinentry &>/dev/null; then
        echo "pinentry is not installed, please install it" >&2
        exit 1
    fi

    if [ "$auth_mode" = "fprintd" ] && ! command -v fprintd-enroll &>/dev/null; then
        echo "--auth fprintd requested but fprintd is not installed" >&2
        echo "Install fprintd first, then run 'fprintd-enroll' to enroll a finger" >&2
        exit 1
    fi

    if ! command -v systemctl &>/dev/null; then
        echo "systemctl not found — systemd is required" >&2
        exit 1
    fi
}

function check_aur_install() {
    if command -v pacman &>/dev/null && pacman -Q linux-id &>/dev/null; then
        echo "linux-id is already installed via the AUR package." >&2
        echo "Use 'sudo pacman -R linux-id' first if you want to switch to install.sh." >&2
        exit 1
    fi
}

function migrate_old_install() {
    local old_autostart="/home/$USER/.config/autostart/linux-id.desktop"
    if [ -f "$old_autostart" ]; then
        echo "Removing old autostart entry: $old_autostart"
        rm -f "$old_autostart"
    fi

    local old_user_unit="/home/$USER/.config/systemd/user/linux-id.service"
    if [ -f "$old_user_unit" ]; then
        echo "Removing old user systemd unit: $old_user_unit"
        systemctl --user disable linux-id.service 2>/dev/null || true
        rm -f "$old_user_unit"
    fi

    if [ -f /usr/local/bin/linux-id ]; then
        echo "Removing old binary: /usr/local/bin/linux-id"
        sudo rm -f /usr/local/bin/linux-id
    fi

    if [ -f /etc/udev/rules.d/70-uhid.rules ]; then
        echo "Removing old udev rule: /etc/udev/rules.d/70-uhid.rules"
        sudo rm -f /etc/udev/rules.d/70-uhid.rules
    fi

    if id -nG "$USER" | grep -qw tss; then
        echo "Note: user is still in the 'tss' group from a previous install."
        echo "      The new udev rule no longer needs it; you may run:"
        echo "          sudo gpasswd -d $USER tss"
    fi

    if pgrep -x linux-id >/dev/null; then
        echo "Stopping existing linux-id process"
        pkill -x linux-id || true
    fi
}

function make_executable() {
    local source_binary

    if [ -f "$script_dir/go.mod" ] && command -v go &>/dev/null; then
        echo "Building $executable from source in $script_dir"
        ( cd "$script_dir" && go build -o "$executable" )
        handle "Failed to build executable with go"
        source_binary="$script_dir/$executable"
    else
        local tmp
        tmp="$(mktemp -d)"
        trap 'rm -rf "$tmp"' EXIT
        echo "Downloading latest binary from $release_url"
        if command -v curl &>/dev/null; then
            curl -fsSL "$release_url" | tar -xz -C "$tmp"
        else
            wget -qO- "$release_url" | tar -xz -C "$tmp"
        fi
        handle "Failed to download or extract the prebuilt binary"
        if [ ! -f "$tmp/$executable" ]; then
            echo "Tarball did not contain '$executable':" >&2
            ls -la "$tmp" >&2
            exit 1
        fi
        source_binary="$tmp/$executable"
    fi

    sudo install -Dm755 "$source_binary" /usr/bin/"$executable"
    handle "Failed to install executable to /usr/bin"
}

# Ubuntu (24.04+) sets kernel.apparmor_restrict_unprivileged_userns=1, which
# stops the per-user systemd manager from building the user namespace that the
# unit's filesystem/namespace sandboxing needs; the service then fails with
# 226/NAMESPACE. On such systems install a drop-in that turns those options
# off, keeping the hardening that does not need a namespace (NoNewPrivileges,
# RestrictAddressFamilies, MemoryDenyWriteExecute, ...).
function install_userns_dropin() {
    if [ "$(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null)" != "1" ]; then
        # Restriction off (or not Ubuntu): keep the full sandbox.
        if [ -e "$userns_dropin" ]; then
            sudo rm -f "$userns_dropin"
            handle "Failed to remove $userns_dropin"
        fi
        return
    fi

    echo "AppArmor restricts unprivileged user namespaces on this system;"
    echo "installing $userns_dropin to disable the namespace-based sandboxing."
    sudo install -Dm644 /dev/stdin "$userns_dropin" <<'EOF'
# Installed by linux-id install.sh because kernel.apparmor_restrict_unprivileged_userns=1.
# These options need a user namespace in a per-user service, which AppArmor
# denies, so the service would fail with status=226/NAMESPACE.
[Service]
ProtectProc=default
BindPaths=
BindReadOnlyPaths=
ProtectSystem=no
ProtectHome=no
PrivateTmp=no
PrivateMounts=no
PrivateNetwork=no
PrivatePIDs=no
PrivateUsers=no
ProtectHostname=no
ProtectClock=no
ProtectKernelTunables=no
ProtectKernelModules=no
ProtectKernelLogs=no
ProtectControlGroups=no
EOF
    handle "Failed to install $userns_dropin"
}

function install_unit_and_rules() {
    sudo install -Dm644 /dev/stdin /usr/lib/systemd/user/linux-id.service <<EOF
[Unit]
Description=linux-id TPM service
Documentation=https://github.com/sgstreet/linux-id
ConditionSecurity=tpm2
ConditionKernelModuleLoaded=uhid

[Service]
Type=simple
ExecStart=/usr/bin/linux-id${auth_arg}

ProtectProc=noaccess
# pinentry may need to access /run/user/\$UID/wayland-0
BindReadOnlyPaths=%t
# pinentry may need to access /tmp/.X11-unix
BindReadOnlyPaths=%T/.X11-unix
# pinentry may need to write here
BindPaths=%E
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=tmpfs
PrivateTmp=true
PrivateNetwork=true
PrivatePIDs=true
PrivateUsers=true
ProtectHostname=true
ProtectClock=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectKernelLogs=true
ProtectControlGroups=true
# pinentry may need to connect to wayland/x11 socket
RestrictAddressFamilies=AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true
RestrictRealtime=true
RestrictSUIDSGID=true
PrivateMounts=true

DeviceAllow=/dev/tpmrm0
DeviceAllow=/dev/uhid

[Install]
WantedBy=default.target
EOF
    handle "Failed to install systemd unit"

    install_userns_dropin

    sudo install -Dm644 /dev/stdin /usr/lib/udev/rules.d/60-linux-id-fido-tpm.rules <<'EOF'
# Allow user access tpmrm0 and uhid

KERNEL=="uhid",   SUBSYSTEM=="misc",  TAG+="uaccess"
KERNEL=="tpmrm0", SUBSYSTEM=="tpmrm", TAG+="uaccess"

# Let snap-packaged browsers open linux-id's virtual token. snapd's
# u2f-devices interface only admits known USB keys by idVendor/idProduct,
# which a uhid device has no USB parent to match, so the snap's device
# cgroup silently blocks it. Tagging the hidraw node lets snapd's own
# 70-snap.<name>.rules add it. Harmless when the snap is not installed.
SUBSYSTEM=="hidraw", KERNELS=="0003:15D9:0A37.*", TAG+="snap_firefox_firefox"
SUBSYSTEM=="hidraw", KERNELS=="0003:15D9:0A37.*", TAG+="snap_chromium_chromium"
EOF
    handle "Failed to install udev rules"

    sudo install -Dm644 /dev/stdin /usr/lib/modules-load.d/uhid.conf <<'EOF'
uhid
EOF
    handle "Failed to install modules-load entry"

    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=misc --subsystem-match=tpmrm

    if ! lsmod | grep -qw uhid; then
        sudo modprobe uhid
        handle "Failed to load uhid kernel module"
    fi
}

function enable_user_service() {
    if ! systemctl --user daemon-reload 2>/dev/null; then
        echo
        echo "WARNING: could not reach your user systemd instance from this shell." >&2
        echo "Log back in to your desktop session, then run:" >&2
        echo "    systemctl --user daemon-reload" >&2
        echo "    systemctl --user enable --now linux-id.service" >&2
        echo "    systemctl --user status linux-id.service" >&2
        return
    fi

    systemctl --user enable linux-id.service
    handle "Failed to enable linux-id.service"

    if ! systemctl --user restart linux-id.service; then
        echo "WARNING: linux-id.service did not start cleanly. See status below." >&2
    fi

    echo
    echo "linux-id.service status:"
    echo "------------------------"
    systemctl --user --no-pager status linux-id.service || true
}

# Prompt on stderr and read the answer from the terminal rather than stdin,
# so piped or redirected input can never confirm an uninstall. With no
# terminal the answer is empty, which aborts.
function ask() {
    local reply=""
    printf '%s' "$1" >&2
    read -r reply 2>/dev/null </dev/tty
    printf '%s' "$reply"
}

function check_package_install() {
    if command -v pacman &>/dev/null && pacman -Q linux-id &>/dev/null; then
        echo "linux-id is installed via the AUR package; remove it with:" >&2
        echo "    sudo pacman -R linux-id" >&2
        exit 1
    fi

    if command -v rpm &>/dev/null && rpm -q linux-id &>/dev/null; then
        echo "linux-id is installed via an RPM package (e.g. COPR); remove it with:" >&2
        echo "    sudo dnf remove linux-id" >&2
        exit 1
    fi
}

function uninstall_linux_id() {
    # Current install locations followed by leftovers from older install.sh
    # versions (also cleaned up by migrate_old_install).
    local candidates=(
        /usr/bin/linux-id
        /usr/lib/systemd/user/linux-id.service
        "$unit_dropin_dir"
        "$user_dropin_dir"
        /usr/lib/udev/rules.d/60-linux-id-fido-tpm.rules
        /usr/lib/modules-load.d/uhid.conf
        /usr/local/bin/linux-id
        /etc/udev/rules.d/70-uhid.rules
        "/home/$USER/.config/autostart/linux-id.desktop"
        "/home/$USER/.config/systemd/user/linux-id.service"
    )
    local present=() f

    check_package_install

    for f in "${candidates[@]}"; do
        if [ -e "$f" ]; then
            present+=("$f")
        fi
    done
    if $purge && [ -e "$cred_dir" ]; then
        present+=("$cred_dir")
    fi

    if [ ${#present[@]} -eq 0 ]; then
        echo "linux-id does not appear to be installed; nothing to remove."
        exit 0
    fi

    echo "This will stop linux-id.service and remove:"
    printf '    %s\n' "${present[@]}"
    echo
    echo "WARNING: every site where you registered linux-id as a security key"
    echo "or passkey will stop accepting it. Make sure each of those accounts"
    echo "has another way to sign in before continuing."
    if $purge && [ -e "$cred_dir" ]; then
        echo
        echo "WARNING: --purge permanently deletes your stored resident"
        echo "credentials (passkeys) in $cred_dir. Reinstalling linux-id"
        echo "will not bring them back."
    fi
    echo

    if [[ "$(ask "Uninstall linux-id? [y/N] ")" != [yY] ]]; then
        echo "Aborted; nothing was changed."
        exit 1
    fi

    if [ "$(ask "Are you sure? Type 'uninstall' to confirm: ")" != "uninstall" ]; then
        echo "Aborted; nothing was changed."
        exit 1
    fi

    if $purge && [ -e "$cred_dir" ] &&
        [ "$(ask "Type 'delete' to permanently delete $cred_dir: ")" != "delete" ]; then
        echo "Aborted; nothing was changed."
        exit 1
    fi

    echo "Uninstalling linux-id"

    systemctl --user disable --now linux-id.service 2>/dev/null || true

    # Removes leftovers from older installs and stops any stray process.
    migrate_old_install

    sudo rm -f \
        /usr/bin/linux-id \
        /usr/lib/systemd/user/linux-id.service \
        /usr/lib/udev/rules.d/60-linux-id-fido-tpm.rules \
        /usr/lib/modules-load.d/uhid.conf
    handle "Failed to remove installed files"

    # Drop-in directories: ours, and any 'systemctl --user edit' overrides.
    sudo rm -rf "$unit_dropin_dir"
    handle "Failed to remove $unit_dropin_dir"
    rm -rf "$user_dropin_dir"
    handle "Failed to remove $user_dropin_dir"

    systemctl --user daemon-reload 2>/dev/null || true
    sudo udevadm control --reload-rules
    sudo udevadm trigger --subsystem-match=misc --subsystem-match=tpmrm

    if $purge && [ -e "$cred_dir" ]; then
        rm -rf "$cred_dir"
        handle "Failed to delete $cred_dir"
        echo "Deleted $cred_dir"
    elif [ -e "$cred_dir" ]; then
        echo "Kept stored credentials in $cred_dir (re-run with --purge to delete them)."
    fi

    echo
    echo "linux-id has been uninstalled. Log out and back in (or reboot) to drop"
    echo "the device permissions granted by the removed udev rule."
}

if $uninstall; then
    uninstall_linux_id
    exit 0
fi

echo "Installing linux-id (auth=$auth_mode)"

check_prereqs
check_aur_install
migrate_old_install
make_executable
install_unit_and_rules
enable_user_service

echo
echo "Installation successful (auth=$auth_mode). Log out and back in (or reboot)"
echo "so the new udev rules and user systemd unit are picked up."
