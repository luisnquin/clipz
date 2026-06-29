self: {
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.programs.cliplenz;
  basePackage = self.packages.${pkgs.stdenv.hostPlatform.system}.cliplenz;
in {
  options.programs.cliplenz = {
    enable = lib.mkEnableOption "cliplenz native clipboard viewer";

    package = lib.mkOption {
      type = lib.types.package;
      default = basePackage;
      defaultText = lib.literalExpression "cliplenz";
      description = "The cliplenz package to use, before `fonts` is applied.";
    };

    fonts = lib.mkOption {
      type = lib.types.listOf lib.types.package;
      default = [pkgs.cascadia-code pkgs.dejavu_fonts];
      defaultText = lib.literalExpression "[ pkgs.cascadia-code pkgs.dejavu_fonts ]";
      example = lib.literalExpression ''
        [ pkgs.cascadia-code pkgs.dejavu_fonts pkgs.noto-fonts-cjk-sans pkgs.noto-fonts-color-emoji ]
      '';
      description = ''
        Fonts cliplenz may load. cliplenz scans every directory its fontconfig
        points at on first render; restricting the set to these packages bounds
        the 1-3s cold start and keeps rendering reproducible. Order matters: the
        first entry is the source of truth for the interface font (see
        `defaultFont`); later entries widen preview coverage. The default's
        Cascadia Code drives the UI and DejaVu covers Latin/Cyrillic/Greek/
        symbols in the preview pane. Add CJK / emoji packages for full preview
        coverage at the cost of a slower cold start.
      '';
    };

    defaultFont = lib.mkOption {
      type = lib.types.str;
      default = "";
      example = "DejaVu Sans Mono";
      description = ''
        Interface font family. Empty (the default) derives it from the first
        entry of `fonts`, so the list stays the single source of truth. Set a
        family name to override when the first package ships several families.
        Override per-invocation with `--font <family>`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [(cfg.package.override {inherit (cfg) fonts defaultFont;})];
  };
}
