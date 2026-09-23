import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        async def on_request(req):
            u = req.url
            if "organizaciones/candidatos" in u:
                print("FULL REQ URL:", u)
                print("METHOD:", req.method)
                if req.method == "POST":
                    print("POST DATA:", req.post_data)
        page.on("request", on_request)
        await page.goto(URL, wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(3000)
        btns = page.locator("button")
        n = await btns.count()
        for i in range(n-1, -1, -1):
            if (await btns.nth(i).text_content() or "").strip() == "ACCION POPULAR":
                await btns.nth(i).click()
                break
        await page.wait_for_timeout(6000)
        await browser.close()

asyncio.run(main())