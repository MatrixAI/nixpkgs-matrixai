#!/usr/bin/env bash

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_SYSTEM="x86_64-linux"
DEFAULT_CANDIDATE_REF="refs/heads/nixos-unstable"
NIXPKGS_OWNER="NixOS"
NIXPKGS_REPO="nixpkgs"
NIXPKGS_REMOTE_URL="https://github.com/${NIXPKGS_OWNER}/${NIXPKGS_REPO}"

CACHE_ROOT_DIR="$ROOT_DIR/tmp/package-version-intel"
API_CACHE_DIR="$CACHE_ROOT_DIR/api"
API_CACHE_TTL_SECONDS=900
HTTP_TIMEOUT_SECONDS=20

usage() {
  cat <<'EOF'
Usage:
  scripts/package-version-intel.sh current <attr-path> [--system <system>]
  scripts/package-version-intel.sh compare <attr-path> [--candidate-ref <git-ref-or-sha>] [--system <system>]

Description:
  current  Show package metadata (version/pname/name) from current nixpkgs-matrixai pinned nixpkgs.
  compare  Show current metadata and compare it against a candidate nixpkgs ref.

Resolution model:
  - candidate ref resolution is API-first (GitHub commits endpoint),
  - API responses are cached under tmp/package-version-intel/api,
  - git ls-remote is used as fallback when API resolution is unavailable.

Options:
  --system <system>
      Target system for evaluation (default: x86_64-linux).

  --candidate-ref <git-ref-or-sha>
      Candidate nixpkgs ref for compare mode. Accepts:
      - 40-char commit sha
      - refs/heads/<branch>
      - refs/tags/<tag>
      - bare branch/tag names (auto-resolved)
      (default: refs/heads/nixos-unstable)
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || die "required command not found: $name"
}

log_info() {
  echo "[package-version-intel] $*" >&2
}

cache_prepare_dirs() {
  mkdir -p "$API_CACHE_DIR" || return 1
}

file_age_seconds() {
  local path="$1"
  local now mtime

  now="$(date +%s 2>/dev/null || true)"
  mtime="$(stat -c %Y "$path" 2>/dev/null || true)"

  if [[ "$now" =~ ^[0-9]+$ ]] && [[ "$mtime" =~ ^[0-9]+$ ]]; then
    printf '%s' "$((now - mtime))"
  else
    printf '%s' "$((API_CACHE_TTL_SECONDS + 1))"
  fi
}

is_cache_fresh() {
  local cache_file="$1"
  local age

  [[ -f "$cache_file" ]] || return 1
  age="$(file_age_seconds "$cache_file")"
  [[ "$age" =~ ^[0-9]+$ ]] || return 1
  (( age <= API_CACHE_TTL_SECONDS ))
}

urlencode() {
  local input="$1"
  local encoded=""
  local i ch hex

  for ((i = 0; i < ${#input}; i++)); do
    ch="${input:$i:1}"
    case "$ch" in
      [a-zA-Z0-9.~_-]) encoded+="$ch" ;;
      *)
        printf -v hex '%%%02X' "'$ch"
        encoded+="$hex"
        ;;
    esac
  done

  printf '%s' "$encoded"
}

http_fetch_to_file() {
  local url="$1"
  local out_file="$2"

  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time "$HTTP_TIMEOUT_SECONDS" \
      -H 'Accept: application/vnd.github+json' \
      -o "$out_file" \
      "$url"
    return $?
  fi

  if command -v wget >/dev/null 2>&1; then
    wget -q -T "$HTTP_TIMEOUT_SECONDS" \
      -O "$out_file" \
      --header='Accept: application/vnd.github+json' \
      "$url"
    return $?
  fi

  return 127
}

github_commit_cache_file() {
  local ref="$1"
  local safe_ref
  safe_ref="$(urlencode "$ref")"
  printf '%s/%s-%s-%s.commit.json' "$API_CACHE_DIR" "$NIXPKGS_OWNER" "$NIXPKGS_REPO" "$safe_ref"
}

fetch_commit_json_cached() {
  local ref="$1"
  local cache_file tmp_file url

  cache_file="$(github_commit_cache_file "$ref")"

  if is_cache_fresh "$cache_file"; then
    log_info "using cached commit response for $ref"
    printf '%s\n' "$cache_file"
    return 0
  fi

  url="https://api.github.com/repos/${NIXPKGS_OWNER}/${NIXPKGS_REPO}/commits/${ref}"
  tmp_file="$(mktemp)" || return 1

  log_info "requesting commits endpoint: $url"
  if ! http_fetch_to_file "$url" "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$cache_file" || {
    rm -f "$tmp_file"
    return 1
  }

  printf '%s\n' "$cache_file"
}

parse_args() {
  SYSTEM="$DEFAULT_SYSTEM"
  CANDIDATE_REF="$DEFAULT_CANDIDATE_REF"
  POSITIONAL_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --system)
        [[ $# -ge 2 ]] || die "--system requires a value"
        SYSTEM="$2"
        shift 2
        ;;
      --candidate-ref)
        [[ $# -ge 2 ]] || die "--candidate-ref requires a value"
        CANDIDATE_REF="$2"
        shift 2
        ;;
      *)
        POSITIONAL_ARGS+=("$1")
        shift
        ;;
    esac
  done
}

attr_path_json() {
  local attr_path="$1"
  jq -cn --arg attr "$attr_path" '$attr | split(".") | map(select(length > 0))'
}

lock_nixpkgs_rev() {
  nix eval --raw --impure --expr "
    let
      l = builtins.fromJSON (builtins.readFile \"${ROOT_DIR}/flake.lock\");
    in
      l.nodes.nixpkgs.locked.rev
  " 2>/dev/null
}

resolve_candidate_ref() {
  local ref="$1"
  local resolved cache_file sha

  if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
    printf '%s|%s|literal\n' "$ref" "$ref"
    return 0
  fi

  cache_file="$(fetch_commit_json_cached "$ref" 2>/dev/null || true)"
  if [[ -n "$cache_file" ]]; then
    sha="$(jq -r '.sha // empty' "$cache_file" 2>/dev/null || true)"
    if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
      printf '%s|%s|api\n' "$ref" "$sha"
      return 0
    fi
  fi

  resolved="$(git ls-remote "$NIXPKGS_REMOTE_URL" "$ref" 2>/dev/null | awk 'NR==1 {print $1}')"
  if [[ -n "$resolved" ]]; then
    printf '%s|%s|git\n' "$ref" "$resolved"
    return 0
  fi

  if [[ "$ref" != refs/* ]]; then
    cache_file="$(fetch_commit_json_cached "refs/heads/${ref}" 2>/dev/null || true)"
    if [[ -n "$cache_file" ]]; then
      sha="$(jq -r '.sha // empty' "$cache_file" 2>/dev/null || true)"
      if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s|%s|api\n' "refs/heads/${ref}" "$sha"
        return 0
      fi
    fi

    resolved="$(git ls-remote "$NIXPKGS_REMOTE_URL" "refs/heads/${ref}" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -n "$resolved" ]]; then
      printf '%s|%s|git\n' "refs/heads/${ref}" "$resolved"
      return 0
    fi

    cache_file="$(fetch_commit_json_cached "refs/tags/${ref}" 2>/dev/null || true)"
    if [[ -n "$cache_file" ]]; then
      sha="$(jq -r '.sha // empty' "$cache_file" 2>/dev/null || true)"
      if [[ "$sha" =~ ^[0-9a-f]{40}$ ]]; then
        printf '%s|%s|api\n' "refs/tags/${ref}" "$sha"
        return 0
      fi
    fi

    resolved="$(git ls-remote "$NIXPKGS_REMOTE_URL" "refs/tags/${ref}" 2>/dev/null | awk 'NR==1 {print $1}')"
    if [[ -n "$resolved" ]]; then
      printf '%s|%s|git\n' "refs/tags/${ref}" "$resolved"
      return 0
    fi
  fi

  die "unable to resolve candidate ref in nixpkgs remote: $ref"
}

eval_meta_at_sha() {
  local attr_json="$1"
  local sha="$2"

  nix eval --json --impure --expr "
    let
      np = builtins.getFlake \"github:NixOS/nixpkgs/${sha}\";
      pkgs = import np.outPath {
        system = \"${SYSTEM}\";
        config.allowUnfree = true;
      };
      attrPath = builtins.fromJSON ''${attr_json}'';
      resolvePath = path: attrs:
        builtins.foldl'
          (state: key:
            if !state.ok then state
            else if builtins.isAttrs state.value && builtins.hasAttr key state.value then {
              ok = true;
              value = builtins.getAttr key state.value;
            } else {
              ok = false;
              value = null;
            })
          { ok = true; value = attrs; }
          path;
      resolved = resolvePath attrPath pkgs;
      pkg = if resolved.ok then resolved.value else null;
      isAttrs = builtins.isAttrs pkg;
    in
      {
        present = resolved.ok;
        version = if isAttrs && (pkg ? version) then pkg.version else null;
        pname = if isAttrs && (pkg ? pname) then pkg.pname else null;
        name = if isAttrs && (pkg ? name) then pkg.name else null;
      }
  " 2>/dev/null
}

fetch_compare_json_cached() {
  local base_sha="$1"
  local head_sha="$2"
  local cache_file tmp_file url

  cache_file="$(printf '%s/%s-%s-%s-%s.compare.json' "$API_CACHE_DIR" "$NIXPKGS_OWNER" "$NIXPKGS_REPO" "$base_sha" "$head_sha")"

  if is_cache_fresh "$cache_file"; then
    log_info "using cached compare response: $cache_file"
    printf '%s\n' "$cache_file"
    return 0
  fi

  url="https://api.github.com/repos/${NIXPKGS_OWNER}/${NIXPKGS_REPO}/compare/${base_sha}...${head_sha}"
  tmp_file="$(mktemp)" || return 1

  log_info "requesting compare endpoint: $url"
  if ! http_fetch_to_file "$url" "$tmp_file"; then
    rm -f "$tmp_file"
    return 1
  fi

  mv "$tmp_file" "$cache_file" || {
    rm -f "$tmp_file"
    return 1
  }

  printf '%s\n' "$cache_file"
}

signed_days_delta() {
  local older_epoch="$1"
  local newer_epoch="$2"
  local delta sign

  delta=$((newer_epoch - older_epoch))
  sign="+"

  if (( delta < 0 )); then
    sign="-"
    delta=$((-delta))
  fi

  printf '%s%d' "$sign" "$((delta / 86400))"
}

print_topology_block() {
  local current_rev="$1"
  local candidate_sha="$2"
  local compare_file ahead behind merge_base
  local current_date candidate_date merge_base_date current_epoch candidate_epoch age_delta

  compare_file="$(fetch_compare_json_cached "$current_rev" "$candidate_sha" 2>/dev/null || true)"
  if [[ -z "$compare_file" ]]; then
    echo "  topology: unavailable (compare endpoint not available)"
    return 0
  fi

  ahead="$(jq -r '.ahead_by // empty' "$compare_file" 2>/dev/null || true)"
  behind="$(jq -r '.behind_by // empty' "$compare_file" 2>/dev/null || true)"
  merge_base="$(jq -r '.merge_base_commit.sha // empty' "$compare_file" 2>/dev/null || true)"
  current_date="$(jq -r '.base_commit.committer.date // .base_commit.author.date // empty' "$compare_file" 2>/dev/null || true)"
  merge_base_date="$(jq -r '.merge_base_commit.committer.date // .merge_base_commit.author.date // empty' "$compare_file" 2>/dev/null || true)"

  candidate_date="$(
    fetch_commit_json_cached "$candidate_sha" 2>/dev/null \
      | xargs -r -I{} jq -r '.commit.committer.date // .commit.author.date // empty' "{}" 2>/dev/null \
      || true
  )"

  current_epoch="$(date -u -d "$current_date" +%s 2>/dev/null || true)"
  candidate_epoch="$(date -u -d "$candidate_date" +%s 2>/dev/null || true)"

  if [[ "$current_epoch" =~ ^[0-9]+$ ]] && [[ "$candidate_epoch" =~ ^[0-9]+$ ]]; then
    age_delta="$(signed_days_delta "$current_epoch" "$candidate_epoch")"
  else
    age_delta="unavailable"
  fi

  echo "  topology"
  echo "    ahead count (current-only): ${behind:-unavailable}"
  echo "    behind count (candidate-only): ${ahead:-unavailable}"
  echo "    merge-base: ${merge_base:-unavailable}"
  echo "    merge-base date: ${merge_base_date:-unavailable}"
  echo "    current pin date: ${current_date:-unavailable}"
  echo "    candidate pin date: ${candidate_date:-unavailable}"
  echo "    age delta (candidate - current): ${age_delta} days"
}

print_meta_block() {
  local title="$1"
  local meta_json="$2"

  echo "$title"
  echo "  present: $(jq -r '.present // false' <<< "$meta_json")"
  echo "  version: $(jq -r '.version // "unknown"' <<< "$meta_json")"
  echo "  pname:   $(jq -r '.pname // "unknown"' <<< "$meta_json")"
  echo "  name:    $(jq -r '.name // "unknown"' <<< "$meta_json")"
}

status_from_versions() {
  local current="$1"
  local candidate="$2"

  if [[ "$current" == "unknown" || "$candidate" == "unknown" ]]; then
    printf '%s\n' "UNKNOWN"
    return 0
  fi

  if [[ "$current" == "$candidate" ]]; then
    printf '%s\n' "UNCHANGED"
  else
    printf '%s\n' "CHANGED"
  fi
}

cmd_current() {
  local attr_path="$1"
  local attr_json current_meta current_rev

  attr_json="$(attr_path_json "$attr_path")"
  current_rev="$(lock_nixpkgs_rev || true)"
  [[ "$current_rev" =~ ^[0-9a-f]{40}$ ]] || die "failed to resolve current nixpkgs rev from flake.lock"

  current_meta="$(eval_meta_at_sha "$attr_json" "$current_rev" || true)"
  [[ -n "$current_meta" ]] || die "failed to evaluate current metadata for attr path: $attr_path"

  echo "package version intel"
  echo "  mode:        current"
  echo "  attr path:   $attr_path"
  echo "  system:      $SYSTEM"
  echo "  nixpkgs rev: ${current_rev:-unknown}"
  echo
  print_meta_block "current pin" "$current_meta"
}

cmd_compare() {
  local attr_path="$1"
  local attr_json current_meta current_rev candidate_tuple candidate_ref_used candidate_sha candidate_source
  local candidate_meta current_version candidate_version status

  attr_json="$(attr_path_json "$attr_path")"
  current_rev="$(lock_nixpkgs_rev || true)"
  [[ "$current_rev" =~ ^[0-9a-f]{40}$ ]] || die "failed to resolve current nixpkgs rev from flake.lock"

  current_meta="$(eval_meta_at_sha "$attr_json" "$current_rev" || true)"
  [[ -n "$current_meta" ]] || die "failed to evaluate current metadata for attr path: $attr_path"

  candidate_tuple="$(resolve_candidate_ref "$CANDIDATE_REF")"
  candidate_ref_used="$(printf '%s' "$candidate_tuple" | awk -F'|' '{print $1}')"
  candidate_sha="$(printf '%s' "$candidate_tuple" | awk -F'|' '{print $2}')"
  candidate_source="$(printf '%s' "$candidate_tuple" | awk -F'|' '{print $3}')"

  candidate_meta="$(eval_meta_at_sha "$attr_json" "$candidate_sha" || true)"
  [[ -n "$candidate_meta" ]] || die "failed to evaluate candidate metadata for attr path: $attr_path at $candidate_sha"

  current_version="$(jq -r '.version // "unknown"' <<< "$current_meta")"
  candidate_version="$(jq -r '.version // "unknown"' <<< "$candidate_meta")"
  status="$(status_from_versions "$current_version" "$candidate_version")"

  echo "package version intel"
  echo "  mode:                 compare"
  echo "  attr path:            $attr_path"
  echo "  system:               $SYSTEM"
  echo "  current nixpkgs rev:  ${current_rev:-unknown}"
  echo "  candidate ref input:  $CANDIDATE_REF"
  echo "  candidate ref used:   $candidate_ref_used"
  echo "  candidate sha:        $candidate_sha"
  echo "  resolve source:       ${candidate_source:-unknown}"
  echo "  compare status:       $status"
  print_topology_block "$current_rev" "$candidate_sha"
  echo
  print_meta_block "current pin" "$current_meta"
  echo
  print_meta_block "candidate pin" "$candidate_meta"
}

main() {
  parse_args "$@"

  require_cmd nix
  require_cmd git
  require_cmd jq
  require_cmd date

  if ! cache_prepare_dirs; then
    log_info "warning: failed to prepare cache directory under $CACHE_ROOT_DIR"
  fi

  local cmd="${POSITIONAL_ARGS[0]:-}"
  local attr_path="${POSITIONAL_ARGS[1]:-}"

  [[ -n "$cmd" ]] || {
    usage
    exit 1
  }

  [[ -n "$attr_path" ]] || die "attribute path is required"

  case "$cmd" in
    current)
      if [[ ${#POSITIONAL_ARGS[@]} -ne 2 ]]; then
        usage
        exit 1
      fi
      cmd_current "$attr_path"
      ;;
    compare)
      if [[ ${#POSITIONAL_ARGS[@]} -ne 2 ]]; then
        usage
        exit 1
      fi
      cmd_compare "$attr_path"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
