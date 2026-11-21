{
  pkgs,
  nodejs,
  src,
  setupDependencies,
}:
let
  buildSource = pkgs.lib.cleanSourceWith {
    inherit src;
    filter =
      path: _type:
      let
        relative = pkgs.lib.removePrefix "${toString src}/" (toString path);
      in
      !(builtins.elem relative [
        "tests"
        "specs"
        "nix/checks"
        "playwright.config.ts"
      ]);
  };
in
pkgs.stdenv.mkDerivation {
  pname = "npm-build";
  version = "0";
  src = buildSource;
  nativeBuildInputs = [ nodejs ];
  buildPhase = ''
    runHook preBuild
    ${setupDependencies}
    npm run build
    runHook postBuild
  '';
  installPhase = ''
    runHook preInstall
    mkdir -p "$out"
    cp -R dist "$out/dist"
    runHook postInstall
  '';
}
