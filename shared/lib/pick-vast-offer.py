#!/usr/bin/env python3
"""Deterministic Vast.ai offer picker (P2.7).

Reads a Vast offer-search JSON array from stdin and prints
"<offer_id> <dph_total>" for the selected offer.

Selection policy:
  1. Drop offers whose host_id OR machine_id appears in the exclusion
     list (excluded ids come from failed hosts; the provisioner records
     the machine_id reported by `vastai show instance`, while search
     results key hosts by host_id — matching both avoids re-picking
     the same failed machine under a different label). Entries prefixed
     with "offer:" exclude a single offer id.
  2. On retry (any exclusions present), prefer an offer whose
     geolocation differs from the first remaining offer's geolocation
     (diversity of failure mode), falling back to the first offer.
  3. Otherwise take the first remaining offer.

Usage:
  echo "$offers_json" | python3 pick-vast-offer.py [excluded_id ...]
  echo "$offers_json" | python3 pick-vast-offer.py 12345 offer:67890
"""

import json
import sys


def main() -> int:
    excluded = sys.argv[1:]
    machine_excludes = {e for e in excluded if e and not e.startswith("offer:")}
    offer_excludes = {e.split(":", 1)[1] for e in excluded if e.startswith("offer:")}

    try:
        offers = json.load(sys.stdin)
    except (json.JSONDecodeError, ValueError) as exc:
        print(f"pick-vast-offer: invalid JSON on stdin: {exc}", file=sys.stderr)
        return 2

    if not isinstance(offers, list) or not offers:
        print("pick-vast-offer: no offers on stdin", file=sys.stderr)
        return 2

    remaining = [
        o
        for o in offers
        if str(o.get("host_id", "")) not in machine_excludes
        and str(o.get("machine_id", "")) not in machine_excludes
        and str(o.get("id", "")) not in offer_excludes
    ]
    if not remaining:
        print("pick-vast-offer: all offers excluded", file=sys.stderr)
        return 2

    chosen = remaining[0]
    if machine_excludes or offer_excludes:
        # Retry path: prefer a different geolocation than the top offer.
        top_geo = chosen.get("geolocation")
        for cand in remaining[1:]:
            if cand.get("geolocation") != top_geo:
                chosen = cand
                break

    print(f"{chosen.get('id', '')} {chosen.get('dph_total', '0')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
