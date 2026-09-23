import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        api = {}
        async def on_response(resp):
            u = resp.url
            if "/api/v1/" in u or "candidato" in u.lower():
                try:
                    ct = resp.headers.get("content-type", "")
                    if "json" in ct:
                        api[u] = await resp.json()
                except Exception:
                    pass
        page.on("response", on_response)
        await page.goto(URL, wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(3000)
        btns = page.locator("button:visible")
        for i in range(56, 57):  # just ACCION POPULAR distrital
            try:
                await btns.nth(i).click()
                await page.wait_for_timeout(5000)
                await page.keyboard.press("Escape")
            except Exception as e:
                print("err", e)
        print("---API KEYS---")
        for u in api:
            print(u)
        with open("api_dump2.json", "w", encoding="utf-8") as f:
            json.dump(api, f, ensure_ascii=False, indent=2, default=str)
        await browser.close()

asyncio.run(main())