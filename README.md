# nixpkgs-matrixai

Matrix AI public Nix package and module distribution flake.

This repository exists to provide one coherent producer interface for Matrix AI Nix consumers.

Without this layer, teams consume many independent flakes directly and drift over time on pins, output shapes, and composition behavior. Here, curation is intentionally centralized so downstream repositories can depend on one stable contract instead of many floating contracts.

In short:

- this repo owns what is distributed and how it is composed,
- downstream repos own environment-specific rollout and runtime operations.

Technical contract summary:

- public API is the `outputs` shape in `flake.nix`,
- canonical constructor path is `lib.mkPkgs`,
- constrained `builtins.getFlake` is allowed only under policy (path allowlist, commit pinning, and check enforcement).

Allowlist metadata is maintained in `checks/policy-pin-allowlist.nix`, while enforcement logic lives in `checks/policy-pin.nix`.

## Usage

### What this flake exports

The public contract is the `outputs` shape in `flake.nix`.

| Output | Purpose |
| --- | --- |
| `lib` | Public helper scope from `lib/default.nix`; includes upstream `nixpkgs.lib` under `lib.lib`, source filtering helpers under `lib.gitignore`, and constructor helpers such as `lib.mkPkgs`. |
| `overlays.default` | Canonical project overlay from `overlays/default.nix`. |
| `legacyPackages.${system}` | Compatibility package set produced via `lib.mkPkgs`. |
| `packages.${system}` | Curated flat top-level installables projection from `pkgs/default.nix` (`exportTopLevel`). |
| `templates.default` | Minimal OSS starter template (alias of `templates.oss`). |
| `templates.oss` | Minimal OSS starter template using flake-parts and `nixpkgs-matrixai.lib.mkPkgs`. |
| `nixosModules.default` | Public aggregate NixOS module entrypoint. |
| `nixosModules.procpath` | Public NixOS Procpath module entrypoint. |
| `homeModules.default` | Public Home Manager module entrypoint. |
| `checks.${system}` | Local contract/policy/smoke gates consumed by `nix flake check`. |
| `devShells.${system}.default` | Developer shell for local repository maintenance workflows. |

Current policy is explicit single-system materialization (`x86_64-linux`).

### Start from the OSS template

Initialize a new project using the exported starter:

```sh
nix flake init -t github:MatrixAI/nixpkgs-matrixai#oss
```

Equivalent alias:

```sh
nix flake init -t github:MatrixAI/nixpkgs-matrixai#default
```

The template emits one minimal `flake.nix` that:

1. uses flake-parts,
2. imports `nixpkgs-matrixai` from GitHub,
3. constructs `pkgs` through `nixpkgs-matrixai.lib.mkPkgs`,
4. defines a small `devShell` consuming `nixpkgs-matrixai` packages.

### Constructor path (`lib.mkPkgs`)

`lib.mkPkgs` is the canonical constructor for downstream composition.

Overlay ordering in `lib/mkPkgs.nix` is:

1. upstream nixpkgs constructor,
2. project default overlay,
3. caller-provided overlays.

Implementation shape:

```nix
mkPkgsUpstream {
  inherit system config;
  overlays = [ overlay ] ++ overlays;
}
```

### Gitignore-aware source filtering (`lib.gitignore`)

This flake pins and re-exports `hercules-ci/gitignore.nix` under `lib.gitignore`.

`gitignore.nix` is a Nix library helper, not an installable package. Its main helpers are:

- `lib.gitignore.gitignoreSource`: filter a local source tree using Git ignore rules.
- `lib.gitignore.gitignoreFilter`: produce a composable source filter function.

Downstream flakes that already consume this repository should prefer the centralized helper unless they need independent pin control:

```nix
{ inputs, ... }:
let
  inherit (inputs.nixpkgs-matrixai.lib.gitignore) gitignoreSource;
in
{
  packages.x86_64-linux.example = pkgs.stdenv.mkDerivation {
    pname = "example";
    version = "0.1.0";
    src = gitignoreSource ./.;
  };
}
```

Projects should add `hercules-ci/gitignore.nix` as their own input only when they deliberately need a separate version or different `nixpkgs` follow policy.

If a wrapper producer flake such as `nixpkgs-matrixai-private` is the only Matrix AI input pinned by a downstream repository, that wrapper must explicitly re-export this public library surface, for example by exposing `lib.gitignore` from its own `lib` output. Flake outputs do not automatically pass through transitive input outputs.

### Package registry and overlay model

`pkgs/default.nix` is the package registry and projection hub:

- `registry.topLevel` maps top-level package names to package files,
- `registry.scopes` maps scoped package sets (currently `python3Packages`),
- `exportTopLevel` projects flat installables to `packages.${system}`,
- `overlay` wires top-level + scoped entries into `overlays.default` / `legacyPackages.${system}`.

### Direct output usage

```sh
nix build 'github:MatrixAI/nixpkgs-matrixai#packages.x86_64-linux.matrixai-public-hello'
nix build 'github:MatrixAI/nixpkgs-matrixai#legacyPackages.x86_64-linux.matrixai-public-hello'
```

## Development

### Local developer shell

Enter the repository maintenance shell:

```sh
nix develop
```

The shell is intentionally curated for this repository's maintenance workflows and includes tools like `nix`, `git`, `jq`, GNU text/core utilities, `curl`, and `wget`.

### Canonical local test workflow

Use these as the standard local gates:

```sh
nix flake show path:. --no-write-lock-file
nix flake check path:. --no-write-lock-file
```

Current checks:

- `checks.${system}.contract-outputs`
- `checks.${system}.contract-packages`
- `checks.${system}.contract-modules`
- `checks.${system}.policy-pin`
- `checks.${system}.smoke-hello`

### Explore the pinned upstream nixpkgs in a REPL

Use this when you need to inspect the upstream `nixpkgs` revision that this
repository currently pins.

Start a REPL from the repository root:

```sh
nix repl
```

Load this flake using path-source semantics:

```nix
:lf path:.
```

Then inspect the upstream input and its resolved source:

```nix
inputs.nixpkgs
inputs.nixpkgs.rev
inputs.nixpkgs.outPath
inputs.nixpkgs.lib.version
```

Instantiate the pinned upstream package set directly when you need to inspect
packages as they exist before this repository's overlay and constructor logic:

```nix
pkgs = import inputs.nixpkgs { system = "x86_64-linux"; config.allowUnfree = true; }
pkgs.lib.version
pkgs.hello.version
pkgs.stdenv.hostPlatform.system
```

Compare that with this repository's exported package surfaces when you need to
see what the public flake contract exposes after `lib.mkPkgs` composition:

```nix
self.legacyPackages.x86_64-linux.lib.version
self.packages.x86_64-linux.matrixai-public-hello
```

Use `path:.` for high-churn local exploration because it reads the working tree
path directly. If you want parity with Git-backed flake acquisition, load the
flake with `:lf .` instead and stage newly added files first:

```nix
:lf .
```

The `flake.lock` file remains the baseline pinned state for non-overridden
inputs. Temporary `--override-input` usage supersedes the selected input edge in
memory for that invocation only; it is not a persistent lock update.

For one-off shell checks outside the REPL, quote flake refs that contain `#`:

```sh
nix eval 'path:.#legacyPackages.x86_64-linux.lib.version'
```

### Pin governance workflows

#### Upstream nixpkgs pin workflow

Use:

```sh
./scripts/nixpkgs-pin-policy.sh info
./scripts/nixpkgs-pin-policy.sh info --tracking-ref refs/heads/nixos-unstable
./scripts/nixpkgs-pin-policy.sh update <commit-sha>
```

`update` rewrites the managed nixpkgs block in `flake.nix`, refreshes `flake.lock`, and verifies rev consistency.

When a candidate pin breaks an upstream package you care about, use the pin
search helper before deciding policy. A candidate succeeds when all requested
conditions pass. Build conditions build one or more derivations, assert
conditions must evaluate to `true`, and eval conditions must evaluate
successfully.

Put reusable conditions in a condition file that receives the candidate upstream
nixpkgs package set as `pkgs` and returns a list of condition attrsets:

```nix
{ pkgs }:

[
  { kind = "build"; expr = pkgs.binwalk; }
  { kind = "build"; expr = pkgs.radicle; }
  { kind = "assert"; expr = pkgs.lib.versionAtLeast pkgs.radicle.version "1.9.1"; }
  { kind = "eval"; expr = pkgs.radicle.version; }
]
```

Then search from the current managed nixpkgs pin for the closest candidate where
every condition passes:

```sh
./scripts/nixpkgs-pin-search.sh ./checks/pin-conditions.nix
```

For quick one-off probes, pass repeated command-line conditions with `pkgs` in
scope. These lower to the same internal condition schema as condition files:

```sh
./scripts/nixpkgs-pin-search.sh --build 'pkgs.binwalk' --build 'pkgs.radicle'
```

For version or metadata searches, use `--assert` or `--eval`:

```sh
./scripts/nixpkgs-pin-search.sh --assert 'pkgs.lib.versionAtLeast pkgs.radicle.version "1.9.1"'
```

Combine condition kinds when both metadata and builds matter:

```sh
./scripts/nixpkgs-pin-search.sh --build 'pkgs.radicle' --assert 'pkgs.lib.versionAtLeast pkgs.radicle.version "1.9.1"'
```

The condition kinds are:

- `build`: expression must evaluate to a derivation, list of derivations, or
  attrset of derivations; all resulting derivations are built.
- `assert`: expression must evaluate to boolean `true`.
- `eval`: expression must evaluate successfully without being selected as a
  package build target.

Conceptually, the helper is like `git bisect` for source-code regressions, but
the search space is upstream nixpkgs commits and the pass/fail test is your Nix
condition set. This lets maintainers answer questions such as "which nearby
nixpkgs commit still builds `pkgs.binwalk`?" or "which nearby commit first has a
package version satisfying this predicate?" before deciding whether to accept a
pin, hold a pin, or add a local override.

Use `--direction backward`, `--direction forward`, or `--direction both` when
you want to constrain the search direction from the origin commit. The default
is `both`, which samples around the origin and reports the first sampled
candidate where all conditions pass. The search space is defined by three
separate choices: the upstream remote where nixpkgs commits are fetched from,
the traversal branch whose commit steps are counted, and the origin commit where
the search starts. By default these are NixOS/nixpkgs,
`refs/heads/nixos-unstable`, and the current managed pin. All direction modes
use the same exponential fuzzy sampling strategy:

- `--direction both`: origin, +1, -1, +2, -2, +4, -4, and so on.
- `--direction backward`: origin, -1, -2, -4, -8, and so on.
- `--direction forward`: origin, +1, +2, +4, +8, and so on.

This keeps expensive package probes practical. A sampled pass is evidence for a
usable candidate, not proof of the nearest possible passing commit. By default,
the helper uses `--refine closest`: it bisects the sampled fail/pass bracket until
the remaining bracket is small, then exact-scans the final tail. The default
exact tail threshold is 16 commits. Use `--refine none` to keep the sampled
result only, `--refine bisect` to stop after monotonic boundary refinement, or
`--refine exact` to linearly scan the whole sampled bracket.

Offsets are tracking-branch steps from the origin on the selected traversal
branch. For example, offset `-119` means 119 previous tracking-branch steps
before the origin pin, and offset `+12` means 12 next tracking-branch steps after
the origin pin. The same commit object can appear on multiple branches, so an
offset is only meaningful with the selected traversal branch. The run report
prints bracket sizes while refining so you can see the search space shrink.

If the origin is already the traversal branch head, the forward side is empty,
so a both-direction fuzzy scan can only probe the origin and older commits.

The helper is non-mutating. It prints the search strategy, a compact sample trace,
stores logs under `tmp/nixpkgs-pin-search`, and prints the
`./scripts/nixpkgs-pin-policy.sh update <commit-sha>` command to run if you
accept the selected candidate. It uses the local nixpkgs Git cache under
`tmp/git-cache/nixpkgs.repo` so repeated candidate probes can walk and evaluate
cached Git history instead of refetching the same commits through the GitHub
tarball path. Defaults are intentionally simple: current managed pin as origin,
NixOS/nixpkgs as upstream remote, `refs/heads/nixos-unstable` as traversal
branch, both-direction search, closest
refinement, a 16-commit exact tail threshold, and a 256-commit span. Use
`--origin <commit-sha>`, `--direction <backward|forward|both>`,
`--refine <none|bisect|exact|closest>`, `--exact-threshold <count>`, or
`--span <count>` only when the default search window is not enough.

#### External flake pin baseline

External `builtins.getFlake` usage is allowlisted and enforced by `checks.${system}.policy-pin`.

Allowlist metadata lives in:

- `checks/policy-pin-allowlist.nix`

### Helper scripts for maintainers

These scripts improve maintainer decision-making inside this repository. They are ergonomics helpers, not the contract authority (the contract authority remains flake outputs and checks).

1. External pin lifecycle visibility:

```sh
./scripts/external-pin-lifecycle.sh info
./scripts/external-pin-lifecycle.sh info --tracking-ref refs/heads/main
```

Reports include:

- allowlisted entry metadata,
- pinned commit date,
- pin age in days,
- review cadence and due state,
- tracking branch head SHA visibility.

2. Package version intelligence for policy decisions:

```sh
./scripts/package-version-intel.sh current vscodium
./scripts/package-version-intel.sh compare vscodium --candidate-ref refs/heads/nixos-unstable
./scripts/package-version-intel.sh compare matrixai-public-hello --system x86_64-linux --candidate-ref <commit-sha>
```

Reports include current pinned metadata and candidate metadata (`version`, `pname`, `name`) plus a simple changed/unchanged status.

### Adding packages

1. Add or update package definitions under `pkgs/top-level` or `pkgs/development/python-modules`.
2. Register package paths in `pkgs/default.nix` under:
   - `registry.topLevel`, or
   - `registry.scopes.<scopeName>`.
3. Validate both surfaces:
   - `packages.${system}` via `exportTopLevel`,
   - `legacyPackages.${system}` via overlay composition.

Useful checks:

```sh
nix flake show path:. --no-write-lock-file
nix build '.#packages.x86_64-linux.matrixai-public-hello'
nix build '.#legacyPackages.x86_64-linux.matrixai-public-hello'
```

### Modules

Stable exported module entrypoints are:

- `nixosModules.default`
- `nixosModules.procpath`
- `homeModules.default`

The public NixOS surfaces are composed from one internal registry seam:

- `modules/nixos/module-list.nix` is the internal list of NixOS leaf-module
  paths.
- `modules/nixos/default.nix` aggregates that list into `nixosModules.default`.
- `modules/default.nix` projects named module exports such as
  `nixosModules.procpath` from the same list.

Consumers should use the exported flake module surfaces above rather than the
internal registry files directly.

Current public behavior:

- `nixosModules.default` aggregates the registered NixOS leaf modules.
- `nixosModules.procpath` provides `programs.procpath`.
- `homeModules.default` remains a placeholder until a Home Manager-specific
  module exists.

Example NixOS usage:

```nix
{
  imports = [
    inputs.nixpkgs-matrixai.nixosModules.procpath
  ];

  programs.procpath = {
    enable = true;
  };
}
```

### Cross-repo consumption checks

When iterating with `nixpkgs-matrixai-private`, run from the private checkout:

```sh
nix flake check --override-input nixpkgs-matrixai ../nixpkgs-matrixai
```

For lock-based validation in private:

```sh
nix flake update nixpkgs-matrixai
nix flake check
```
