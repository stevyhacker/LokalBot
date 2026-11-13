#!/usr/bin/env python3
"""Write <film>/events.json from the composition's window.__events(), so sound follows the picture's own timing.

    python3 dump_events.py <film>/comp.html
"""
import asyncio, json, os, sys
from playwright.async_api import async_playwright


async def main(comp):
    async with async_playwright() as p:
        b = await p.chromium.launch()
        pg = await b.new_page(viewport={"width": 1920, "height": 1080})
        errs = []; pg.on("pageerror", lambda e: errs.append(str(e)))
        await pg.goto("file://" + os.path.abspath(comp))
        await pg.evaluate("window.__ready")
        ev = await pg.evaluate("window.__events()")
        extra = await pg.evaluate("window.__curves ? window.__curves() : null")
        await b.close()
    out = os.path.join(os.path.dirname(os.path.abspath(comp)), "events.json")
    json.dump({"events": ev["events"], "curves": extra}, open(out, "w"), indent=1)
    print(out, len(ev["events"]), "events", "| page errors:", errs[:3] or "none")


asyncio.run(main(sys.argv[1]))
