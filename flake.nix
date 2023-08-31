{
  description = "Nextcloud running in a container";

  inputs = {
    nixpkgs.url = "nixpkgs/nixos-23.05";
    arion.url = "github:hercules-ci/arion";
  };

  outputs = { self, nixpkgs, arion, ... }: {
    nixosModules = rec {
      default = nextcloudContainer;
      nextcloudContainer = { ... }: {
        imports = [ arion.nixosModules.arion ./nextcloud-container.nix ];
      };
    };
  };
}
