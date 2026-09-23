import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        img_urls = set()
        async def on_response(resp):
            u = resp.url
            if "/api/v1/" in u:
                print("API URL:", u)
        async def on_request(req):
            u = req.url
            if "/api/v1/" in u:
                print("API REQ:", u)
        page.on("response", on_response)
        page.on("request", on_request)
        page.on("response", lambda r: (img_urls.add(r.url) if any(x in r.url.lower() for x in [".jpg",".png",".pdf"]) and "votoinformado" in r.url else None))
        await page.goto(URL, wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(3000)
        # click first ACCION POPULAR (distrital)
        btns = page.locator("button")
        n = await btns.count()
        for i in range(n-1, -1, -1):
            if (await btns.nth(i).text_content() or "").strip() == "ACCION POPULAR":
                await btns.nth(i).click()
                break
        await page.wait_for_timeout(6000)
        print("---IMG/PDF URLs---")
        for u in sorted(img_urls):
            print(u)
        # dump img src on detail page
        imgs = await page.eval_on_selector_all("img", "els=>els.map(e=>e.src)")
        print("---DETAIL IMGS---")
        for i in imgs:
            print(i)
        await browser.close()

asyncio.run(main())