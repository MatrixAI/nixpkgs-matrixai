#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FLAKE_FILE="$ROOT_DIR/flake.nix"

CACHE_ROOT_DIR="$ROOT_DIR/tmp/nixpkgs-pin-search"
GIT_CACHE_ROOT_DIR="$ROOT_DIR/tmp/git-cache"

DEFAULT_TRACKING_REF="refs/heads/nixos-unstable"
DEFAULT_SYSTEM="x86_64-linux"
DEFAULT_SPAN="256"
DEFAULT_DIRECTION="both"
DEFAULT_REFINE="closest"
DEFAULT_EXACT_THRESHOLD="16"

NIXPKGS_OWNER="NixOS"
NIXPKGS_REPO="nixpkgs"
NIXPKGS_REMOTE_URL="https://github.com/${NIXPKGS_OWNER}/${NIXPKGS_REPO}"
NIXPKGS_CACHE_REF="refs/heads/pin-search-cache"

MANAGED_BLOCK_BEGIN="    # BEGIN: nixpkgs-pin (managed by scripts/nixpkgs-pin-policy.sh)"
MANAGED_BLOCK_END="    # END: nixpkgs-pin"

usage() {
  cat <<'EOF'
Usage:
  scripts/nixpkgs-pin-search.sh <conditions-file.nix> [--build <nix-expr>] [--assert <bool-expr>] [--eval <nix-expr>] [--origin <commit-sha>] [--direction <backward|forward|both>] [--span <count>] [--refine <none|bisect|exact|closest>] [--exact-threshold <count>] [--tracking-ref <git-ref>] [--system <system>]
  scripts/nixpkgs-pin-search.sh --build <nix-expr> [--build <nix-expr> ...] [--assert <bool-expr> ...] [--eval <nix-expr> ...] [--origin <commit-sha>] [--direction <backward|forward|both>] [--span <count>] [--refine <none|bisect|exact|closest>] [--exact-threshold <count>] [--tracking-ref <git-ref>] [--system <system>]

Description:
  Search around a nixpkgs commit for a candidate whose conditions all pass. The
  default search direction is both. The search is non-mutating; use the printed
  nixpkgs-pin-policy.sh update command if you accept the candidate.

Concept:
  This is like git bisect for upstream nixpkgs commits, but the pass/fail test is
  a Nix predicate or build condition evaluated against each candidate package set.

  Three inputs define the search space:
    upstream remote   where nixpkgs commits are fetched from
    traversal branch branch/ref whose commit steps are counted
    origin commit    commit where the search starts

  Defaults are NixOS/nixpkgs, refs/heads/nixos-unstable, and the managed pin in
  flake.nix. The same commit can appear on multiple branches, so offsets only
  have meaning relative to the selected traversal branch.

  Offsets are tracking-branch steps from the origin commit:
    0 is the origin commit itself.
    -1 is one previous tracking-branch step before origin.
    -119 is the 119th previous tracking-branch step before origin.
    +12 is the 12th next tracking-branch step after origin.

Search modes:
  --direction both      sampled fuzzy scan: origin, +1, -1, +2, -2, +4, -4, ...
  --direction backward  sampled fuzzy scan: origin, -1, -2, -4, -8, ...
  --direction forward   sampled fuzzy scan: origin, +1, +2, +4, +8, ...

Refinement modes:
  --refine closest bisect the sampled fail/pass bracket, then exact-scan the small tail
  --refine bisect  refine the sampled fail/pass bracket assuming local monotonicity
  --refine exact   linearly scan the sampled fail/pass bracket for the closest pass
  --refine none    keep the first sampled passing candidate

Result meaning:
  A refined passing candidate is the closest passing candidate found after the
  selected refinement strategy. With --refine closest, this means the script first
  narrows cheaply, then exact-scans the final small bracket.

Condition file form:
  The conditions file is imported as a function receiving { pkgs } and must
  return a list of condition attrsets. Each condition has a kind and expr:
    { kind = "build"; expr = pkgs.binwalk; }
    { kind = "assert"; expr = pkgs.radicle.version == "1.9.1"; }
    { kind = "eval"; expr = pkgs.radicle.version; }

Command-line conditions:
  --build evaluates an expression to a derivation, list of derivations, or
  attrset of derivations and builds all resulting derivations.
  --assert evaluates a boolean expression that must be true.
  --eval evaluates an expression successfully without building it.

Examples:
  scripts/nixpkgs-pin-search.sh ./checks/pin-conditions.nix
  scripts/nixpkgs-pin-search.sh --build 'pkgs.binwalk'
  scripts/nixpkgs-pin-search.sh --assert 'pkgs.radicle.version == "1.9.1"'
  scripts/nixpkgs-pin-search.sh --build 'pkgs.radicle' --assert 'pkgs.lib.versionAtLeast pkgs.radicle.version "1.9.1"'
  scripts/nixpkgs-pin-search.sh --build 'pkgs.binwalk' --build 'pkgs.radicle' --direction backward --span 512
  scripts/nixpkgs-pin-search.sh --build 'pkgs.binwalk' --span 512 --exact-threshold 16
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

log_info() {
  echo "[nixpkgs-pin-search] $*" >&2
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "required command not found: $name"
}

parse_args() {
  CONDITIONS_FILE=""
  BUILD_EXPRS=()
  ASSERT_EXPRS=()
  EVAL_EXPRS=()
  ORIGIN=""
  DIRECTION="$DEFAULT_DIRECTION"
  REFINE="$DEFAULT_REFINE"
  EXACT_THRESHOLD="$DEFAULT_EXACT_THRESHOLD"
  SPAN="$DEFAULT_SPAN"
  TRACKING_REF="$DEFAULT_TRACKING_REF"
  SYSTEM="$DEFAULT_SYSTEM"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --build)
        [[ $# -ge 2 ]] || die "--build requires a value"
        BUILD_EXPRS+=("$2")
        shift 2
        ;;
      --assert)
        [[ $# -ge 2 ]] || die "--assert requires a value"
        ASSERT_EXPRS+=("$2")
        shift 2
        ;;
      --eval)
        [[ $# -ge 2 ]] || die "--eval requires a value"
        EVAL_EXPRS+=("$2")
        shift 2
        ;;
      --origin)
        [[ $# -ge 2 ]] || die "--origin requires a value"
        ORIGIN="$2"
        shift 2
        ;;
      --direction)
        [[ $# -ge 2 ]] || die "--direction requires a value"
        DIRECTION="$2"
        shift 2
        ;;
      --span)
        [[ $# -ge 2 ]] || die "--span requires a value"
        SPAN="$2"
        shift 2
        ;;
      --refine)
        [[ $# -ge 2 ]] || die "--refine requires a value"
        REFINE="$2"
        shift 2
        ;;
      --exact-threshold)
        [[ $# -ge 2 ]] || die "--exact-threshold requires a value"
        EXACT_THRESHOLD="$2"
        shift 2
        ;;
      --tracking-ref)
        [[ $# -ge 2 ]] || die "--tracking-ref requires a value"
        TRACKING_REF="$2"
        shift 2
        ;;
      --system)
        [[ $# -ge 2 ]] || die "--system requires a value"
        SYSTEM="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      --*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -n "$CONDITIONS_FILE" ]]; then
          die "only one conditions file may be specified"
        fi
        CONDITIONS_FILE="$1"
        shift
        ;;
    esac
  done

  if [[ -z "$CONDITIONS_FILE" && ${#BUILD_EXPRS[@]} -eq 0 && ${#ASSERT_EXPRS[@]} -eq 0 && ${#EVAL_EXPRS[@]} -eq 0 ]]; then
    usage
    exit 1
  fi

  if [[ -n "$CONDITIONS_FILE" && ! -f "$CONDITIONS_FILE" ]]; then
    die "conditions file not found: $CONDITIONS_FILE"
  fi

  if ! [[ "$SPAN" =~ ^[0-9]+$ ]] || (( SPAN < 1 )); then
    die "--span must be a positive integer"
  fi

  if ! [[ "$EXACT_THRESHOLD" =~ ^[0-9]+$ ]] || (( EXACT_THRESHOLD < 1 )); then
    die "--exact-threshold must be a positive integer"
  fi

  case "$DIRECTION" in
    backward|forward|both) ;;
    *) die "--direction must be one of: backward, forward, both" ;;
  esac

  case "$REFINE" in
    none|bisect|exact|closest) ;;
    *) die "--refine must be one of: none, bisect, exact, closest" ;;
  esac
}

extract_nixpkgs_field_from_flake_block() {
  local field="$1"
  local value

  value="$({
    awk -v begin="$MANAGED_BLOCK_BEGIN" -v end="$MANAGED_BLOCK_END" -v field="$field" '
      BEGIN { in_block = 0; }
      {
        if (index($0, begin) > 0) { in_block = 1; next; }
        if (in_block == 1 && index($0, end) > 0) { in_block = 0; next; }
        if (in_block == 1) {
          line = $0;
          gsub(/^[[:space:]]+/, "", line);
          if (line ~ "^" field "[[:space:]]*=[[:space:]]*\"") {
            sub("^" field "[[:space:]]*=[[:space:]]*\"", "", line);
            sub("\";[[:space:]]*$", "", line);
            print line;
            exit 0;
          }
        }
      }
      END { exit 1; }
    ' "$FLAKE_FILE"
  } 2>/dev/null)"

  [[ -n "$value" ]] || die "failed to read '${field}' from managed nixpkgs block in ${FLAKE_FILE}"
  printf '%s\n' "$value"
}

validate_sha_format() {
  local sha="$1"
  if ! [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
    die "commit sha must be 40 lowercase hex characters: $sha"
  fi
}

cache_prepare_dirs() {
  mkdir -p "$GIT_CACHE_ROOT_DIR" "$CACHE_ROOT_DIR/runs" || die "failed to prepare cache directories"
}

git_cache_repo_path() {
  printf '%s/%s.repo' "$GIT_CACHE_ROOT_DIR" "$NIXPKGS_REPO"
}

init_or_update_git_cache() {
  local cache_repo
  cache_repo="$(git_cache_repo_path)"

  if [[ ! -d "$cache_repo/.git" ]]; then
    log_info "initializing git cache at $cache_repo"
    mkdir -p "$cache_repo" || die "failed to create git cache"
    git -C "$cache_repo" init -q >/dev/null 2>&1 || die "failed to initialize git cache"
    git -C "$cache_repo" remote add origin "$NIXPKGS_REMOTE_URL" >/dev/null 2>&1 || die "failed to add nixpkgs remote"
  fi

  git -C "$cache_repo" config remote.origin.promisor true \
    || die "failed to configure nixpkgs cache as a partial clone"
  git -C "$cache_repo" config remote.origin.partialclonefilter tree:0 \
    || die "failed to configure nixpkgs cache tree filter"

  printf '%s\n' "$cache_repo"
}

resolve_origin() {
  if [[ -n "$ORIGIN" ]]; then
    validate_sha_format "$ORIGIN"
    printf '%s\n' "$ORIGIN"
  else
    extract_nixpkgs_field_from_flake_block rev
  fi
}

fetch_search_refs() {
  local cache_repo="$1"
  local origin="$2"

  log_info "fetching nixpkgs refs for search"
  git -C "$cache_repo" fetch --filter=tree:0 --no-tags origin \
    "$origin" \
    "+${TRACKING_REF}:${NIXPKGS_CACHE_REF}" >/dev/null 2>&1 \
    || die "failed to fetch origin and tracking ref from nixpkgs"
}

load_tracking_chain() {
  local cache_repo="$1"
  local origin="$2"
  local origin_index=""
  local i

  mapfile -t TRACKING_CHAIN < <(
    git -C "$cache_repo" rev-list --first-parent "$NIXPKGS_CACHE_REF"
  )

  [[ ${#TRACKING_CHAIN[@]} -gt 0 ]] || die "failed to build tracking chain from: $TRACKING_REF"

  for i in "${!TRACKING_CHAIN[@]}"; do
    if [[ "${TRACKING_CHAIN[$i]}" == "$origin" ]]; then
      origin_index="$i"
      break
    fi
  done

  [[ -n "$origin_index" ]] || die "origin is not on selected traversal branch: $origin"
  ORIGIN_INDEX="$origin_index"
  build_candidate_window "$origin_index"
}

append_candidate() {
  local sha="$1"
  local offset="$2"
  local direction="$3"

  CANDIDATES+=("$sha")
  CANDIDATE_OFFSETS+=("$offset")
  CANDIDATE_DIRECTIONS+=("$direction")
}

append_candidate_if_missing() {
  local sha="$1"
  local offset="$2"
  local direction="$3"
  local existing_offset

  CANDIDATE_WAS_APPENDED=0
  for existing_offset in "${CANDIDATE_OFFSETS[@]}"; do
    if [[ "$existing_offset" == "$offset" ]]; then
      return 0
    fi
  done

  append_candidate "$sha" "$offset" "$direction"
  CANDIDATE_WAS_APPENDED=1
}

candidate_index_for_offset() {
  local offset="$1"
  local i index sha direction

  for i in "${!CANDIDATE_OFFSETS[@]}"; do
    if [[ "${CANDIDATE_OFFSETS[$i]}" == "$offset" ]]; then
      CANDIDATE_INDEX_RESULT="$i"
      return 0
    fi
  done

  if (( offset == 0 )); then
    index="$ORIGIN_INDEX"
    direction="origin"
  elif (( offset > 0 )); then
    index=$((ORIGIN_INDEX - offset))
    direction="forward"
  else
    index=$((ORIGIN_INDEX - offset))
    direction="backward"
  fi

  if (( index < 0 || index >= ${#TRACKING_CHAIN[@]} )); then
    die "refinement offset is outside tracking chain: $offset"
  fi

  sha="${TRACKING_CHAIN[$index]}"
  append_candidate "$sha" "$offset" "$direction"
  CANDIDATE_INDEX_RESULT="$((${#CANDIDATES[@]} - 1))"
}

build_candidate_window() {
  local origin_index="$1"
  local distance index forward_limit backward_limit

  CANDIDATES=()
  CANDIDATE_OFFSETS=()
  CANDIDATE_DIRECTIONS=()
  FORWARD_CANDIDATE_COUNT=0
  BACKWARD_CANDIDATE_COUNT=0
  append_candidate "${TRACKING_CHAIN[$origin_index]}" 0 origin

  case "$DIRECTION" in
    backward)
      for ((distance = 1; distance <= SPAN; distance *= 2)); do
        index=$((origin_index + distance))
        (( index < ${#TRACKING_CHAIN[@]} )) || break
        append_candidate "${TRACKING_CHAIN[$index]}" "$((-distance))" backward
        BACKWARD_CANDIDATE_COUNT=$((BACKWARD_CANDIDATE_COUNT + 1))
      done
      ;;
    forward)
      for ((distance = 1; distance <= SPAN; distance *= 2)); do
        index=$((origin_index - distance))
        (( index >= 0 )) || break
        append_candidate "${TRACKING_CHAIN[$index]}" "$distance" forward
        FORWARD_CANDIDATE_COUNT=$((FORWARD_CANDIDATE_COUNT + 1))
      done
      ;;
    both)
      for ((distance = 1; distance <= SPAN; distance *= 2)); do
        index=$((origin_index - distance))
        if (( index >= 0 )); then
          append_candidate "${TRACKING_CHAIN[$index]}" "$distance" forward
          FORWARD_CANDIDATE_COUNT=$((FORWARD_CANDIDATE_COUNT + 1))
        fi
        index=$((origin_index + distance))
        if (( index < ${#TRACKING_CHAIN[@]} )); then
          append_candidate "${TRACKING_CHAIN[$index]}" "$((-distance))" backward
          BACKWARD_CANDIDATE_COUNT=$((BACKWARD_CANDIDATE_COUNT + 1))
        fi
      done
      ;;
  esac

  if [[ "$DIRECTION" == "forward" || "$DIRECTION" == "both" ]]; then
    forward_limit="$origin_index"
    if (( forward_limit > SPAN )); then
      forward_limit="$SPAN"
    fi
    if (( forward_limit > 0 )); then
      index=$((origin_index - forward_limit))
      append_candidate_if_missing "${TRACKING_CHAIN[$index]}" "$forward_limit" forward
      FORWARD_CANDIDATE_COUNT=$((FORWARD_CANDIDATE_COUNT + CANDIDATE_WAS_APPENDED))
    fi
  fi

  if [[ "$DIRECTION" == "backward" || "$DIRECTION" == "both" ]]; then
    backward_limit=$((${#TRACKING_CHAIN[@]} - origin_index - 1))
    if (( backward_limit > SPAN )); then
      backward_limit="$SPAN"
    fi
    if (( backward_limit > 0 )); then
      index=$((origin_index + backward_limit))
      append_candidate_if_missing "${TRACKING_CHAIN[$index]}" "$((-backward_limit))" backward
      BACKWARD_CANDIDATE_COUNT=$((BACKWARD_CANDIDATE_COUNT + CANDIDATE_WAS_APPENDED))
    fi
  fi

  [[ ${#CANDIDATES[@]} -gt 0 ]] || die "failed to build candidate window from origin commit"
}

short_sha() {
  printf '%s' "${1:0:7}"
}

target_label() {
  local parts=()
  local expr

  if [[ -n "$CONDITIONS_FILE" ]]; then
    parts+=("$CONDITIONS_FILE")
  fi
  for expr in "${BUILD_EXPRS[@]}"; do
    parts+=("--build ${expr}")
  done
  for expr in "${ASSERT_EXPRS[@]}"; do
    parts+=("--assert ${expr}")
  done
  for expr in "${EVAL_EXPRS[@]}"; do
    parts+=("--eval ${expr}")
  done

  if [[ ${#parts[@]} -eq 0 ]]; then
    printf '%s' "no conditions"
    return 0
  fi

  local IFS="; "
  printf '%s' "${parts[*]}"
}

write_conditions_nix() {
  local conditions_abs=""
  local expr

  if [[ -n "$CONDITIONS_FILE" ]]; then
    conditions_abs="$(cd "$(dirname "$CONDITIONS_FILE")" && pwd)/$(basename "$CONDITIONS_FILE")"
    cat <<EOF
  fileConditions = import ${conditions_abs} { inherit pkgs; };
EOF
  else
    cat <<'EOF'
  fileConditions = [ ];
EOF
  fi

  cat <<'EOF'
  cliConditions = [
EOF

  for expr in "${BUILD_EXPRS[@]}"; do
    cat <<EOF
    { kind = "build"; expr = (${expr}); }
EOF
  done
  for expr in "${ASSERT_EXPRS[@]}"; do
    cat <<EOF
    { kind = "assert"; expr = (${expr}); }
EOF
  done
  for expr in "${EVAL_EXPRS[@]}"; do
    cat <<EOF
    { kind = "eval"; expr = (${expr}); }
EOF
  done

  cat <<'EOF'
  ];
  conditionsRaw = fileConditions ++ cliConditions;
  conditions =
    if builtins.isList conditionsRaw then conditionsRaw
    else builtins.throw "conditions file must return a list";
EOF
}

materialize_candidate_worktree() {
  local sha="$1"
  local source_dir="$2"
  local materialize_log="$3"

  if [[ -e "$source_dir" ]]; then
    git -C "$SEARCH_CACHE_REPO" worktree remove --force "$source_dir" >/dev/null 2>&1 \
      || rm -rf "$source_dir"
  fi

  git -C "$SEARCH_CACHE_REPO" worktree add --detach --force "$source_dir" "$sha" >"$materialize_log" 2>&1 \
    || die "failed to materialize candidate worktree: $sha"
}

write_probe_expr() {
  local sha="$1"
  local expr_file="$2"
  local source_dir="$3"

  {
    cat <<EOF
let
  pkgs = import ${source_dir} {
    system = "${SYSTEM}";
    config.allowUnfree = true;
  };
  isDerivation = value: builtins.isAttrs value && value ? type && value.type == "derivation";
  normalize = value:
    if builtins.isList value then value
    else if isDerivation value then [ value ]
    else if builtins.isAttrs value then builtins.attrValues value
    else [ value ];
  evalMarker = name: value: pkgs.runCommand name { } ''
    mkdir -p "\$out"
    cat > "\$out/value.txt" <<'VALUE'
    \${builtins.toJSON value}
    VALUE
  '';
  conditionName = index: condition:
    if builtins.isAttrs condition && condition ? name then condition.name
    else "condition-\${builtins.toString index}";
  conditionToDrvs = index: condition:
    let
      name = conditionName index condition;
      kind =
        if builtins.isAttrs condition && condition ? kind then condition.kind
        else builtins.throw "condition must be an attrset with kind";
      expr =
        if builtins.isAttrs condition && condition ? expr then condition.expr
        else builtins.throw "condition must be an attrset with expr";
    in
      if kind == "build" then normalize expr
      else if kind == "assert" then
        if builtins.isBool expr then
          if expr then [ (evalMarker "pin-search-assert-\${name}" true) ]
          else builtins.throw "assert condition returned false: \${name}"
        else builtins.throw "assert condition must evaluate to a boolean: \${name}"
      else if kind == "eval" then [ (evalMarker "pin-search-eval-\${name}" expr) ]
      else builtins.throw "unknown condition kind: \${kind}";
EOF
    write_conditions_nix
    cat <<'EOF'
in
  builtins.concatLists (builtins.genList (index: conditionToDrvs index (builtins.elemAt conditions index)) (builtins.length conditions))
EOF
  } > "$expr_file"
}

probe_candidate() {
  local index="$1"
  local sha="${CANDIDATES[$index]}"
  local candidate_dir expr_file log_file outputs_file result_file source_dir materialize_log state

  if [[ -n "${RESULT_STATES[$index]:-}" ]]; then
    printf '%s\n' "${RESULT_STATES[$index]}"
    return 0
  fi

  candidate_dir="$RUN_DIR/candidates/$sha"
  expr_file="$candidate_dir/target.nix"
  log_file="$candidate_dir/build.log"
  outputs_file="$candidate_dir/outputs.txt"
  result_file="$candidate_dir/result.json"
  source_dir="$candidate_dir/source"
  materialize_log="$candidate_dir/materialize.log"
  mkdir -p "$candidate_dir" || die "failed to create candidate directory: $candidate_dir"

  materialize_candidate_worktree "$sha" "$source_dir" "$materialize_log"
  write_probe_expr "$sha" "$expr_file" "$source_dir"

  if nix build --no-link --print-out-paths --keep-going --impure --file "$expr_file" >"$outputs_file" 2>"$log_file"; then
    state="PASS"
  else
    state="FAIL"
  fi

  RESULT_STATES[$index]="$state"

  jq -n \
    --arg sha "$sha" \
    --arg short "$(short_sha "$sha")" \
    --arg state "$state" \
    --arg target "$(target_label)" \
    --arg log "$log_file" \
    --arg outputs "$outputs_file" \
    --arg direction "${CANDIDATE_DIRECTIONS[$index]}" \
    --argjson offset "${CANDIDATE_OFFSETS[$index]}" \
    --slurpfile outputPaths <(jq -R -s 'split("\n") | map(select(length > 0))' "$outputs_file") \
    '{sha: $sha, short: $short, offset: $offset, direction: $direction, state: $state, target: $target, log: $log, outputs: $outputs, outputPaths: $outputPaths[0]}' \
    > "$result_file"

  printf '%s\n' "$state"
}

print_probe_line() {
  local phase="$1"
  local index="$2"
  local state="$3"
  local sha="${CANDIDATES[$index]}"
  local outputs_file="$RUN_DIR/candidates/$sha/outputs.txt"
  local first_output=""

  if [[ "$state" == "PASS" && -s "$outputs_file" ]]; then
    first_output="$(head -n 1 "$outputs_file")"
  fi

  if [[ -n "$first_output" ]]; then
    printf '  %-7s %-9s %-7s %-8s %-6s %s\n' "${CANDIDATE_OFFSETS[$index]}" "${CANDIDATE_DIRECTIONS[$index]}" "$(short_sha "$sha")" "$state" "$phase" "$first_output"
  else
    printf '  %-7s %-9s %-7s %-8s %s\n' "${CANDIDATE_OFFSETS[$index]}" "${CANDIDATE_DIRECTIONS[$index]}" "$(short_sha "$sha")" "$state" "$phase"
  fi
}

print_output_paths() {
  local sha="$1"
  local outputs_file="$RUN_DIR/candidates/$sha/outputs.txt"

  if [[ -s "$outputs_file" ]]; then
    echo "  output paths:"
    sed 's/^/    /' "$outputs_file"
  fi
}

offset_explanation() {
  local offset="$1"

  if (( offset < 0 )); then
    printf '%sth previous tracking-branch step before origin; origin is offset 0' "$((-offset))"
  elif (( offset > 0 )); then
    printf '%sth next tracking-branch step after origin; origin is offset 0' "$offset"
  else
    printf '%s' "origin commit itself; origin is offset 0"
  fi
}

offset_abs() {
  local value="$1"
  if (( value < 0 )); then
    printf '%s\n' "$((-value))"
  else
    printf '%s\n' "$value"
  fi
}

refinement_step_toward_origin() {
  local offset="$1"
  if (( offset < 0 )); then
    printf '%s\n' 1
  else
    printf '%s\n' -1
  fi
}

same_side_offsets() {
  local a="$1"
  local b="$2"
  (( a < 0 && b < 0 )) || (( a > 0 && b > 0 ))
}

bracket_size() {
  local fail_offset="$1"
  local pass_offset="$2"
  local fail_abs pass_abs

  fail_abs="$(offset_abs "$fail_offset")"
  pass_abs="$(offset_abs "$pass_offset")"
  if (( pass_abs >= fail_abs )); then
    printf '%s\n' "$((pass_abs - fail_abs))"
  else
    printf '%s\n' "$((fail_abs - pass_abs))"
  fi
}

print_bracket_line() {
  local label="$1"
  local fail_index="$2"
  local pass_index="$3"
  local size

  size="$(bracket_size "${CANDIDATE_OFFSETS[$fail_index]}" "${CANDIDATE_OFFSETS[$pass_index]}")"
  printf '  bracket %-7s fail=%s pass=%s size=%s\n' \
    "$label" \
    "${CANDIDATE_OFFSETS[$fail_index]}" \
    "${CANDIDATE_OFFSETS[$pass_index]}" \
    "$size"
}

refine_exact() {
  local fail_index="$1"
  local pass_index="$2"
  local fail_offset="${CANDIDATE_OFFSETS[$fail_index]}"
  local pass_offset="${CANDIDATE_OFFSETS[$pass_index]}"
  local step offset index state selected_index

  echo
  echo "refine exact"
  print_bracket_line exact "$fail_index" "$pass_index"
  step="$(refinement_step_toward_origin "$pass_offset")"
  offset=$((fail_offset - step))
  selected_index="$pass_index"

  while [[ "$offset" != "$pass_offset" ]]; do
    candidate_index_for_offset "$offset"
    index="$CANDIDATE_INDEX_RESULT"
    state="$(probe_candidate "$index")"
    print_probe_line "refine" "$index" "$state"
    record_timeline "refine exact offset=${CANDIDATE_OFFSETS[$index]} direction=${CANDIDATE_DIRECTIONS[$index]} sha=${CANDIDATES[$index]} state=$state"

    if [[ "$state" == "PASS" ]]; then
      selected_index="$index"
      pass_index="$index"
      print_bracket_line exact "$fail_index" "$pass_index"
      break
    fi

    fail_index="$index"
    print_bracket_line exact "$fail_index" "$pass_index"
    offset=$((offset - step))
  done

  REFINED_INDEX="$selected_index"
}

refine_bisect() {
  local fail_index="$1"
  local pass_index="$2"
  local fail_offset="${CANDIDATE_OFFSETS[$fail_index]}"
  local pass_offset="${CANDIDATE_OFFSETS[$pass_index]}"
  local low_abs high_abs mid_abs mid_offset index state selected_index sign

  echo
  echo "refine bisect"
  if (( pass_offset < 0 )); then
    sign=-1
  else
    sign=1
  fi
  low_abs="$(offset_abs "$fail_offset")"
  high_abs="$(offset_abs "$pass_offset")"
  selected_index="$pass_index"
  print_bracket_line bisect "$fail_index" "$pass_index"

  while (( high_abs - low_abs > 1 )); do
    mid_abs=$(((low_abs + high_abs) / 2))
    mid_offset=$((sign * mid_abs))
    candidate_index_for_offset "$mid_offset"
    index="$CANDIDATE_INDEX_RESULT"
    state="$(probe_candidate "$index")"
    print_probe_line "refine" "$index" "$state"
    record_timeline "refine bisect offset=${CANDIDATE_OFFSETS[$index]} direction=${CANDIDATE_DIRECTIONS[$index]} sha=${CANDIDATES[$index]} state=$state"

    if [[ "$state" == "PASS" ]]; then
      high_abs="$mid_abs"
      selected_index="$index"
      pass_index="$index"
    else
      low_abs="$mid_abs"
      fail_index="$index"
    fi
    print_bracket_line bisect "$fail_index" "$pass_index"
  done

  REFINED_INDEX="$selected_index"
}

refine_closest() {
  local fail_index="$1"
  local pass_index="$2"
  local fail_offset="${CANDIDATE_OFFSETS[$fail_index]}"
  local pass_offset="${CANDIDATE_OFFSETS[$pass_index]}"
  local low_abs high_abs mid_abs mid_offset index state selected_index sign

  echo
  echo "refine closest"
  if (( pass_offset < 0 )); then
    sign=-1
  else
    sign=1
  fi
  low_abs="$(offset_abs "$fail_offset")"
  high_abs="$(offset_abs "$pass_offset")"
  selected_index="$pass_index"
  print_bracket_line closest "$fail_index" "$pass_index"

  while (( high_abs - low_abs > EXACT_THRESHOLD )); do
    mid_abs=$(((low_abs + high_abs) / 2))
    mid_offset=$((sign * mid_abs))
    candidate_index_for_offset "$mid_offset"
    index="$CANDIDATE_INDEX_RESULT"
    state="$(probe_candidate "$index")"
    print_probe_line "refine" "$index" "$state"
    record_timeline "refine closest offset=${CANDIDATE_OFFSETS[$index]} direction=${CANDIDATE_DIRECTIONS[$index]} sha=${CANDIDATES[$index]} state=$state"

    if [[ "$state" == "PASS" ]]; then
      high_abs="$mid_abs"
      selected_index="$index"
      pass_index="$index"
    else
      low_abs="$mid_abs"
      fail_index="$index"
    fi
    print_bracket_line closest "$fail_index" "$pass_index"
  done

  refine_exact "$fail_index" "$pass_index"
  selected_index="$REFINED_INDEX"
  REFINED_INDEX="$selected_index"
}

record_timeline() {
  printf '%s\n' "$*" >> "$TIMELINE_FILE"
}

run_sampled_search() {
  local index state selected selected_index sampled_index sampled_fail_index offset last_forward_fail_index last_backward_fail_index

  echo "sample"
  selected=""
  sampled_fail_index=""
  last_forward_fail_index=""
  last_backward_fail_index=""
  for index in "${!CANDIDATES[@]}"; do
    state="$(probe_candidate "$index")"
    print_probe_line "sample" "$index" "$state"
    record_timeline "sample offset=${CANDIDATE_OFFSETS[$index]} direction=${CANDIDATE_DIRECTIONS[$index]} sha=${CANDIDATES[$index]} state=$state"

    if [[ "$state" == "PASS" ]]; then
      selected="${CANDIDATES[$index]}"
      selected_index="$index"
      break
    elif [[ "$state" == "FAIL" ]]; then
      offset="${CANDIDATE_OFFSETS[$index]}"
      if (( offset > 0 )); then
        last_forward_fail_index="$index"
      elif (( offset < 0 )); then
        last_backward_fail_index="$index"
      fi
    fi
  done

  echo
  echo "result"
  if [[ -n "$selected" ]]; then
    sampled_index="$selected_index"
    if (( CANDIDATE_OFFSETS[$selected_index] > 0 )); then
      sampled_fail_index="$last_forward_fail_index"
    elif (( CANDIDATE_OFFSETS[$selected_index] < 0 )); then
      sampled_fail_index="$last_backward_fail_index"
    fi
    if [[ -n "$sampled_fail_index" ]] && same_side_offsets "${CANDIDATE_OFFSETS[$sampled_fail_index]}" "${CANDIDATE_OFFSETS[$selected_index]}"; then
      echo "  refinement bracket: fail offset ${CANDIDATE_OFFSETS[$sampled_fail_index]} -> pass offset ${CANDIDATE_OFFSETS[$selected_index]}"
      case "$REFINE" in
        none) REFINED_INDEX="$selected_index" ;;
        exact) refine_exact "$sampled_fail_index" "$selected_index" ;;
        bisect) refine_bisect "$sampled_fail_index" "$selected_index" ;;
        closest) refine_closest "$sampled_fail_index" "$selected_index" ;;
      esac
    else
      REFINED_INDEX="$selected_index"
    fi
    selected_index="$REFINED_INDEX"
    selected="${CANDIDATES[$selected_index]}"

    echo
    echo "final"
    echo "  selected: $(short_sha "$selected") ($selected)"
    if [[ "$selected_index" == "$sampled_index" ]]; then
      echo "  reason: sampled passing candidate found"
    else
      echo "  reason: refined passing candidate found"
    fi
    echo "  refinement: $REFINE"
    echo "  offset: ${CANDIDATE_OFFSETS[$selected_index]}"
    echo "  offset meaning: $(offset_explanation "${CANDIDATE_OFFSETS[$selected_index]}")"
    echo "  candidate direction: ${CANDIDATE_DIRECTIONS[$selected_index]}"
    case "$REFINE" in
      closest)
        echo "  certainty: closest candidate proven inside the final exact-scanned bracket"
        ;;
      exact)
        echo "  certainty: closest candidate proven inside the sampled fail/pass bracket"
        ;;
      bisect)
        echo "  certainty: boundary candidate under local monotonicity assumption"
        ;;
      none)
        echo "  certainty: sampled candidate only"
        ;;
    esac
    print_output_paths "$selected"
    echo "  logs: $RUN_DIR"
    echo
    echo "next step"
    echo "  ./scripts/nixpkgs-pin-policy.sh update $selected"
  else
    echo "  selected: none"
    echo "  reason: no sampled passing candidate found within span"
    echo "  logs: $RUN_DIR"
    exit 1
  fi
}

run_search() {
  local origin cache_repo

  origin="$(resolve_origin)"
  ORIGIN_RESOLVED="$origin"
  validate_sha_format "$origin"
  cache_repo="$(init_or_update_git_cache)"
  SEARCH_CACHE_REPO="$cache_repo"
  fetch_search_refs "$cache_repo" "$origin"
  load_tracking_chain "$cache_repo" "$origin"

  RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(short_sha "$origin")"
  RUN_DIR="$CACHE_ROOT_DIR/runs/$RUN_ID"
  TIMELINE_FILE="$RUN_DIR/timeline.txt"
  mkdir -p "$RUN_DIR/candidates" || die "failed to create run directory: $RUN_DIR"

  declare -gA RESULT_STATES=()

  echo "nixpkgs pin search"
  echo "  target:       $(target_label)"
  echo "  remote:       $NIXPKGS_REMOTE_URL"
  echo "  traversal:    $TRACKING_REF"
  echo "  origin:       $(short_sha "$origin")"
  echo "  direction:    $DIRECTION"
  echo "  algorithm:    exponential fuzzy sampling"
  echo "  model:        git-bisect-like search over nixpkgs commits using Nix conditions"
  echo "  refinement:   $REFINE"
  if [[ "$REFINE" == "closest" ]]; then
    echo "  exact tail:   <= $EXACT_THRESHOLD commits"
  fi
  echo "  span:         $SPAN"
  echo "  candidates:   forward=$FORWARD_CANDIDATE_COUNT backward=$BACKWARD_CANDIDATE_COUNT"
  if [[ "$DIRECTION" == "both" && "$FORWARD_CANDIDATE_COUNT" == "0" ]]; then
    echo "  note:         origin is at traversal branch head; forward side is empty"
  fi
  echo "  run dir:      $RUN_DIR"
  echo

  record_timeline "nixpkgs pin search"
  record_timeline "target: $(target_label)"
  record_timeline "remote: $NIXPKGS_REMOTE_URL"
  record_timeline "traversal branch: $TRACKING_REF"
  record_timeline "origin: $origin"
  record_timeline "direction: $DIRECTION"
  record_timeline "refinement: $REFINE"
  if [[ "$REFINE" == "closest" ]]; then
    record_timeline "exact tail: <= $EXACT_THRESHOLD commits"
  fi
  record_timeline "span: $SPAN"
  record_timeline "candidates forward=$FORWARD_CANDIDATE_COUNT backward=$BACKWARD_CANDIDATE_COUNT"
  if [[ "$DIRECTION" == "both" && "$FORWARD_CANDIDATE_COUNT" == "0" ]]; then
    record_timeline "note: origin is at traversal branch head; forward side is empty"
  fi

  run_sampled_search
}

main() {
  parse_args "$@"
  require_cmd nix
  require_cmd git
  require_cmd jq
  require_cmd date
  cache_prepare_dirs
  run_search
}

main "$@"
