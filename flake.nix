{
  description = "beryl-utils: user scripts + wayland user units, exposed as a flake";

  inputs.nixpkgs.url = "https://flakehub.com/f/DeterminateSystems/nixpkgs-26.05-chilled/0.1";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }: let
    inherit (nixpkgs) lib;
    inherit (flake-utils.lib) eachDefaultSystem;

    # ponytail: manifest is the single source of truth, shared with install.sh.
    # columns: src|role|outname|install_links|home_dest
    # src is relative to assets/; name is the basename (unit names, store keys).
    manifestRows = let
      raw = lib.splitString "\n" (builtins.readFile ./assets/manifest);
      keep = lib.filter (l: l != "" && !lib.hasPrefix "#" l) raw;
    in
      map (
        l: let
          p = lib.splitString "|" l;
        in {
          src = builtins.elemAt p 0;
          name = baseNameOf (builtins.elemAt p 0);
          role = builtins.elemAt p 1;
          out = builtins.elemAt p 2;
          links = builtins.elemAt p 3;
          home = builtins.elemAt p 4;
        }
      )
      keep;

    unitRows = lib.filter (m: m.role == "unit") manifestRows;
    desktopRows = lib.filter (m: m.role == "desktop") manifestRows;
    binRows = lib.filter (m: m.role != "unit" && m.role != "desktop") manifestRows;

    # core package: every script on PATH (gpu-detect.sh included; it is
    # sourced, not exec'd), wl-watcher wrapped
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

          # ponytail: cp preserves git exec bits; the pybin wrapper above is the
          # only generated file and it chmods itself.

          runHook postInstall
        '';

        meta = {
          description = "Desktop/wayland helper scripts and user units";
          mainProgram = "wl-watcher";
        };
      };

    # patch the user units: fix ExecStart to the store bins and drop the
    # hardcoded %h/.local/bin/gamemode hooks in favour of a PATH-resolved gamemode.
    # ponytail: replacement pairs are derived from the manifest (name = src
    # basename, out = installed name), so new bin rows get patched for free.
    patchUnit = pkg: f: let
      storeBin = m: "${pkg}/bin/${m.out}";
    in
      builtins.replaceStrings (
        ["%h/.local/bin/gamemode"]
        ++ map (m: "/usr/local/bin/${m.name}") binRows
        ++ map (m: "/usr/local/bin/${m.out}") binRows
        ++ map (m: "%h/.local/bin/${m.name}") binRows
        ++ map (m: "%h/.local/bin/${m.out}") binRows
      ) (["gamemode"] ++ map storeBin binRows ++ map storeBin binRows ++ map storeBin binRows ++ map storeBin binRows) (builtins.readFile f);

    unitsFor = pkg:
      builtins.listToAttrs (map (m: lib.nameValuePair m.name (patchUnit pkg ./assets/${m.src})) unitRows);

    # desktop/data files: $HOME-relative path -> source
    # ponytail: symlinked into $HOME via home.file; the store package derivation
    # can't own $HOME paths, but a home-manager module can.
    desktopFileMap = builtins.listToAttrs (
      map (m: lib.nameValuePair "${m.home}/${m.out}" {source = ./assets/${m.src};}) desktopRows
    );

    # shared beryl-utils options
    berylOptions = pkg: {
      enable = lib.mkEnableOption "beryl-utils";
      package = lib.mkOption {
        type = lib.types.package;
        default = pkg;
        description = "The beryl-utils package to install.";
      };
    };

    homeModule = {
      lib,
      pkgs,
      config,
      ...
    }: let
      cfg = config.beryl-utils;
      pkg = mkBerylUtils pkgs;
    in {
      options.beryl-utils = berylOptions pkg;

      # ponytail: units are patched against beryl-utils.package (not the
      # default), so an overridden package gets correctly-patched ExecStarts.
      config = lib.mkIf cfg.enable (
        let
          units = unitsFor cfg.package;
        in {
          home.packages = [cfg.package];
          home.file =
            desktopFileMap
            // builtins.listToAttrs (
              map (
                m:
                  lib.nameValuePair ".config/systemd/user/${m.name}" {
                    text = units.${m.name};
                  }
              )
              unitRows
            );
        }
      );
    };

    nixosModule = {
      lib,
      pkgs,
      config,
      ...
    }: let
      cfg = config.beryl-utils;
      pkg = mkBerylUtils pkgs;
    in {
      options.beryl-utils = berylOptions pkg;

      config = lib.mkIf cfg.enable (
        let
          units = unitsFor cfg.package;
        in {
          environment.systemPackages = [cfg.package];

          # ponytail: the platform option installs the units into
          # /etc/systemd/user (where environment.etc used to put them) and
          # handles enable/text for us. Enabling is inherently per-user, so
          # there is no auto-enable and no user list in this flake: once per
          # user, `systemctl --user enable` the units.
          systemd.user.units = lib.mapAttrs (_: text: {inherit text;}) units;
        }
      );
    };

    perSystem = system: let
      pkgs = nixpkgs.legacyPackages.${system};
    in {
      packages = {
        default = mkBerylUtils pkgs;
      };

      devShells = {
        default = pkgs.mkShell {
          buildInputs = [
            pkgs.bats
            pkgs.shfmt
            pkgs.shellcheck
            # ponytail: find, so new .sh files anywhere under assets/ are covered
            (pkgs.writeShellScriptBin "localfmt" "exec shfmt -w -s -i 2 $(find assets -name '*.sh' -o -name '*.bats')")
            (pkgs.writeShellScriptBin "locallint" "exec shellcheck $(find assets -name '*.sh' -o -name '*.bats')")
            (pkgs.writeShellScriptBin "localbuild" "exec nix build .#default")
          ];
        };
      };
    };
  in
    # ponytail: parens are load-bearing — `//` binds tighter than function
    # application, so without them the module maps would land inside each
    # system key and `.homeManagerModules.default` would be null.
    (eachDefaultSystem perSystem)
    // {
      homeManagerModules = {
        default = homeModule;
      };
      nixosModules = {
        default = nixosModule;
      };
    };
}
