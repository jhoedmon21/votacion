import asyncio
from playwright.async_api import async_playwright

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(headless=True)
        page = await b.new_page()
        found = set()
        async def on_request(req):
            u = req.url
            if "blob.core.windows.net" in u and "logo" in u.lower():
                found.add(u)
        page.on("request", on_request)
        await page.goto("https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09", wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(4000)
        # grab all img srcs
        imgs = await page.eval_on_selector_all("img", "els=>els.map(e=>e.src)")
        for i in imgs:
            print("IMG:", i)
        await b.close()

asyncio.run(main())