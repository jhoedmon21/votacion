import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        urls = []
        async def on_response(resp):
            u = resp.url
            ct = resp.headers.get("content-type", "")
            if ("api" in u.lower() or "candidato" in u.lower() or "hoja" in u.lower() or "resultado" in u.lower() or u.endswith(".json")) and ("json" in ct or "api" in u.lower()):
                urls.append((u, ct))
                print("RESP:", u, ct)
        page.on("response", on_response)
        try:
            await page.goto(URL, wait_until="networkidle", timeout=60000)
        except Exception as e:
            print("goto warn:", e)
        await page.wait_for_timeout(8000)
        print("---ALL RESP URLS---")
        for u in urls:
            print(u)
        print("---TITLE---", await page.title())
        print("---BODY SNIPPET---")
        body = await page.content()
        print(body[:1500])
        await browser.close()

asyncio.run(main())