import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

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
            if "/api/v1/" in u:
                try:
                    b = await resp.json()
                    api_resp[u] = b
                except Exception:
                    pass
        page.on("request", on_request)
        page.on("response", on_response)
        await page.goto(URL, wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(3000)
        # collect visible buttons with text
        btns = page.locator("button:visible")
        n = await btns.count()
        print("visible buttons:", n)
        texts = []
        for i in range(n):
            t = (await btns.nth(i).text_content() or "").strip().replace("\n", " ")
            texts.append((i, t))
        for i, t in texts:
            print(f"[{i}] {t[:60]}")
        await browser.close()

asyncio.run(main())