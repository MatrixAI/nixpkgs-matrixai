{
  system,
  packageLock,
  selections,
}:
let
  validOutput =
    value: builtins.isString value && builtins.match "[A-Za-z0-9_+-][A-Za-z0-9._+-]*" value != null;
  validProvider =
    provider:
    let
      source = provider.source or { };
      remote = builtins.match "git[+](ssh|https)://([^/?#[:space:]]+)(/[^?#[:space:]]+)" source.url;
      user = builtins.match "([^@]+)@.*" (builtins.elemAt remote 1);
    in
    builtins.isAttrs provider
    && builtins.isString (provider.name or null)
    && provider.name != ""
    && builtins.isString (provider.version or null)
    && builtins.match "[0-9]+[.][0-9]+[.][0-9]+([-+][0-9A-Za-z.+-]+)?" provider.version != null
    && builtins.isAttrs source
    && builtins.isString (source.url or null)
    && remote != null
    && (
      user == null
      || (
        builtins.elemAt remote 0 == "ssh"
        && builtins.match "[A-Za-z0-9._-]+" (builtins.elemAt user 0) != null
      )
    )
    && builtins.isString (source.rev or null)
    && builtins.match "([0-9a-f]{40}|[0-9a-f]{64})" source.rev != null
    && (!(source ? narHash) || (builtins.isString source.narHash && source.narHash != ""))
    && validOutput (provider.archiveOutput or "npm-package");
in
builtins.mapAttrs (
  modulePath:
  {
    name,
    output ? "npm-package",
    archive ? null,
  }:
  let
    locked = packageLock.packages.${modulePath};
    source = builtins.match "git[+]ssh://([^?#]+)#([0-9a-f]{40})" locked.resolved;
    selectedArchive =
      if archive != null then
        archive
      else if source == null then
        throw "${modulePath} must have an exact git+ssh commit resolution in package-lock.json"
      else
        (builtins.getFlake (
          "git+ssh://${builtins.elemAt source 0}" + "?rev=${builtins.elemAt source 1}&allRefs=1"
        )).packages.${system}.${output};
    descriptor = selectedArchive.npmPackage or (throw "${modulePath}: missing npmPackage descriptor");
    distribution =
      selectedArchive.npmDistribution
        or (throw "${modulePath}: missing npmDistribution; runtime discovery is unsupported by this artifact");
  in
  assert
    (builtins.isInt descriptor.schemaVersion && descriptor.schemaVersion == 1)
    || throw "${modulePath}: unsupported npmPackage schemaVersion";
  assert descriptor.format == "npm-tgz";
  assert descriptor.name == name;
  assert descriptor.version == locked.version;
  assert source == null || descriptor.source.rev == builtins.elemAt source 1;
  assert descriptor.dependencies == (locked.dependencies or { });
  assert descriptor.peerDependencies == (locked.peerDependencies or { });
  assert descriptor.peerDependenciesMeta == (locked.peerDependenciesMeta or { });
  assert descriptor.optionalDependencies == (locked.optionalDependencies or { });
  assert descriptor.engines == (locked.engines or { });
  assert descriptor.bin == (locked.bin or { });
  assert
    builtins.isAttrs distribution || throw "${modulePath}: npmDistribution must be an attribute set";
  assert
    (builtins.isInt (distribution.schemaVersion or null) && distribution.schemaVersion == 1)
    || throw "${modulePath}: unsupported npmDistribution schemaVersion";
  assert
    (validOutput (distribution.archiveOutput or null) && distribution.archiveOutput == output)
    || throw "${modulePath}: npmDistribution archiveOutput must name the selected archive package";
  assert
    builtins.isList (distribution.runtimeProviders or null)
    || throw "${modulePath}: npmDistribution runtimeProviders must be a list";
  assert
    builtins.all validProvider distribution.runtimeProviders
    || throw "${modulePath}: malformed runtime provider; require exact versions/revisions and plain git+ssh or git+https URLs without passwords, queries or fragments";
  {
    # Advertised candidates do not acquire sources or change the npm lock graph.
    inherit name locked distribution;
    output = output;
    source =
      if source == null then
        null
      else
        {
          url = "git+ssh://${builtins.elemAt source 0}";
          rev = builtins.elemAt source 1;
        };
    archive = selectedArchive;
  }
) selections
