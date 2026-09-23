import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        all_bodies = {}
        async def on_response(resp):
            u = resp.url
            if "/api/v1/" in u:
                try:
                    body = await resp.json()
                except Exception:
                    body = None
                all_bodies[u] = body
                print("RESP URL:", u)
                if body is not None:
                    print("  data keys:", list(body.get("data", [{}])[0].keys()) if isinstance(body.get("data"), list) and body.get("data") else body.get("data", "no data"))
        async def on_request(req):
            if "/api/v1/" in req.url:
                print("REQ URL:", req.url)
        page.on("response", on_response)
        page.on("request", on_request)
        try:
            await page.goto(URL, wait_until="networkidle", timeout=60000)
        except Exception as e:
            print("goto warn:", e)
        await page.wait_for_timeout(6000)
        with open("organizaciones_full.json", "w", encoding="utf-8") as f:
            json.dump(all_bodies, f, ensure_ascii=False, indent=2, default=str)
        print("saved organizaciones_full.json; count:", len(all_bodies))
        await browser.close()

asyncio.run(main())