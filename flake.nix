{
  description = "beryl-utils: user scripts + wayland user units, exposed as a flake";

  inputs.nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-26.05-chilled/0.1";

  outputs = {
    self,
    nixpkgs,
  }: let
    inherit (nixpkgs) lib;

    # systems this flake builds for
    forAllSystems = f:
      nixpkgs.lib.genAttrs nixpkgs.lib.systems.flakeExposed
      (system: f nixpkgs.legacyPackages.${system});

    # ponytail: manifest is the single source of truth, shared with install.sh.
    # columns: src|role|outname|install_links|home_dest
    # src is relative to assets/; name is the basename (unit names, store keys).
    manifestRows = let
      raw = lib.splitString "\n" (builtins.readFile ./assets/manifest);
      keep = lib.filter (l: l != "" && !lib.hasPrefix "#" l) raw;
    in
      map (l: let
        p = lib.splitString "|" l;
      in {
        src = builtins.elemAt p 0;
        name = baseNameOf (builtins.elemAt p 0);
        role = builtins.elemAt p 1;
        out = builtins.elemAt p 2;
        links = builtins.elemAt p 3;
        home = builtins.elemAt p 4;
      })
      keep;

    unitRows = lib.filter (m: m.role == "unit") manifestRows;
    desktopRows = lib.filter (m: m.role == "desktop") manifestRows;

    # core package: every script on PATH, gpu-detect in lib/, wl-watcher wrapped
    mkBerylUtils = pkgs:
      pkgs.stdenv.mkDerivation {
        pname = "beryl-utils";
        version = "unstable";

        # ponytail: copy the whole tree; the installPhase only grabs what it needs.
        # a fileset filter is overkill for a repo this small.
        src = ./.;

        # no compile step; we only arrange files
        dontBuild = true;

        installPhase = ''
          runHook preInstall
          mkdir -p "$out/bin" "$out/lib/beryl-utils"

          ${lib.concatMapStringsSep "\n" (
              m:
                if m.role == "bin"
                then ''
                  cp assets/${m.src} "$out/bin/${m.name}"
                  ${lib.optionalString (m.name != m.out) ''
                    ln -s "${m.name}" "$out/bin/${m.out}"
                  ''}
                ''
                else if m.role == "lib"
                then ''
                  cp assets/${m.src} "$out/bin/${m.out}"
                ''
                else if m.role == "pybin"
                then ''
                  cp assets/${m.src} "$out/lib/beryl-utils/${m.out}"
                  # ponytail: echo (not a heredoc) keeps the wrapper robust inside the
                  # generated installPhase; ${pkgs.python3} is resolved at eval time.
                  echo '#!/bin/sh' > "$out/bin/${m.out}"
                  echo "exec ${pkgs.python3}/bin/python3 \"$out/lib/beryl-utils/${m.out}\" \"\$@\"" >> "$out/bin/${m.out}"
                  chmod +x "$out/bin/${m.out}"
                ''
                else ""
            )
            manifestRows}

          chmod +x "$out/bin"/* "$out/lib/beryl-utils"/*

          runHook postInstall
        '';

        meta = {
          description = "Desktop/wayland helper scripts and user units";
          mainProgram = "wl-watcher";
        };
      };

    # patch the user units: fix ExecStart to the store bins and drop the
    # hardcoded %h/.local/bin/gamemode hooks in favour of a PATH-resolved gamemode
    patchUnit = pkg: f:
      builtins.replaceStrings
      [
        "/usr/local/bin/uwsm-mangohud.sh"
        "/usr/local/bin/wl-watcher"
        "%h/.local/bin/gamemode"
      ]
      [
        "${pkg}/bin/uwsm-mangohud"
        "${pkg}/bin/wl-watcher"
        "gamemode"
      ]
      (builtins.readFile f);

    unitsFor = pkg:
      builtins.listToAttrs (
        map (m: lib.nameValuePair m.name (patchUnit pkg ./assets/${m.src})) unitRows
      );

    homeModule = {
      lib,
      pkgs,
      config,
      ...
    }: let
      pkg = mkBerylUtils pkgs;
      units = unitsFor pkg;
    in {
      options.beryl-utils = {
        enable = lib.mkEnableOption "beryl-utils";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkg;
          description = "The beryl-utils package to install.";
        };
      };

      config = lib.mkIf config.beryl-utils.enable {
        home.packages = [config.beryl-utils.package];

        systemd.user.services = builtins.listToAttrs (
          map (m:
            lib.nameValuePair (lib.removeSuffix ".service" m.name) {
              enable = true;
              text = units.${m.name};
            })
          unitRows
        );

        # ponytail: desktop/data files are symlinked into $HOME via home.file;
        # the store package derivation can't own $HOME paths, but the
        # home-manager module can.
        home.file = builtins.listToAttrs (
          map (m: lib.nameValuePair "${m.home}/${m.out}" {source = ./assets/${m.src};})
          desktopRows
        );
      };
    };

    nixosModule = {
      lib,
      pkgs,
      config,
      ...
    }: let
      pkg = mkBerylUtils pkgs;
      units = unitsFor pkg;
    in {
      options.beryl-utils = {
        enable = lib.mkEnableOption "beryl-utils";
        package = lib.mkOption {
          type = lib.types.package;
          default = pkg;
          description = "The beryl-utils package to install.";
        };
        users = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [];
          description = "Users who should receive the package on their PATH.";
        };
      };

      config = lib.mkIf config.beryl-utils.enable {
        environment.systemPackages = [config.beryl-utils.package];

        # ponytail: global preset + --global enable is the only mechanism
        # NixOS has for auto-enabling *user* units. Ceiling: enables for all
        # users, not just `users`; scope package availability via `users`.
        environment.etc = lib.mkMerge [
          (builtins.listToAttrs (
            map (m:
              lib.nameValuePair "systemd/user/${m.name}" {
                text = units.${m.name};
              })
            unitRows
          ))
          {
            "systemd/user-preset/beryl-utils.preset".text =
              lib.concatMapStringsSep "\n" (m: "enable ${m.name}") unitRows;
          }
        ];

        system.activationScripts.beryl-utils-enable = ''
          ${pkgs.systemd}/bin/systemctl --global daemon-reload 2>/dev/null || true
          ${pkgs.systemd}/bin/systemctl --global preset ${
            lib.concatMapStringsSep " " (m: m.name) unitRows
          } 2>/dev/null || true
        '';

        # ponytail: desktop/data symlinks for NixOS users require home-manager
        # for those users; ceiling if a listed user is unmanaged.
        users.users = builtins.listToAttrs (
          map (u:
            lib.nameValuePair u {
              packages = [config.beryl-utils.package];
              home.file = builtins.listToAttrs (
                map (m:
                  lib.nameValuePair "${m.home}/${m.out}" {
                    source = ./assets/${m.src};
                  })
                desktopRows
              );
            })
          config.beryl-utils.users
        );
      };
    };
  in {
    lib = {inherit mkBerylUtils unitsFor;};

    packages = forAllSystems (pkgs: {default = mkBerylUtils pkgs;});

    homeManagerModules.default = homeModule;
    nixosModules.default = nixosModule;

    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
        buildInputs = [
          pkgs.bats
          pkgs.shfmt
          pkgs.shellcheck
          (pkgs.writeShellScriptBin "localfmt" "exec shfmt -w -s -i 2 assets/scripts/*.sh assets/scripts/*.bats")
          (pkgs.writeShellScriptBin "locallint" "exec shellcheck assets/scripts/*.sh assets/scripts/*.bats")
          (pkgs.writeShellScriptBin "localbuild" "exec nix build .#default")
        ];
      };
    });
  };
}
