import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        reqs = set()
        async def on_response(resp):
            u = resp.url
            if "/api/v1/" in u and u not in reqs:
                reqs.add(u)
                print("RESP URL:", u)
                try:
                    b = await resp.json()
                    with open("probe_detail.json", "w", encoding="utf-8") as f:
                        json.dump(b, f, ensure_ascii=False, indent=2, default=str)
                    print("  saved detail, keys:", list(b.keys()) if isinstance(b,dict) else type(b))
                except Exception as e:
                    print("  nojson:", e)
        page.on("response", on_response)
        await page.goto(URL, wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(4000)
        # Dump card text/link structure
        cards = await page.eval_on_selector_all("a", "els => els.map(e=>e.textContent.trim().slice(0,60)+' | '+e.href)")
        for c in cards[:40]:
            print("A:", c)
        # try clicking the first card that mentions municipal
        await browser.close()

asyncio.run(main())