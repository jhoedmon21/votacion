import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        async def on_request(req):
            if "candidatos" in req.url and "organizaciones" in req.url:
                print("REQ:", req.method, req.url)
                if req.method == "POST":
                    print("  POST DATA:", req.post_data)
                print("  POST JSON:", req.post_data_json)
        page.on("request", on_request)
        await page.goto(URL, wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(3000)
        btns = page.locator("button:visible")
        await btns.nth(56).click()  # ACCION POPULAR distrital
        await page.wait_for_timeout(5000)
        await browser.close()

asyncio.run(main())