#!/bin/bash
#
# RaspAP installation functions
# Author: @billz <billzimmerman@gmail.com>
# License: GNU General Public License v3.0
#
# You are not obligated to bundle the LICENSE file with your RaspAP projects as long
# as you leave these references intact in the header comments of your source files.

# Exit on error
set -o errexit
# Exit on error inside functions
set -o errtrace
# Turn on traces, disabled by default
# set -o xtrace

# Set defaults
readonly raspap_dir="/etc/raspap"
readonly raspap_user="www-data"
readonly raspap_sudoers="/etc/sudoers.d/090_raspap"
readonly raspap_dnsmasq="/etc/dnsmasq.d/090_raspap.conf"
readonly raspap_adblock="/etc/dnsmasq.d/090_adblock.conf"
readonly raspap_sysctl="/etc/sysctl.d/90_raspap.conf"
readonly rulesv4="/etc/iptables/rules.v4"
webroot_dir="/var/www/html"
git_source_url="https://github.com/$repo"  # $repo from install.raspap.com

# NOTE: all the below functions are overloadable for system-specific installs

# Prompts user to set installation options
function _config_installation() {
    _install_log "Configure installation"
    _get_linux_distro
    echo "Detected OS: ${DESC}"
    echo "Using GitHub repository: ${repo} ${branch} branch"
    echo "Install directory: ${raspap_dir}"
    echo -n "Install to lighttpd root: ${webroot_dir}? [Y/n]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            read -e -p < /dev/tty "Enter alternate lighttpd directory: " -i "/var/www/html" webroot_dir
        fi
    else
        echo -e
    fi
    echo "Installing to lighttpd directory: ${webroot_dir}"
    echo -n "Complete installation with these values? [Y/n]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            echo "Installation aborted."
            exit 0
        fi
    else
        echo -e
    fi
}

# Determines host Linux distrubtion details
function _get_linux_distro() {
    if type lsb_release >/dev/null 2>&1; then # linuxbase.org
        OS=$(lsb_release -si)
        RELEASE=$(lsb_release -sr)
        CODENAME=$(lsb_release -sc)
        DESC=$(lsb_release -sd)
    elif [ -f /etc/os-release ]; then # freedesktop.org
        . /etc/os-release
        OS=$ID
        RELEASE=$VERSION_ID
        CODENAME=$VERSION_CODENAME
        DESC=$PRETTY_NAME
    else
        _install_error "Unsupported Linux distribution"
    fi
}

# Sets php package option based on Linux version, abort if unsupported distro
function _set_php_package() {
    case $RELEASE in
        "18.04"|"19.10") # Ubuntu Server
            php_package="php7.4-cgi"
            phpcgiconf="/etc/php/7.4/cgi/php.ini" ;;
        "10")
            php_package="php7.3-cgi"
            phpcgiconf="/etc/php/7.3/cgi/php.ini" ;;
        "9")
            php_package="php7.0-cgi"
            phpcgiconf="/etc/php/7.0/cgi/php.ini" ;;
        "8")
            _install_error "${DESC} and php5 are not supported. Please upgrade." ;;
        *)
            _install_error "${DESC} is unsupported. Please install on a supported distro." ;;
    esac
}

# Runs a system software update to make sure we're using all fresh packages
function _install_dependencies() {
    _install_log "Installing required packages"
    _set_php_package
    if [ "$php_package" = "php7.4-cgi" ]; then
        echo "Adding apt-repository ppa:ondrej/php"
        sudo apt-get install software-properties-common || _install_error "Unable to install dependency"
        sudo add-apt-repository ppa:ondrej/php || _install_error "Unable to add-apt-repository ppa:ondrej/php"
    fi
    if [ ${OS,,} = "debian" ] || [ ${OS,,} = "ubuntu" ]; then
        dhcpcd_package="dhcpcd5"
    fi
    # Set dconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
    sudo apt-get install $apt_option lighttpd git hostapd dnsmasq iptables-persistent $php_package $dhcpcd_package vnstat qrencode || _install_error "Unable to install dependencies"
}

# Enables PHP for lighttpd and restarts service for settings to take effect
function _enable_php_lighttpd() {
    _install_log "Enabling PHP for lighttpd"
    sudo lighttpd-enable-mod fastcgi-php    
    sudo service lighttpd force-reload
    sudo systemctl restart lighttpd.service || _install_error "Unable to restart lighttpd"
}

# Verifies existence and permissions of RaspAP directory
function _create_raspap_directories() {
    _install_log "Creating RaspAP directories"
    if [ -d "$raspap_dir" ]; then
        sudo mv $raspap_dir "$raspap_dir.`date +%F-%R`" || _install_error "Unable to move old '$raspap_dir' out of the way"
    fi
    sudo mkdir -p "$raspap_dir" || _install_error "Unable to create directory '$raspap_dir'"

    # Create a directory for existing file backups.
    sudo mkdir -p "$raspap_dir/backups"

    # Create a directory to store networking configs
    echo "Creating $raspap_dir/networking"
    sudo mkdir -p "$raspap_dir/networking"
    # Copy existing dhcpcd.conf to use as base config
    echo "Adding /etc/dhcpcd.conf as base configuration"
    cat /etc/dhcpcd.conf | sudo tee -a /etc/raspap/networking/defaults > /dev/null
    echo "Changing file ownership of $raspap_dir"
    sudo chown -R $raspap_user:$raspap_user "$raspap_dir" || _install_error "Unable to change file ownership for '$raspap_dir'"
}

# Generate hostapd logging and service control scripts
function _create_hostapd_scripts() {
    _install_log "Creating hostapd logging & control scripts"
    sudo mkdir $raspap_dir/hostapd || _install_error "Unable to create directory '$raspap_dir/hostapd'"

    # Move logging shell scripts 
    sudo cp "$webroot_dir/installers/"*log.sh "$raspap_dir/hostapd" || _install_error "Unable to move logging scripts"
    # Move service control shell scripts
    sudo cp "$webroot_dir/installers/"service*.sh "$raspap_dir/hostapd" || _install_error "Unable to move service control scripts"
    # Make enablelog.sh and disablelog.sh not writable by www-data group.
    sudo chown -c root:"$raspap_user" "$raspap_dir/hostapd/"*.sh || _install_error "Unable change owner and/or group"
    sudo chmod 750 "$raspap_dir/hostapd/"*.sh || _install_error "Unable to change file permissions"
}

# Generate lighttpd service control scripts
function _create_lighttpd_scripts() {
    _install_log "Creating lighttpd control scripts"
    sudo mkdir $raspap_dir/lighttpd || _install_error "Unable to create directory '$raspap_dir/lighttpd"

    # Move service control shell scripts
    sudo cp "$webroot_dir/installers/"configport.sh "$raspap_dir/lighttpd" || _install_error "Unable to move service control scripts"
    # Make configport.sh writable by www-data group
    sudo chown -c root:"$raspap_user" "$raspap_dir/lighttpd/"*.sh || _install_error "Unable change owner and/or group"
    sudo chmod 750 "$raspap_dir/lighttpd/"*.sh || _install_error "Unable to change file permissions"
}

# Prompt to install adblock
function _prompt_install_adblock() {
    if [ "$install_adblock" == 1 ]; then
        _install_log "Configure ad blocking (Beta)"
        echo -n "Download blocklists and enable ad blocking? [Y/n]: "
        if [ "$assume_yes" == 0 ]; then
            read answer < /dev/tty
            if [ "$answer" != "${answer#[Nn]}" ]; then
                echo -e
            else
                _install_adblock
            fi
        fi
    fi
}

# Download notracking adblock lists and enable option
function _install_adblock() {
    _install_log "Creating ad block base configuration (Beta)"
    notracking_url="https://raw.githubusercontent.com/notracking/hosts-blocklists/master/"
    if [ ! -d "$raspap_dir/adblock" ]; then
        echo "Creating $raspap_dir/adblock"
        sudo mkdir -p "$raspap_dir/adblock"
    fi
    if [ ! -f /tmp/hostnames.txt ]; then
        echo "Fetching latest hostnames list"
        wget ${notracking_url}hostnames.txt -q --show-progress --progress=bar:force -O /tmp/hostnames.txt 2>&1 \
            || _install_error "Unable to download notracking hostnames"
    fi
    if [ ! -f /tmp/domains.txt ]; then
        echo "Fetching latest domains list"
        wget ${notracking_url}domains.txt -q --show-progress --progress=bar:force -O /tmp/domains.txt 2>&1 \
            || _install_error "Unable to download notracking domains"
    fi
    echo "Adding blocklists to $raspap_dir/adblock"
    sudo cp /tmp/hostnames.txt $raspap_dir/adblock || _install_error "Unable to move notracking hostnames"
    sudo cp /tmp/domains.txt $raspap_dir/adblock || _install_error "Unable to move notracking domains"

    echo "Moving and setting permissions for blocklist update script"
    sudo cp "$webroot_dir/installers/"update_blocklist.sh "$raspap_dir/adblock" || _install_error "Unable to move blocklist update script"

    # Make blocklists and update script writable by www-data group
    sudo chown -c root:"$raspap_user" "$raspap_dir/adblock/"*.* || _install_error "Unable to change owner/group"
    sudo chmod 750 "$raspap_dir/adblock/"*.sh || install_error "Unable to change file permissions"

    # Create 090_adblock.conf and write values to /etc/dnsmasq.d
    if [ ! -f "$raspap_adblock" ]; then
        echo "Adding 090_addblock.conf to /etc/dnsmasq.d"
        sudo touch "$raspap_adblock"
        echo "conf-file=$raspap_dir/adblock/domains.txt" | sudo tee -a "$raspap_adblock" > /dev/null || _install_error "Unable to write to $raspap_adblock"
        echo "addn-hosts=$raspap_dir/adblock/hostnames.txt" | sudo tee -a "$raspap_adblock" > /dev/null || _install_error "Unable to write to $raspap_adblock"
    fi

    echo "Enabling ad blocking management option"
    sudo sed -i "s/\('RASPI_ADBLOCK_ENABLED', \)false/\1true/g" "$webroot_dir/includes/config.php" || _install_error "Unable to modify config.php"
    echo "Done."
}

# Prompt to install openvpn
function _prompt_install_openvpn() {
    _install_log "Setting up OpenVPN support"
    echo -n "Install OpenVPN and enable client configuration? [Y/n]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            echo -e
        else
            _install_openvpn
        fi
    elif [ "$ovpn_option" == 1 ]; then
        _install_openvpn
    fi
}

# Install openvpn and enable client configuration option
function _install_openvpn() {
    _install_log "Installing OpenVPN and enabling client configuration"
    sudo apt-get install -y openvpn || _install_error "Unable to install openvpn"
    sudo sed -i "s/\('RASPI_OPENVPN_ENABLED', \)false/\1true/g" "$webroot_dir/includes/config.php" || _install_error "Unable to modify config.php"
    echo "Enabling openvpn-client service on boot"
    sudo systemctl enable openvpn-client@client || _install_error "Unable to enable openvpn-client daemon"
    _create_openvpn_scripts || _install_error "Unable to create openvpn control scripts"
}

# Generate openvpn logging and auth control scripts
function _create_openvpn_scripts() {
    _install_log "Creating OpenVPN control scripts"
    sudo mkdir $raspap_dir/openvpn || _install_error "Unable to create directory '$raspap_dir/openvpn'"

   # Move service auth control shell scripts
    sudo cp "$webroot_dir/installers/"configauth.sh "$raspap_dir/openvpn" || _install_error "Unable to move auth control script"
    # Make configauth.sh writable by www-data group
    sudo chown -c root:"$raspap_user" "$raspap_dir/openvpn/"*.sh || _install_error "Unable change owner and/or group"
    sudo chmod 750 "$raspap_dir/openvpn/"*.sh || _install_error "Unable to change file permissions"
}

# Fetches latest files from github to webroot
function _download_latest_files() {
    if [ ! -d "$webroot_dir" ]; then
        sudo mkdir -p $webroot_dir || _install_error "Unable to create new webroot directory"
    fi

    if [ -d "$webroot_dir" ]; then
        sudo mv $webroot_dir "$webroot_dir.`date +%F-%R`" || _install_error "Unable to remove old webroot directory"
    fi

    _install_log "Cloning latest files from github"
    git clone --branch $branch --depth 1 $git_source_url /tmp/raspap-webgui || _install_error "Unable to download files from github"

    sudo mv /tmp/raspap-webgui $webroot_dir || _install_error "Unable to move raspap-webgui to web root"
}

# Sets files ownership in web root directory
function _change_file_ownership() {
    if [ ! -d "$webroot_dir" ]; then
        _install_error "Web root directory doesn't exist"
    fi

    _install_log "Changing file ownership in web root directory"
    sudo chown -R $raspap_user:$raspap_user "$webroot_dir" || _install_error "Unable to change file ownership for '$webroot_dir'"
}

# Check for existing configuration files
function _check_for_old_configs() {
    if [ -f /etc/network/interfaces ]; then
        sudo cp /etc/network/interfaces "$raspap_dir/backups/interfaces.`date +%F-%R`"
        sudo ln -sf "$raspap_dir/backups/interfaces.`date +%F-%R`" "$raspap_dir/backups/interfaces"
    fi

    if [ -f /etc/hostapd/hostapd.conf ]; then
        sudo cp /etc/hostapd/hostapd.conf "$raspap_dir/backups/hostapd.conf.`date +%F-%R`"
        sudo ln -sf "$raspap_dir/backups/hostapd.conf.`date +%F-%R`" "$raspap_dir/backups/hostapd.conf"
    fi

    if [ -f $raspap_dnsmasq ]; then
        sudo cp $raspap_dnsmasq "$raspap_dir/backups/dnsmasq.conf.`date +%F-%R`"
        sudo ln -sf "$raspap_dir/backups/dnsmasq.conf.`date +%F-%R`" "$raspap_dir/backups/dnsmasq.conf"
    fi

    if [ -f /etc/dhcpcd.conf ]; then
        sudo cp /etc/dhcpcd.conf "$raspap_dir/backups/dhcpcd.conf.`date +%F-%R`"
        sudo ln -sf "$raspap_dir/backups/dhcpcd.conf.`date +%F-%R`" "$raspap_dir/backups/dhcpcd.conf"
    fi

    for file in /etc/systemd/network/raspap-*.net*; do
        if [ -f "${file}" ]; then
            filename=$(basename $file)
            sudo cp "$file" "${raspap_dir}/backups/${filename}.`date +%F-%R`"
            sudo ln -sf "${raspap_dir}/backups/${filename}.`date +%F-%R`" "${raspap_dir}/backups/${filename}"
        fi
    done
}

# Move configuration file to the correct location
function _move_config_file() {
    if [ ! -d "$raspap_dir" ]; then
        _install_error "'$raspap_dir' directory doesn't exist"
    fi

    _install_log "Moving configuration file to '$raspap_dir'"
    sudo cp "$webroot_dir"/raspap.php "$raspap_dir" || _install_error "Unable to move files to '$raspap_dir'"
    sudo chown -R $raspap_user:$raspap_user "$raspap_dir" || _install_error "Unable to change file ownership for '$raspap_dir'"
}

# Set up default configuration
function _default_configuration() {
    _install_log "Applying default configuration to installed services"
    if [ -f /etc/default/hostapd ]; then
        sudo mv /etc/default/hostapd /tmp/default_hostapd.old || _install_error "Unable to remove old /etc/default/hostapd file"
    fi
    sudo cp $webroot_dir/config/default_hostapd /etc/default/hostapd || _install_error "Unable to move hostapd defaults file"
    sudo cp $webroot_dir/config/hostapd.conf /etc/hostapd/hostapd.conf || _install_error "Unable to move hostapd configuration file"
    sudo cp $webroot_dir/config/dnsmasq.conf $raspap_dnsmasq || _install_error "Unable to move dnsmasq configuration file"
    sudo cp $webroot_dir/config/dhcpcd.conf /etc/dhcpcd.conf || _install_error "Unable to move dhcpcd configuration file"

    [ -d /etc/dnsmasq.d ] || sudo mkdir /etc/dnsmasq.d

    sudo systemctl stop systemd-networkd
    sudo systemctl disable systemd-networkd
    sudo cp $webroot_dir/config/raspap-bridge-br0.netdev /etc/systemd/network/raspap-bridge-br0.netdev || _install_error "Unable to move br0 netdev file"
    sudo cp $webroot_dir/config/raspap-br0-member-eth0.network /etc/systemd/network/raspap-br0-member-eth0.network || _install_error "Unable to move br0 member file"

    if [ ! -f "$webroot_dir/includes/config.php" ]; then
        sudo cp "$webroot_dir/config/config.php" "$webroot_dir/includes/config.php"
    fi
}

# Install and enable RaspAP daemon
function _enable_raspap_daemon() {
    _install_log "Enabling RaspAP daemon"
    echo "Disable with: sudo systemctl disable raspapd.service"
    sudo cp $webroot_dir/installers/raspapd.service /lib/systemd/system/ || _install_error "Unable to move raspap.service file"
    sudo systemctl daemon-reload
    sudo systemctl enable raspapd.service || _install_error "Failed to enable raspap.service"
}

# Configure IP forwarding, set IP tables rules, prompt to install RaspAP daemon
function _configure_networking() {
    _install_log "Configuring networking"
    echo "Enabling IP forwarding"
    echo "net.ipv4.ip_forward=1" | sudo tee $raspap_sysctl > /dev/null || _install_error "Unable to set IP forwarding"
    sudo sysctl -p $raspap_sysctl || _install_error "Unable to execute sysctl"
    sudo /etc/init.d/procps restart || _install_error "Unable to execute procps"

    echo "Checking iptables rules"
    rules=(
    "-A POSTROUTING -j MASQUERADE"
    "-A POSTROUTING -s 192.168.50.0/24 ! -d 192.168.50.0/24 -j MASQUERADE"
    )
    for rule in "${rules[@]}"; do
        if grep -- "$rule" $rulesv4 > /dev/null; then
            echo "Rule already exits: ${rule}"
        else
            rule=$(sed -e 's/^\(-A POSTROUTING\)/-t nat \1/' <<< $rule)
            echo "Adding rule: ${rule}"
            sudo iptables $rule || _install_error "Unable to execute iptables"
            added=true
        fi
    done
    # Persist rules if added
    if [ "$added" = true ]; then
        echo "Persisting IP tables rules"
        sudo iptables-save | sudo tee $rulesv4 > /dev/null || _install_error "Unable to execute iptables-save"
    fi

    # Prompt to install RaspAP daemon
    echo -n "Enable RaspAP control service (Recommended)? [Y/n]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            echo -e
        else
            _enable_raspap_daemon
        fi
    else
        echo -e
        _enable_raspap_daemon
    fi
 }

# Add sudoers file to /etc/sudoers.d/ and set file permissions
function _patch_system_files() {

    # Create sudoers if not present
    if [ ! -f $raspap_sudoers ]; then
        _install_log "Adding raspap.sudoers to ${raspap_sudoers}"
        sudo cp "$webroot_dir/installers/raspap.sudoers" $raspap_sudoers || _install_error "Unable to apply raspap.sudoers to $raspap_sudoers"
        sudo chmod 0440 $raspap_sudoers || _install_error "Unable to change file permissions for $raspap_sudoers"
    fi

    # Add symlink to prevent wpa_cli cmds from breaking with multiple wlan interfaces
    _install_log "Symlinked wpa_supplicant hooks for multiple wlan interfaces"
    if [ ! -f /usr/share/dhcpcd/hooks/10-wpa_supplicant ]; then
        sudo ln -s /usr/share/dhcpcd/hooks/10-wpa_supplicant /etc/dhcp/dhclient-enter-hooks.d/
    fi

    # Unmask and enable hostapd.service
    _install_log "Unmasking and enabling hostapd service"
    sudo systemctl unmask hostapd.service
    sudo systemctl enable hostapd.service
}


# Optimize configuration of php-cgi.
function _optimize_php() {
    _install_log "Optimize PHP configuration"
    if [ ! -f "$phpcgiconf" ]; then
        _install_warning "PHP configuration could not be found."
        return
    fi

    # Backup php.ini and create symlink for restoring.
    datetimephpconf=$(date +%F-%R)
    sudo cp "$phpcgiconf" "$raspap_dir/backups/php.ini.$datetimephpconf"
    sudo ln -sf "$raspap_dir/backups/php.ini.$datetimephpconf" "$raspap_dir/backups/php.ini"

    echo -n "Enable HttpOnly for session cookies (Recommended)? [Y/n]: "
    if [ "$assume_yes" == 0 ]; then
        read answer < /dev/tty
        if [ "$answer" != "${answer#[Nn]}" ]; then
            echo -e
        else
             php_session_cookie=1;
        fi
    fi

    if [ "$assume_yes" == 1 ] || [ "$php_session_cookie" == 1 ]; then
        echo "Php-cgi enabling session.cookie_httponly."
        sudo sed -i -E 's/^session\.cookie_httponly\s*=\s*(0|([O|o]ff)|([F|f]alse)|([N|n]o))\s*$/session.cookie_httponly = 1/' "$phpcgiconf"
    fi

    if [ "$php_package" = "php7.1-cgi" ]; then
        echo -n "Enable PHP OPCache (Recommended)? [Y/n]: "
        if [ "$assume_yes" == 0 ]; then
            read answer < /dev/tty
            if [ "$answer" != "${answer#[Nn]}" ]; then
                echo -e
            else
                php_opcache=1;
            fi
        fi

        if [ "$assume_yes" == 1 ] || [ "$phpopcache" == 1 ]; then
            echo -e "Php-cgi enabling opcache.enable."
            sudo sed -i -E 's/^;?opcache\.enable\s*=\s*(0|([O|o]ff)|([F|f]alse)|([N|n]o))\s*$/opcache.enable = 1/' "$phpcgiconf"
            # Make sure opcache extension is turned on.
            if [ -f "/usr/sbin/phpenmod" ]; then
                sudo phpenmod opcache
            else
                _install_warning "phpenmod not found."
            fi
        fi
    fi
}

function _install_complete() {
    _install_log "Installation completed!"
    if [ "$assume_yes" == 0 ]; then
        # Prompt to reboot if wired ethernet (eth0) is connected.
        # With default_configuration this will create an active AP on restart.
        if ip a | grep -q ': eth0:.*state UP'; then
            echo -n "The system needs to be rebooted as a final step. Reboot now? [y/N]: "
            read answer < /dev/tty
            if [ "$answer" != "${answer#[Nn]}" ]; then
                echo "Installation reboot aborted."
                exit 0
            fi
            sudo shutdown -r now || _install_error "Unable to execute shutdown"
        fi
    fi
}

function _install_raspap() {
    _display_welcome
    _config_installation
    _update_system_packages
    _install_dependencies
    _enable_php_lighttpd
    _create_raspap_directories
    _optimize_php
    _check_for_old_configs
    _download_latest_files
    _change_file_ownership
    _create_hostapd_scripts
    _create_lighttpd_scripts
    _move_config_file
    _default_configuration
    _configure_networking
    _prompt_install_openvpn
    _prompt_install_adblock
    _patch_system_files
    _install_complete
}
