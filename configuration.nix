{ config, pkgs, lib, ... }:

let
  # Concrete values
  wifiSSID = "mycar";
  wifiPSK  = "1z2x3c4v5b";
  staticIP = "10.10.1.222";
  gateway  = "10.10.1.1";
  dnsUp    = "1.1.1.1";

  # Local flake path used by OTA service (image will place flake at /etc/nixos)
  localFlake = "/etc/nixos";

  # Pinned Pi-hole image digest (immutable, reproducible)
  piholeImage = "docker.io/pihole/pihole@sha256:300cc8f9e966b00440358aafef21f91b32dfe8887e8bd9a6193ed1c4328655d4";
in
{
  ################################################################
  # Base system identity and boot
  ################################################################
  system.stateVersion = "23.11";
  networking.hostName = "rpi400-appliance";

  boot.loader.raspberryPi.enable = true;
  boot.loader.raspberryPi.version = 2;

  ################################################################
  # Minimal packages and users
  ################################################################
  environment.systemPackages = with pkgs; [
    bash
    coreutils
    iproute2
    iputils
    bind
    podman
    podman-compose
    sway
    wayland
    librewolf
    jq
    htop
  ];

  users.users.pi = {
    isNormalUser = true;
    description = "Autologin user for appliance";
    extraGroups = [ "wheel" "audio" "video" "networkmanager" ];
    createHome = true;
    # Intentionally unusable hash to force first-boot provisioning to set password
    initialHashedPassword = "$6$rounds=1$abcdefghijklmnop$abcdefghijklmnopqrstuvwx";
    shell = pkgs.bash;
  };

  ################################################################
  # UI: Wayland Sway autologin on tty1
  ################################################################
  services.getty.autologinUser = "pi";
  systemd.services."getty@tty1".enable = false;

  systemd.services.sway-tty1 = {
    description = "Sway session on tty1 for user pi";
    after = [ "systemd-user-sessions.service" "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      User = "pi";
      Group = "pi";
      TTYPath = "/dev/tty1";
      StandardInput = "tty";
      StandardOutput = "tty";
      Restart = "always";
      RestartSec = "2s";
      Environment = "XDG_RUNTIME_DIR=/run/user/1000";
    };
    script = ''
      #!/bin/sh
      mkdir -p /run/user/1000
      chown pi:pi /run/user/1000 || true
      exec /run/current-system/sw/bin/dbus-run-session /run/current-system/sw/bin/sway
    '';
  };

  services.xserver.enable = false;

  ################################################################
  # Networking: networkd, static IP, disable systemd-resolved
  ################################################################
  networking.useNetworkd = true;
  services.systemd-resolved.enable = false;
  networking.firewall.enable = true;
  networking.firewall.allowedTCPPorts = [ 80 ];
  networking.firewall.allowedUDPPorts = [ 53 ];
  networking.interfaces.wlan0.ipv4.addresses = [
    { address = staticIP; prefixLength = 24; }
  ];
  networking.defaultGateway = gateway;
  networking.nameservers = [ dnsUp ];

  networking.wireless = {
    enable = true;
    networks = {
      "${wifiSSID}" = { psk = wifiPSK; };
    };
  };

  # Disable Wi-Fi power saving for stability
  systemd.services.disable-wifi-powersave = {
    description = "Disable Wi-Fi power save for wlan0";
    after = [ "network-pre.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = { Type = "oneshot"; };
    script = ''
      #!/bin/sh
      for i in 1 2 3 4 5; do
        if /run/current-system/sw/bin/iw dev wlan0 set power_save off 2>/dev/null; then
          exit 0
        fi
        sleep 1
      done
      exit 0
    '';
  };

  ################################################################
  # Bluetooth CLI only
  ################################################################
  hardware.bluetooth.enable = true;
  services.bluetooth.enable = true;

  ################################################################
  # Podman and Pi-hole container (pinned image, persistent data)
  ################################################################
  virtualisation.podman = {
    enable = true;
    enableSocket = true;
    package = pkgs.podman;
  };

  # Ensure persistent directory exists on rootfs
  environment.etc."var-lib-pihole".source = null;
  # Bind mount handled by systemd service script; ensure directory exists
  systemd.tmpfiles.rules = [
    "d /var/lib/pihole 0755 root root -"
  ];

  systemd.services.pihole-container = {
    description = "Podman Pi-hole container (managed)";
    after = [ "network-online.target" "podman.socket" ];
    wants = [ "network-online.target" "podman.socket" ];
    serviceConfig = {
      Restart = "always";
      RestartSec = "5s";
      KillMode = "process";
      TimeoutStartSec = "120s";
    };
    script = ''
      #!/bin/sh
      set -e
      mkdir -p /var/lib/pihole
      chown 999:999 /var/lib/pihole || true
      /run/current-system/sw/bin/podman rm -f pihole 2>/dev/null || true
      exec /run/current-system/sw/bin/podman run \
        --name pihole \
        --replace \
        --net host \
        -v /var/lib/pihole:/data:Z \
        -e TZ="UTC" \
        -e WEBPASSWORD="" \
        -e DNSMASQ_LISTENING="single" \
        -e ServerIP="${staticIP}" \
        --health-cmd "/run/current-system/sw/bin/dig @127.0.0.1 google.com +short || exit 1" \
        --health-interval 15s \
        --health-retries 3 \
        --health-start-period 30s \
        ${piholeImage}
    '';
  };

  ################################################################
  # Boot-time health check and rollback logic for OTA safety
  ################################################################
  systemd.services.pihole-boot-health = {
    description = "Boot-time health check for Pi-hole and bless/rollback decision";
    after = [ "network-online.target" "pihole-container.service" ];
    wants = [ "network-online.target" "pihole-container.service" ];
    serviceConfig = { Type = "oneshot"; RemainAfterExit = "no"; };
    script = ''
      #!/bin/sh
      set -e
      timeout=90
      elapsed=0
      interval=3
      while [ $elapsed -lt $timeout ]; do
        status=$(/run/current-system/sw/bin/podman inspect -f '{{.State.Health.Status}}' pihole 2>/dev/null || echo "unknown")
        if [ "$status" = "healthy" ]; then
          touch /run/ota-blessed
          exit 0
        fi
        sleep $interval
        elapsed=$((elapsed + interval))
      done
      /run/current-system/sw/bin/podman restart pihole || true
      sleep 5
      status=$(/run/current-system/sw/bin/podman inspect -f '{{.State.Health.Status}}' pihole 2>/dev/null || echo "unknown")
      if [ "$status" = "healthy" ]; then
        touch /run/ota-blessed
        exit 0
      fi
      if [ -d /boot/loader/entries ]; then
        entries=$(ls -1 /boot/loader/entries | sort -V)
        prev=$(echo "$entries" | tail -n2 | head -n1)
        if [ -n "$prev" ]; then
          /run/current-system/sw/bin/bootctl set-default "${prev%.conf}" || true
        fi
      fi
      /run/current-system/sw/bin/systemctl --no-block reboot
      exit 1
    '';
  };

  # Conditional runner: only run health check after OTA boots
  systemd.services.pihole-boot-health-condition = {
    description = "Conditional runner for pihole-boot-health (runs only when /run/ota-boot exists)";
    wants = [ "pihole-boot-health.service" ];
    after = [ "pihole-container.service" ];
    serviceConfig = { Type = "oneshot"; };
    script = ''
      #!/bin/sh
      if [ -f /run/ota-boot ]; then
        rm -f /run/ota-boot
        /run/current-system/sw/bin/systemctl start pihole-boot-health.service
      fi
    '';
    wantedBy = [ "multi-user.target" ];
  };

  ################################################################
  # OTA update service and timer (conservative, flake-based)
  ################################################################
  systemd.timers.ota-update = {
    description = "Periodic OTA update (flake inputs update + build new generation)";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnCalendar = "daily"; Persistent = true; };
  };

  systemd.services.ota-update = {
    description = "OTA update: flake input update and nixos-rebuild boot";
    wants = [ "network-online.target" ];
    after = [ "network-online.target" ];
    serviceConfig = { Type = "oneshot"; };
    script = ''
      #!/bin/sh
      set -e
      cd ${localFlake}
      /run/current-system/sw/bin/nix flake update --update-input nixpkgs || true
      /run/current-system/sw/bin/nixos-rebuild boot --flake "${localFlake}#rpi400"
      touch /run/ota-boot
      /run/current-system/sw/bin/systemctl --no-block reboot
    '';
  };

  systemd.services."ota-update".enable = true;
  systemd.timers."ota-update".enable = true;

  ################################################################
  # First-boot provisioning for non-technical users
  ################################################################
  # Place a file named /boot/first-boot.conf on the SD card before first boot:
  # PI_PASSWORD=MySecurePass123
  # WIFI_SSID=mycar
  # WIFI_PSK=1z2x3c4v5b
  # Optional: /boot/first-boot-ssh.pub with your SSH public key (one line)
  systemd.services.firstboot-provision = {
    description = "One-time first-boot provisioning (password + wifi + optional SSH key)";
    wantedBy = [ "multi-user.target" ];
    after = [ "local-fs.target" "network.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = "no";
      ConditionPathExists = "/boot/first-boot.conf";
    };
    script = ''
      #!/bin/sh
      set -e
      CONF=/boot/first-boot.conf
      SSHPUB=/boot/first-boot-ssh.pub
      PI_PASSWORD=$(grep -E '^PI_PASSWORD=' "$CONF" 2>/dev/null | cut -d'=' -f2- || true)
      WIFI_SSID=$(grep -E '^WIFI_SSID=' "$CONF" 2>/dev/null | cut -d'=' -f2- || true)
      WIFI_PSK=$(grep -E '^WIFI_PSK=' "$CONF" 2>/dev/null | cut -d'=' -f2- || true)
      if [ -n "$PI_PASSWORD" ]; then
        echo "pi:${PI_PASSWORD}" | /run/current-system/sw/bin/chpasswd || true
      fi
      if [ -f "$SSHPUB" ]; then
        mkdir -p /home/pi/.ssh
        cat "$SSHPUB" >> /home/pi/.ssh/authorized_keys
        chown -R 1000:1000 /home/pi/.ssh || true
        chmod 700 /home/pi/.ssh || true
        chmod 600 /home/pi/.ssh/authorized_keys || true
        rm -f "$SSHPUB"
      fi
      if [ -n "$WIFI_SSID" ] && [ -n "$WIFI_PSK" ]; then
        cat > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf <<EOF
ctrl_interface=DIR=/var/run/wpa_supplicant GROUP=netdev
update_config=1
country=IN
network={
  ssid="${WIFI_SSID}"
  psk="${WIFI_PSK}"
  key_mgmt=WPA-PSK
}
EOF
        chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
        /run/current-system/sw/bin/systemctl restart wpa_supplicant@wlan0.service || true
        /run/current-system/sw/bin/systemctl restart systemd-networkd.service || true
      fi
      rm -f "$CONF"
      exit 0
    '';
  };

  ################################################################
  # System stability and resource constraints
  ################################################################
  hardware.watchdog.enable = true;
  hardware.watchdog.device = "/dev/watchdog";

  services.zram = {
    enable = true;
    devices = 1;
    compressionAlgorithm = "lz4";
    size = "50%";
  };

  powerManagement.cpuFreqGovernor = "performance";

  systemd.journald.extraConfig = ''
    SystemMaxUse=50M
    RuntimeMaxUse=50M
    SystemKeepFree=10M
  '';

  services.printing.enable = false;
  services.avahi.enable = false;
  services.cups.enable = false;
  services.systemd-coredump.enable = false;

  services.openssh.enable = true;
  services.openssh.passwordAuthentication = false;
  services.openssh.permitRootLogin = "no";

  systemd.services."systemd-journald".serviceConfig = {
    MemoryLimit = "50M";
  };

  boot.kernelModules = [ "brcmfmac" ];

  services.ntp.enable = true;
  time.timeZone = "UTC";
}
