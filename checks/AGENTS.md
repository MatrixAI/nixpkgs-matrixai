# checks/AGENTS.md

## Purpose

This file is the runbook for agents changing checks under [`checks/`](checks/default.nix).

The checks layer is the machine-enforced local gate for this repository contract.

## Scope

- Govern only the local check topology and check intent.
- Keep checks focused on contract, package surface, module evaluation, policy, and smoke behavior.
- Do not move repository policy into ad-hoc shell workflows when a check can enforce it.

## Check topology model

The check entrypoint is [`checks/default.nix`](checks/default.nix), which aggregates one check per file:

- [`contract-outputs`](checks/contract-outputs.nix)
- [`contract-packages`](checks/contract-packages.nix)
- [`contract-modules`](checks/contract-modules.nix)
- [`policy-pin`](checks/policy-pin.nix)
- [`smoke-hello`](checks/smoke-hello.nix)

Keep each lane semantic and independently explainable.

## Design invariants

1. A check name should communicate *what invariant* it protects.
2. Each file should implement one principal gate.
3. Use Nix assertions for deterministic structural invariants when feasible.
4. Use derivation-time shell checks only when scanning source text or executing runtime-like probes is required.
5. Keep failure output actionable: indicate invariant type and likely drift area.

## Change protocol

When adding or changing checks:

1. Update [`checks/default.nix`](checks/default.nix) wiring.
2. Update consumer-facing check docs in [`README.md`](README.md).
3. Keep architecture/runbook alignment in [`AGENTS.md`](AGENTS.md).
4. Validate with [`nix flake check`](README.md).

## Anti-patterns

- Introducing ambiguous lane names without clear invariants.
- Bundling unrelated checks into one broad lane.
- Letting docs drift from actual check names and behavior.
- Replacing stable contract checks with informal scripts.
