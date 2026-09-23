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
                    print("  saved; keys:", list(b.keys()) if isinstance(b,dict) else type(b))
                except Exception as e:
                    print("  nojson", e)
        page.on("response", on_response)
        await page.goto(URL, wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(4000)
        btns = await page.eval_on_selector_all("button", "els=>els.map(e=>(e.textContent||'').trim().slice(0,50)+' class='+e.className)")
        for b in btns[:40]:
            print("BTN:", b)
        print("---count cards---")
        print(await page.locator("button").count())
        await browser.close()

asyncio.run(main())