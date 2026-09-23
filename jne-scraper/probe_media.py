import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        media = set()
        async def on_request(req):
            u = req.url
            if any(x in u.lower() for x in [".jpg", ".png", ".pdf", ".jpeg"]) and "votoinformado" in u:
                media.add(u)
        page.on("request", on_request)
        await page.goto(URL, wait_until="networkidle", timeout=60000)
        await page.wait_for_timeout(3000)
        # click each distrital party button to trigger candidate image loads
        btns = page.locator("button")
        n = await btns.count()
        # buttons near bottom are distrital cards; click the ones that open lists
        seen = set()
        for i in range(n):
            t = (await btns.nth(i).text_content() or "").strip()
            # capture only buttons that are party names appearing (distrital)
            await btns.nth(i).click()
            await page.wait_for_timeout(2500)
            # close if a modal opens -> press escape
            await page.keyboard.press("Escape")
            await page.wait_for_timeout(800)
        print("---MEDIA URLS---")
        for u in sorted(media):
            print(u)
        await browser.close()

asyncio.run(main())