{ lib
, system
, pkgs
, publicLib
, defaultOverlay
, topLevelPackages
, legacyPackages
, nixosModulesSet
, homeModulesSet
, templatesSet
}:

{
  "contract-outputs" = import ./contract-outputs.nix {
    inherit
      system
      pkgs
      publicLib
      defaultOverlay
      topLevelPackages
      legacyPackages
      templatesSet
      ;
  };

  "contract-packages" = import ./contract-packages.nix {
    inherit lib pkgs topLevelPackages legacyPackages;
  };

  "contract-modules" = import ./contract-modules.nix {
    inherit lib system pkgs nixosModulesSet homeModulesSet;
  };

  "policy-pin" = import ./policy-pin.nix {
    inherit pkgs;
  };

  "smoke-hello" = import ./smoke-hello.nix {
    inherit pkgs topLevelPackages legacyPackages;
  };

  "smoke-vl-convert" = import ./smoke-vl-convert.nix {
    inherit pkgs topLevelPackages legacyPackages;
  };
}
