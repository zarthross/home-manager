{
  config,
  lib,
  pkgs,
  ...
}:

with lib;

let

  cfg = config.programs.ghorg;

  yamlFormat = pkgs.formats.yaml { };

  confType = types.submodule {
    freeformType = yamlFormat.type;
    options = {

    };
  };

  recloneType = types.submodule {
    freeformType = yamlFormat.type;
    options = {

    };
  };

in
{
  meta.maintainers = [ maintainers.zarthross ];

  options.programs.ghorg = {
    enable = mkEnableOption "Ghorg: Quickly clone an entire org/users repositories.";

    package = mkOption {
      type = types.package;
      default = pkgs.ghorg;
      defaultText = literalExpression "pkgs.ghorg";
      description = lib.mdDoc "Package providing {command}`ghorg`.";
    };

    conf = mkOption {
      type = confType;
      default = { };
      description = lib.mdDoc "Configuration written to {file}`$XDG_CONFIG_HOME/ghorg/conf.yaml`. See https://github.com/gabrie30/ghorg#configuration";
      example = literalExpression ''
        {
          GHORG_SCM_TYPE = "github";
          GHORG_CLONE_PROTOCOL = "https";
          GHORG_CONCURRENCY = "25";
        }
      '';
    };

    reclone = mkOption {
      type = recloneType;
      default = { };
      description = lib.mdDoc "Reclone Configuration written to {file}`$XDG_CONFIG_HOME/ghorg/reclone.yaml`. See https://github.com/gabrie30/ghorg#reclone-command";
      example = literalExpression ''
        {
          "nix-community" = {
            cmd = "ghorg clone nix-community";
            description = "A project incubator that works in parallel of the @NixOS org";
          };
          "nixos".cmd = "ghorg clone NixOS";
        }
      '';
    };
  };

  config = mkIf cfg.enable {
    home.packages = [ cfg.package ];

    xdg.configFile = {
      "ghorg/conf.yaml".source = yamlFormat.generate "ghorg-conf.yaml" cfg.conf;
      "ghorg/reclone.yaml".source = yamlFormat.generate "ghorg-reclone.yaml" cfg.reclone;
    };
  };
}
