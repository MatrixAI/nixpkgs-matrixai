{ pkgs, publicLib }:
let
  nodejs = pkgs.nodejs_24;
  bridge = publicLib.npmBridge;
  urlMid = "git+ssh://git@example.invalid/fixture-mid.git";
  urlLow = "git+ssh://git@example.invalid/fixture-low.git";
  revMid = "1111111111111111111111111111111111111111";
  revOld = "2222222222222222222222222222222222222222";
  revNew = "3333333333333333333333333333333333333333";
  midDependencies = { fixture-low = "${urlLow}#v1.0.0"; };
  midManifest = {
    name = "fixture-mid";
    version = "1.0.0";
    main = "index.js";
    dependencies = midDependencies;
  };
  mkArchive = manifest: rev: js:
    (pkgs.runCommand "${manifest.name}-${manifest.version}.tgz" { } ''
      mkdir package
      cat > package/package.json <<'EOF'
      ${builtins.toJSON manifest}
      EOF
      cat > package/index.js <<'EOF'
      ${js}
      EOF
      tar -czf "$out" package
    '') // {
      npmPackage = {
        schemaVersion = 1;
        format = "npm-tgz";
        inherit (manifest) name version;
        dependencies = manifest.dependencies or { };
        peerDependencies = { };
        peerDependenciesMeta = { };
        optionalDependencies = { };
        engines = { };
        bin = { };
        source.rev = rev;
      };
      npmDistribution = {
        schemaVersion = 1;
        archiveOutput = "npm-package";
        runtimeProviders = [ ];
      };
    };
  midArchive = mkArchive midManifest revMid "module.exports = require('fixture-low');";
  mkInstallation = { version, rev, override ? false }:
    let
      lowManifest = { name = "fixture-low"; inherit version; main = "index.js"; };
      lowArchive = mkArchive lowManifest rev "module.exports = '${version}';";
      dependencies = {
        fixture-mid = "${urlMid}#v1.0.0";
        picocolors = "1.1.1";
      };
      package = {
        name = "fixture-consumer";
        version = "1.0.0";
        inherit dependencies;
      } // pkgs.lib.optionalAttrs override {
        overrides.fixture-mid.fixture-low = "${urlLow}#semver:^1.0.0";
      };
      packageLock = {
        name = package.name;
        version = package.version;
        lockfileVersion = 3;
        requires = true;
        packages = {
          "" = { inherit (package) name version dependencies; };
          "node_modules/fixture-mid" = {
            version = midManifest.version;
            resolved = "${urlMid}#${revMid}";
            dependencies = midDependencies;
          };
          "node_modules/fixture-low" = {
            inherit version;
            resolved = "${urlLow}#${rev}";
          };
          "node_modules/picocolors" = {
            version = "1.1.1";
            resolved = "https://registry.npmjs.org/picocolors/-/picocolors-1.1.1.tgz";
            integrity = "sha512-xceH2snhtb5M9liqDsmEw56le376mTZkEX/jEb/RxNFyegNul7eNslCXP9FDj/Lcu0X8KEyMceP2ntpaHrDEVA==";
          };
        };
      };
      npmSources = bridge.sources {
        system = pkgs.stdenv.hostPlatform.system;
        inherit packageLock;
        selections = {
          "node_modules/fixture-mid" = { name = "fixture-mid"; archive = midArchive; };
          "node_modules/fixture-low" = { name = "fixture-low"; archive = lowArchive; };
        };
      };
      npmDependencies = bridge.dependencies { inherit pkgs nodejs package packageLock npmSources; };
      src = pkgs.runCommand "npm-bridge-consumer-source" { } ''
        mkdir "$out"
        cat > "$out/package.json" <<'EOF'
        ${builtins.toJSON package}
        EOF
        cat > "$out/package-lock.json" <<'EOF'
        ${builtins.toJSON packageLock}
        EOF
      '';
    in
    pkgs.buildNpmPackage {
      pname = "npm-bridge-consumer";
      inherit version nodejs src;
      inherit (npmDependencies) npmDeps npmConfigHook;
      dontNpmBuild = true;
      dontFixup = true;
      installPhase = ''
        cmp package.json ${src}/package.json
        cmp package-lock.json ${src}/package-lock.json
        node -e "const assert = require('node:assert/strict'); assert.equal(require('fixture-mid'), '${version}'); assert.equal(require('picocolors').green('ok').includes('ok'), true)"
        mkdir -p "$out"
        cp node_modules/fixture-low/package.json "$out/installed-provider.json"
      '';
    };
  original = mkInstallation { version = "1.0.0"; rev = revOld; };
  updated = mkInstallation { version = "1.1.0"; rev = revNew; override = true; };
in
pkgs.runCommand "npm-bridge-install-check" { } ''
  mkdir -p "$out"
  cp ${original}/installed-provider.json "$out/original.json"
  cp ${updated}/installed-provider.json "$out/updated.json"
''
