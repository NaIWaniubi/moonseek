"""Headless acceptance test for the registry demo.

Checks the things a reviewer would actually do: load the page, search the real
registry, click a facet, expand a score explanation, index a dropped file,
search that file, and persist/reload the snapshot through IndexedDB.

Usage: python test_registry_demo.py [base_url]
"""

import json
import os
import sys

from playwright.sync_api import sync_playwright

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8931/index.html"


def main():
    failures = []
    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        page = browser.new_page(viewport={"width": 1280, "height": 900})
        errors = []
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("console", lambda m: errors.append(m.text) if m.type == "error" else None)

        page.goto(BASE)
        page.wait_for_function(
            "document.getElementById('status').textContent.trim() === 'ready'",
            timeout=40000,
        )

        hero = {
            "docs": page.locator("#m-docs").text_content(),
            "terms": page.locator("#m-terms").text_content(),
            "load": page.locator("#m-load").text_content(),
            "median": page.locator("#m-lat").text_content(),
            "wasm": page.locator("#m-wasm").text_content(),
            "ndcg": page.locator("#m-ndcg").text_content(),
        }
        print("HERO:", hero)
        if hero["docs"].replace(",", "") != "3698":
            failures.append(f"expected 3698 docs, got {hero['docs']}")

        # ---- search a real topic and inspect ranking ----
        page.fill("#q", "parser")
        page.click("#go")
        page.wait_for_timeout(400)
        hits = page.locator("#results .hit").count()
        timing = page.locator("#results .timing").first.text_content()
        top = page.locator("#results .hit .id").first.text_content()
        print(f"SEARCH parser: hits={hits} top={top!r} timing={timing!r}")
        if hits != 10:
            failures.append(f"expected 10 hits for 'parser', got {hits}")

        # Every hit must show a highlighted snippet or a description.
        descs = page.locator("#results .hit .desc").count()
        if descs != hits:
            failures.append(f"{hits - descs} hits rendered without a snippet")

        # ---- facet chip narrows the result set ----
        chips = page.locator(".chip").count()
        print("CHIPS:", chips)
        if chips == 0:
            failures.append("no facet chips rendered")
        else:
            page.locator(".chip", has_text="Apache-2.0").first.click()
            page.wait_for_timeout(350)
            filtered = page.locator("#results .hit").count()
            active = page.locator(".chip.active").count()
            print(f"FACET Apache-2.0: hits={filtered} active={active}")
            if active != 1:
                failures.append("facet chip did not become active")
            if filtered > hits:
                failures.append("filtering increased the result count")
            page.locator("#clear-filters").click()
            page.wait_for_timeout(250)

        # ---- score explanation ----
        page.click("#results details.explain summary")
        page.wait_for_timeout(150)
        exp_rows = page.locator("#results .exp .row").count()
        print("EXPLAIN rows:", exp_rows)
        if exp_rows == 0:
            failures.append("explain panel had no scoring rows")

        # ---- dependency query (the graph question) ----
        page.fill("#q", "moonbitlang/async")
        page.click("#go")
        page.wait_for_timeout(350)
        dep_hits = page.locator("#results .hit").count()
        dep_timing = page.locator("#results .timing").first.text_content()
        print(f"SEARCH moonbitlang/async: hits={dep_hits} {dep_timing!r}")
        if dep_hits == 0:
            failures.append("dependency query returned nothing")

        # ---- CJK query ----
        page.fill("#q", "中文")
        page.click("#go")
        page.wait_for_timeout(350)
        cjk = page.locator("#results .hit").count()
        print(f"SEARCH 中文: hits={cjk}")
        if cjk == 0:
            failures.append("CJK query returned nothing")

        # ---- typo tolerance ----
        page.fill("#q", "serch")
        page.click("#go")
        page.wait_for_timeout(350)
        suggestion = page.locator("#sug").count()
        fuzzy = page.locator("#results .hit").count()
        print(f"SEARCH serch: suggestion_link={suggestion} fuzzy_hits={fuzzy}")
        if suggestion == 0 and fuzzy == 0:
            failures.append("typo query produced neither a suggestion nor fuzzy hits")

        # ---- own documents: write a file, drop it in, search it ----
        page.click('.tabs button[data-tab="own"]')
        page.wait_for_timeout(200)
        sample = (
            "# Zephyr protocol notes\n"
            "The Zephyr protocol is a fictional consensus algorithm used to test "
            "the document drop zone. It reaches finality in two rounds and uses "
            "a quorum certificate instead of a longest-chain rule.\n"
            "Unrelated filler: lanterns, orchards, quicksand.\n"
        )
        page.set_input_files(
            "#files",
            files=[
                {"name": "zephyr.md", "mimeType": "text/markdown", "buffer": sample.encode()},
                {"name": "second.md", "mimeType": "text/markdown",
                 "buffer": b"# Second document\nOrchard lanterns and quiet quicksand.\n"},
            ],
        )
        page.wait_for_timeout(600)
        stats = page.locator("#own-stats").text_content()
        files_listed = page.locator("#filelist div").count()
        print(f"OWN index: {stats!r} files={files_listed}")
        if files_listed != 2:
            failures.append(f"expected 2 files listed, got {files_listed}")

        page.fill("#q2", "quorum certificate")
        page.click("#go2")
        page.wait_for_timeout(350)
        own_hits = page.locator("#results2 .hit").count()
        own_top = page.locator("#results2 .hit .id").first.text_content() if own_hits else ""
        print(f"OWN search 'quorum certificate': hits={own_hits} top={own_top!r}")
        if own_hits == 0:
            failures.append("searching a dropped file returned nothing")

        # ---- persistence round trip through IndexedDB ----
        page.click("#own-save")
        page.wait_for_timeout(500)
        saved = page.locator("#own-stats").text_content()
        print(f"OWN save: {saved!r}")
        if "IndexedDB" not in saved:
            failures.append("snapshot was not written to IndexedDB")

        page.click("#own-clear")
        page.wait_for_timeout(200)
        page.click("#own-load")
        page.wait_for_timeout(700)
        restored = page.locator("#own-stats").text_content()
        print(f"OWN restore: {restored!r}")
        if "恢复" not in restored:
            failures.append("snapshot did not restore from IndexedDB")

        page.fill("#q2", "zephyr")
        page.click("#go2")
        page.wait_for_timeout(350)
        restored_hits = page.locator("#results2 .hit").count()
        print(f"OWN search after restore: hits={restored_hits}")
        if restored_hits == 0:
            failures.append("restored index did not answer the same query")

        # ---- bench tab: latency percentiles and the scale curve ----
        page.click('.tabs button[data-tab="bench"]')
        page.click("#bench-run")
        page.wait_for_function(
            "document.getElementById('bench-out').textContent.includes('p50')",
            timeout=60000,
        )
        bench = page.locator("#bench-out").text_content()
        curve_rows = page.locator("#scale-chart .bar-row").count()
        print("BENCH:", bench.replace("\n", " | "))
        print("SCALE curve rows:", curve_rows)
        if curve_rows < 10:
            failures.append(f"scale chart incomplete ({curve_rows} rows)")

        abl = page.locator("#ablation tr").count()
        print("ABLATION rows:", abl)
        if abl < 7:
            failures.append(f"ablation table incomplete ({abl} rows)")

        # Write the screenshot next to the committed one, derived from this
        # script's own location. A bare relative path dropped it in whatever
        # directory the test happened to be run from.
        page.screenshot(
            path=os.path.join(os.path.dirname(os.path.abspath(__file__)),
                              os.pardir, "demo", "demo-screenshot.png"),
            full_page=False,
        )

        if errors:
            print("PAGE ERRORS:", errors[:6])
            failures.extend(errors[:3])

        browser.close()

    if failures:
        print("\nFAILURES:")
        for f in failures:
            print(" -", f)
        sys.exit(1)
    print("\nALL CHECKS PASSED")


if __name__ == "__main__":
    main()