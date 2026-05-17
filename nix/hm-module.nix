self:
{ config, lib, pkgs, ... }:

let
  cfg = config.programs.cliphizt;

  toConfigFile = s: pkgs.writeText "cliphizt-config" ''
    max-items ${toString s.max-items}
    max-dedupe-search ${toString s.max-dedupe-search}
    min-store-length ${toString s.min-store-length}
    preview-width ${toString s.preview-width}
    max-store-size ${s.max-store-size}
    ephemeral-ttl ${s.ephemeral-ttl}
    persist-mode ${if s.persist-mode then "true" else "false"}
    ${lib.optionalString (s.db-path != "") "db-path ${s.db-path}"}
  '';
in {
  options.programs.cliphizt = {
    enable = lib.mkEnableOption "cliphizt clipboard history manager";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
      defaultText = lib.literalExpression "cliphizt";
      description = "The cliphizt package to use.";
    };

    settings = lib.mkOption {
      description = "Configuration written to \$XDG_CONFIG_HOME/cliphizt/config.";
      default = {};
      type = lib.types.submodule {
        options = {
          max-items = lib.mkOption {
            type = lib.types.ints.positive;
            default = 750;
            description = "Maximum number of history entries to keep.";
          };

          max-dedupe-search = lib.mkOption {
            type = lib.types.ints.positive;
            default = 100;
            description = "Number of recent entries to scan for duplicates on store.";
          };

          min-store-length = lib.mkOption {
            type = lib.types.ints.unsigned;
            default = 0;
            description = "Minimum codepoint count required to store an entry.";
          };

          preview-width = lib.mkOption {
            type = lib.types.ints.positive;
            default = 100;
            description = "Maximum grapheme cluster width of list preview text.";
          };

          max-store-size = lib.mkOption {
            type = lib.types.str;
            default = "5MiB";
            example = "10MiB";
            description = "Maximum byte size of a single entry. Accepts KiB/MiB/GiB suffixes.";
          };

          db-path = lib.mkOption {
            type = lib.types.str;
            default = "";
            example = "/home/user/.local/share/cliphizt/db";
            description = "Override database path. Defaults to \$XDG_CACHE_HOME/cliphizt/db.";
          };

          ephemeral-ttl = lib.mkOption {
            type = lib.types.str;
            default = "1h";
            example = "30m";
            description = "TTL applied to entries stored while in ephemeral mode. Accepts s/m/h/d/w units and compound forms like 1h30m.";
          };

          persist-mode = lib.mkOption {
            type = lib.types.bool;
            default = false;
            description = "Persist mode across reboots via \$XDG_STATE_HOME/cliphizt/mode.";
          };
        };
      };
    };

    systemdService = {
      enable = lib.mkEnableOption "systemd user service that watches the clipboard with wl-paste";

      extraStoreArgs = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [];
        example = [ "--ttl" "1h" ];
        description = "Extra arguments appended to every cliphizt store invocation.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ cfg.package ];

    xdg.configFile."cliphizt/config".source = toConfigFile cfg.settings;

    systemd.user.services.cliphizt-watch = lib.mkIf cfg.systemdService.enable {
      Unit = {
        Description = "Wayland clipboard history manager (cliphizt)";
        PartOf = [ "graphical-session.target" ];
        After = [ "graphical-session.target" ];
      };
      Service = {
        Type = "simple";
        ExecStart = lib.escapeShellArgs (
          [ "${pkgs.wl-clipboard}/bin/wl-paste" "--watch" "${lib.getExe cfg.package}" "store" ]
          ++ cfg.systemdService.extraStoreArgs
        );
        Restart = "on-failure";
        KillSignal = "SIGINT";
      };
      Install = {
        WantedBy = [ "graphical-session.target" ];
      };
    };
  };
}
