{
  pkgs,
  nodejs ? pkgs.nodejs_24,
  packageName,
  sources,
}:
let
  plan = pkgs.writeText "npm-source-overrides.json" (
    builtins.toJSON {
      inherit packageName;
      sources = builtins.mapAttrs (_: source: source // { archive = toString source.archive; }) sources;
    }
  );
in
pkgs.writeShellApplication {
  name = "npm";
  runtimeInputs = [ nodejs ];
  text = ''
    export PATH="''${0%/*}:$PATH"
    exec ${nodejs}/bin/node ${./install.mjs} \
      ${nodejs}/bin/npm ${pkgs.util-linux}/bin/flock ${plan} "$@"
  '';
}
