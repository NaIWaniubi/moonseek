#!/usr/bin/env python3
"""Compare a coordinator's facets and aggregations against a single node's.

The claim: a coordinator that fans a query out to shards, merges their
aggregations and returns the result produces the same answer as one node
holding the whole corpus. Anything less makes the distributed aggregation a
plausible-looking approximation rather than a number a client can use.

The comparison is not "same shape": facets are deep-equal, and aggregates are
compared with the tolerances their merge rules allow. Those tolerances are the
interesting part, so they are stated:

  * terms / histogram buckets  -- exact. Counts are integers summed across
    shards, and a value's count is a count.
  * stats count/min/max        -- exact. Extrema and counts recombine exactly.
  * stats sum/avg              -- within a relative 1e-9. Floating-point
    addition is not associative, so summing shard partial sums in a different
    order than the single node's one pass can differ in the last bits.
  * percentiles                -- within a relative 1e-9. The coordinator
    recomputes from the union of the shards' raw values using the engine's own
    interpolation, so this should be exact; the tolerance is for the same
    floating-point reason.

Usage: check-distributed-aggs.py <coordinator-base-url> <single-node-base-url> <query-suffix>
"""

import json
import sys
import urllib.parse
import urllib.request


def get(url):
    with urllib.request.urlopen(url, timeout=60) as response:
        return json.load(response)


def close(a, b, rel=1e-9):
    if a == b:
        return True
    scale = max(abs(a), abs(b), 1.0)
    return abs(a - b) <= rel * scale


def same_number(a, b, exact):
    if exact:
        return a == b
    return close(a, b)


def compare_aggs(coordinator, single, failures):
    if len(coordinator) != len(single):
        failures.append(
            "agg count differs: coordinator %d, single %d"
            % (len(coordinator), len(single))
        )
        return
    for index, (c, s) in enumerate(zip(coordinator, single)):
        label = "%s/%s" % (s.get("kind"), s.get("field"))
        if c.get("field") != s.get("field") or c.get("kind") != s.get("kind"):
            failures.append("agg %d is %s, single node has %s" % (
                index, c.get("kind"), s.get("kind")))
            continue
        # Buckets: exact, and in the same order.
        if c.get("buckets", []) != s.get("buckets", []):
            failures.append("%s buckets differ\n    coordinator %s\n    single      %s"
                            % (label, c.get("buckets"), s.get("buckets")))
        if "stats" in s:
            cs, ss = c["stats"], s["stats"]
            for key, exact in (("count", True), ("min", True), ("max", True),
                               ("sum", False), ("avg", False)):
                if not same_number(cs.get(key), ss.get(key), exact):
                    failures.append("%s stats.%s %r != %r"
                                    % (label, key, cs.get(key), ss.get(key)))
        if "percentiles" in s:
            cp = c.get("percentiles", [])
            sp = s["percentiles"]
            if len(cp) != len(sp):
                failures.append("%s has %d percentiles, single has %d"
                                % (label, len(cp), len(sp)))
            else:
                for (cp_, cv), (sp_, sv) in zip(cp, sp):
                    if cp_ != sp_ or not close(cv, sv):
                        failures.append("%s p=%s -> %r, single %r"
                                        % (label, cp_, cv, sv))
        print("  ok: %s" % label)


def main():
    coordinator_url, single_url, suffix = sys.argv[1], sys.argv[2], sys.argv[3]
    coordinator = get(coordinator_url + suffix)
    single = get(single_url + suffix)
    failures = []

    if coordinator.get("total") != single.get("total"):
        failures.append("total differs: coordinator %s, single %s"
                        % (coordinator.get("total"), single.get("total")))
    else:
        print("  ok: total %s" % single["total"])

    if coordinator.get("facets") != single.get("facets"):
        failures.append("facets differ\n    coordinator %s\n    single      %s"
                        % (coordinator.get("facets"), single.get("facets")))
    else:
        print("  ok: facets %s" % json.dumps(single.get("facets"), sort_keys=True))

    compare_aggs(coordinator.get("aggs", []), single.get("aggs", []), failures)

    if "agg_failed_addresses" in coordinator:
        failures.append("coordinator reported failed aggregation shards: %s"
                        % coordinator["agg_failed_addresses"])

    if failures:
        for failure in failures:
            print("FAIL: %s" % failure)
        sys.exit(1)
    print("DISTRIBUTED AGGREGATIONS MATCH THE SINGLE NODE")


if __name__ == "__main__":
    main()
