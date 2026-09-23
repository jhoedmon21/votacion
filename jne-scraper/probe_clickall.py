import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"
DISTRITAL_IDX = list(range(56, 70))

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        media = set()
        api_resp = {}
        async def on_request(req):
            u = req.url
            if any(x in u.lower() for x in [".jpg", ".png", ".pdf", ".jpeg"]) and "votoinformado" in u:
                media.add(u)
        async def on_response(resp):
            u = resp.url
            if "/api/v1/" in u and "organizacion" not in u:
                try:
                    b = await resp.json()
                    api_resp[u] = b
                except Exception:
                    pass
        page.on("request", on_request)
        page.on("response", on_response)
        await page.goto(URL, wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(3000)
        btns = page.locator("button:visible")
        for i in DISTRITAL_IDX:
            txt = (await btns.nth(i).text_content() or "").strip()
            print("=== CLICK", i, txt)
            try:
                await btns.nth(i).click()
                await page.wait_for_timeout(4000)
                await page.keyboard.press("Escape")
                await page.wait_for_timeout(1000)
            except Exception as e:
                print("  err:", e)
        print("---API RESP URLS---")
        for u in api_resp:
            print(u, type(api_resp[u]).__name__)
        print("---MEDIA URLS---")
        for u in sorted(media):
            print(u)
        with open("api_dump.json", "w", encoding="utf-8") as f:
            json.dump(api_resp, f, ensure_ascii=False, indent=2, default=str)
        await browser.close()

asyncio.run(main())