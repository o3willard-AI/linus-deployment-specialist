#!/usr/bin/env bash
# Unified library path resolution — works at any deployment depth
# Usage: source this file, then call source_libs "logging.sh" "validation.sh"

source_lib() {
    local caller_dir
    caller_dir="$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd)"
    local search_dir="$caller_dir"
    local lib_dir=""
    
    for _ in $(seq 1 6); do
        if [[ -d "$search_dir/shared/lib" ]]; then
            lib_dir="$search_dir/shared/lib"; break
        elif [[ -d "$search_dir/lib" ]]; then
            lib_dir="$search_dir/lib"; break
        fi
        [[ "$search_dir" == "/" ]] && break
        search_dir="$(dirname "$search_dir")"
    done
    
    if [[ -z "$lib_dir" ]]; then
        echo "ERROR [paths.sh]: Cannot find lib/ directory from $caller_dir" >&2
        return 1
    fi
    
    for lib in "$@"; do
        [[ -f "$lib_dir/$lib" ]] || { echo "ERROR [paths.sh]: $lib_dir/$lib not found" >&2; return 1; }
        source "$lib_dir/$lib"
    done
}
