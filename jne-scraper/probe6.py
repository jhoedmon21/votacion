import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        reqs = {}
        async def on_response(resp):
            u = resp.url
            if "/api/v1/" in u and u not in reqs:
                try:
                    b = await resp.json()
                    reqs[u] = b
                    print("RESP URL:", u)
                    with open("probe_detail.json", "w", encoding="utf-8") as f:
                        json.dump(b, f, ensure_ascii=False, indent=2, default=str)
                    if isinstance(b, dict) and "data" in b:
                        d = b["data"]
                        print("  data type:", type(d).__name__, "len:", len(d) if hasattr(d,'__len__') else '-')
                except Exception as e:
                    print("  nojson:", e, u)
        page.on("response", on_response)
        await page.goto(URL, wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(3000)
        # find the Municipal Distrital section and click its first card
        # cards have text like party name; find button whose text is ACCION POPULAR under distrital.
        # The distrital is last section. Click "ACCION POPULAR" appears multiple times; pick the last occurrence.
        btns = page.locator("button")
        n = await btns.count()
        target = None
        for i in range(n-1, -1, -1):
            t = (await btns.nth(i).text_content() or "").strip()
            if t == "ACCION POPULAR":
                target = i
                break
        print("clicking btn index", target)
        if target is not None:
            await btns.nth(target).click()
            await page.wait_for_timeout(6000)
        print("---REQS---")
        for u in reqs:
            print(u)
        await browser.close()

asyncio.run(main())