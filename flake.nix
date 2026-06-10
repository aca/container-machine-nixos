{
  description = "NixOS image for Apple container machine";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";

  outputs = { nixpkgs, ... }:
    let
      system = "aarch64-linux";
      pkgs = import nixpkgs { inherit system; };
      lib = nixpkgs.lib;
      macCommand = pkgs.writeShellScriptBin "mac" ''
        set -euo pipefail

        host="''${MAC_HOST:-192.168.64.1}"
        port="''${MAC_PORT:-2222}"
        user="''${MAC_USER:-''${CONTAINER_USER:-}}"

        if [ -z "$user" ]; then
          user="$(${pkgs.gawk}/bin/awk -F: '$3 >= 501 && $3 < 60000 { print $1; exit }' /etc/passwd)"
        fi

        ssh_args=(
          -p "$port"
          -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null
          -o LogLevel=ERROR
        )

        ssh_cmd=("${pkgs.openssh}/bin/ssh")
        if [ -n "''${MAC_PASSWORD:-}" ]; then
          ssh_cmd=("${pkgs.sshpass}/bin/sshpass" -p "$MAC_PASSWORD" ${pkgs.openssh}/bin/ssh)
        elif ! [ -t 0 ] || ! [ -t 1 ]; then
          ssh_args+=(-o BatchMode=yes)
        fi

        if [ $# -eq 0 ]; then
          if [ -t 0 ] && [ -t 1 ]; then
            exec "''${ssh_cmd[@]}" "''${ssh_args[@]}" -t "$user@$host"
          fi
          exec "''${ssh_cmd[@]}" "''${ssh_args[@]}" "$user@$host"
        fi

        remote_cmd=
        if [ -n "''${PWD:-}" ]; then
          printf -v quoted_pwd '%q' "$PWD"
          remote_cmd="cd $quoted_pwd 2>/dev/null || true; "
        fi

        for arg in "$@"; do
          printf -v quoted_arg '%q' "$arg"
          remote_cmd+=" $quoted_arg"
        done

        exec "''${ssh_cmd[@]}" "''${ssh_args[@]}" "$user@$host" "$remote_cmd"
      '';

      nixos = lib.nixosSystem {
        inherit system;
        modules = [
          ({ pkgs, ... }: {
            boot.isContainer = true;
            networking.hostName = "nixos";

            # This is the NixOS state/default compatibility version, not the
            # systemd package version. Keep it explicit because it controls
            # defaults for stateful services across rebuilds.
            system.stateVersion = "26.05";

            environment.systemPackages = [
              macCommand
            ] ++ (with pkgs; [
              bashInteractive
              coreutils
              curl
              dbus
              findutils
              gawk
              gnugrep
              gnused
              iproute2
              iputils
              less
              man
              nettools
              nix
              openssh
              procps
              shadow
              sudo
              systemd
              util-linux
              vim
              wget
            ]);

            # Apple `container machine run` does not exec the guest command
            # directly. It first enters Apple's mounted `/sbin.machine/init`,
            # resolves the user's login shell from `/etc/passwd`, and then runs
            # that shell with a mostly FHS-style PATH. On NixOS that PATH misses
            # `/run/current-system/sw/bin`, so plain commands such as `whoami`
            # or `nixos-rebuild` fail unless the shell fixes PATH first.
            #
            # NixOS also rejects a store path as `users.defaultUserShell`,
            # because `/etc/passwd` should point at a stable path outside the
            # store. `/etc/machine/shell` is that stable wrapper.
            users.defaultUserShell = "/etc/machine/shell";
            users.users.root.shell = "/etc/machine/shell";

            nix.settings.experimental-features = [
              "nix-command"
              "flakes"
            ];

            programs.bash.interactiveShellInit = ''
              export PATH=/run/wrappers/bin:/run/current-system/sw/bin:$PATH
            '';

            # NixOS packages are not installed into `/usr/bin` or `/bin`.
            # These links are deliberately not a package-wide FHS mirror. They
            # are the minimum commands Apple's mounted `/sbin.machine/init`
            # expects before the NixOS shell wrapper has a chance to run:
            #
            # - `id`, `grep`, and `cut` are used to resolve the container user.
            # - `chown` is used by Apple's first-boot user setup.
            # - `env` and `/bin/sh` cover common script shebang assumptions.
            #
            # The links are refreshed on activation so `nixos-rebuild switch`
            # keeps a working `container machine run` entrypoint.
            system.activationScripts.containerMachineCompatLinks = ''
              ${pkgs.coreutils}/bin/mkdir -p /usr/bin /bin
              ${pkgs.coreutils}/bin/ln -sfn /run/current-system/sw/bin/env /usr/bin/env
              ${pkgs.coreutils}/bin/ln -sfn /run/current-system/sw/bin/chown /usr/bin/chown
              ${pkgs.coreutils}/bin/ln -sfn /run/current-system/sw/bin/cut /usr/bin/cut
              ${pkgs.coreutils}/bin/ln -sfn /run/current-system/sw/bin/id /usr/bin/id
              ${pkgs.coreutils}/bin/ln -sfn /run/current-system/sw/bin/grep /usr/bin/grep
              ${pkgs.coreutils}/bin/ln -sfn /run/current-system/sw/bin/sh /bin/sh
            '';

            # `users.mutableUsers` is left at the NixOS default because Apple
            # injects the macOS user by editing `/etc/passwd` on first setup.
            # With mutable users, NixOS does not always rewrite existing user
            # records on activation. Keep the shell field aligned explicitly so
            # Apple's wrapper keeps entering `/etc/machine/shell` after
            # rebuilds and restarts.
            system.activationScripts.containerMachineUserShells = lib.stringAfter [ "etc" "users" "groups" ] ''
              shell=/etc/machine/shell
              tmp=/etc/passwd.container-machine

              ${pkgs.gawk}/bin/awk -F: -v OFS=: -v shell="$shell" '
                $1 == "root" || ($3 >= 501 && $3 < 60000) { $7 = shell }
                { print }
              ' /etc/passwd > "$tmp"

              ${pkgs.coreutils}/bin/mv "$tmp" /etc/passwd
            '';

            security.sudo.enable = true;
            security.sudo.extraConfig = ''
              ALL ALL=(ALL:ALL) NOPASSWD: ALL
            '';

            environment.etc = {
              "machine/shell" = {
                mode = "0755";
                text = ''
                  #!${pkgs.runtimeShell}
                  # This is the login shell recorded in `/etc/passwd`.
                  # It repairs PATH for non-interactive `container machine run`
                  # commands, then delegates to normal interactive Bash.
                  export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                  exec ${pkgs.bashInteractive}/bin/bash "$@"
                '';
              };

              "machine/create-user.sh" = {
                mode = "0755";
                text = ''
                  #!${pkgs.runtimeShell}
                  # Apple prefers `/etc/machine/create-user.sh` over its built
                  # in `/sbin.machine/create-user.sh`. Keep Apple's user setup
                  # behavior, but run it after adding the NixOS system PATH so
                  # commands like `getent`, `mkdir`, `cp`, and `chmod` resolve.
                  export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
                  exec /sbin.machine/create-user.sh "$@"
                '';
              };
            };

            services.dbus.enable = true;
            services.openssh.enable = true;
            services.openssh.settings.PermitRootLogin = "prohibit-password";

            systemd.services.console-getty.enable = false;
            systemd.services.systemd-update-utmp.enable = false;

            # Apple mounts the host home directory after the root filesystem is
            # assembled. The injected container user may exist before ownership
            # on `/Users/<name>` is correct, so fix it once systemd reaches the
            # local-filesystem stage. Failures are ignored because the mount may
            # be read-only or unavailable depending on machine settings.
            systemd.services.container-machine-home-owner = {
              description = "Fix Apple container-machine home mount owner";
              wantedBy = [ "multi-user.target" ];
              before = [ "multi-user.target" ];
              after = [ "local-fs.target" ];
              path = [
                pkgs.coreutils
                pkgs.gawk
              ];
              serviceConfig.Type = "oneshot";
              script = ''
                awk -F: '$3 >= 501 && $3 < 60000 { print $1 ":" $3 ":" $4 }' /etc/passwd |
                  while IFS=: read -r name uid gid; do
                    if [ -d "/Users/$name" ]; then
                      chown "$uid:$gid" "/Users/$name" 2>/dev/null || true
                    fi
                  done
              '';
            };
          })
        ];
      };

      imageRoot = pkgs.runCommand "nixos-container-machine-root" { } ''
        mkdir -p $out
        cd $out

        # Build the small mutable-looking root that Apple `container machine`
        # expects around the immutable NixOS closure. The real packages still
        # live in `/nix/store` and are exposed through `/run/current-system/sw`.
        mkdir -p bin dev home proc root run sbin sys tmp usr/bin usr/sbin var/lib/dbus var/tmp
        chmod 1777 tmp var/tmp

        # Copy `/etc` out of the NixOS system closure so Apple can inject its
        # generated user and sudoers files. Some files are symlinks in a normal
        # NixOS system, so dereference the account databases before first boot.
        cp -a "$(readlink -f ${nixos.config.system.build.toplevel}/etc)" etc
        chmod -R u+w etc || true

        for file in passwd group shadow gshadow subuid subgid; do
          if [ -e "etc/$file" ] || [ -L "etc/$file" ]; then
            cp -L "etc/$file" "etc/$file.tmp"
            mv -f "etc/$file.tmp" "etc/$file"
            chmod u+w "etc/$file"
          fi
        done

        cat > sbin/init <<'EOF'
        #!${pkgs.runtimeShell}
        set -eu
        export container=container
        export PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin

        # In a normal NixOS boot, the bootloader chooses a generation and
        # systemd starts with `/run/current-system` already pointing to it.
        # Apple `container machine` has no NixOS bootloader, and `/run` is a
        # fresh tmpfs on every boot. If `nixos-rebuild switch` has run before,
        # the persistent profile below points at the latest generation. Use it
        # so package additions survive a stop/start cycle; otherwise fall back
        # to the system closure baked into the image.
        system_profile=/nix/var/nix/profiles/system
        default_system=${nixos.config.system.build.toplevel}

        if [ -e "$system_profile" ]; then
          current_system="$(${pkgs.coreutils}/bin/readlink -f "$system_profile")"
        else
          current_system="$default_system"
        fi

        # Recreate the volatile `/run/current-system` link before activation so
        # activation scripts, wrappers, and PATH entries all resolve against the
        # chosen generation.
        ${pkgs.coreutils}/bin/ln -sfn "$current_system" /run/current-system
        "$current_system/activate"

        # The local macOS user is injected by Apple. Make the host home mount
        # usable from the guest user after activation, when `/etc/passwd` is in
        # its final state for this boot.
        awk -F: '$3 >= 501 && $3 < 60000 { print $1 ":" $3 ":" $4 }' /etc/passwd |
          while IFS=: read -r name uid gid; do
            if [ -d "/Users/$name" ]; then
              chown "$uid:$gid" "/Users/$name" 2>/dev/null || true
            fi
          done

        # Start systemd as PID 1. This is the systemd from the image build; the
        # activated generation provides the rest of the running system through
        # `/run/current-system`.
        exec ${nixos.config.systemd.package}/lib/systemd/systemd "$@"
        EOF
        sed -i 's/^        //' sbin/init
        chmod 0755 sbin/init
        ln -s sbin/init init
        ln -s ${nixos.config.system.build.toplevel} run/current-system

        # Bootstrap-only FHS compatibility for Apple's wrapper. Do not add a
        # broad `/run/current-system/sw/bin/*` mirror here; NixOS packages are
        # meant to be reached through PATH, not copied into `/usr/bin`.
        ln -sf ${pkgs.runtimeShell} bin/sh
        ln -sf ${pkgs.coreutils}/bin/env usr/bin/env
        ln -sf ${pkgs.coreutils}/bin/chown usr/bin/chown
        ln -sf ${pkgs.coreutils}/bin/cut usr/bin/cut
        ln -sf ${pkgs.coreutils}/bin/id usr/bin/id
        ln -sf ${pkgs.gnugrep}/bin/grep usr/bin/grep

        rm -f etc/machine-id
        : > etc/machine-id
        rm -f var/lib/dbus/machine-id
        : > var/lib/dbus/machine-id
      '';

      image = pkgs.dockerTools.buildLayeredImage {
        name = "local/nixos-machine";
        tag = "latest";
        created = "now";
        contents = [
          imageRoot
          nixos.config.system.build.toplevel
        ];
        config = {
          Cmd = [ "/sbin/init" ];
          Env = [
            "container=container"
            "PATH=/run/wrappers/bin:/run/current-system/sw/bin:/usr/bin:/bin"
          ];
          WorkingDir = "/";
        };
      };
    in
    {
      packages.${system} = {
        nixosContainerMachineImage = image;
        default = image;
      };
    };
}
