import asyncio, json
from playwright.async_api import async_playwright

URL = "https://votoinformado.jne.gob.pe/candidatos/resultados?departamento=Arequipa&depCode=04&provincia=Arequipa&provCode=01&distrito=Paucarpata&distCode=09"

async def main():
    async with async_playwright() as p:
        browser = await p.chromium.launch(headless=True)
        page = await browser.new_page()
        captured = {}
        async def on_response(resp):
            u = resp.url
            if "candidatos/organizaciones" in u or "candidato" in u.lower():
                try:
                    body = await resp.json()
                except Exception:
                    body = None
                captured[u] = body
                print("URL:", u)
                print("BODY (truncated):", json.dumps(body, ensure_ascii=False)[:3000])
        page.on("response", on_response)
        try:
            await page.goto(URL, wait_until="networkidle", timeout=60000)
        except Exception as e:
            print("goto warn:", e)
        await page.wait_for_timeout(5000)
        # save full body to file
        with open("organizaciones_raw.json", "w", encoding="utf-8") as f:
            for u, b in captured.items():
                if b is not None:
                    json.dump(b, f, ensure_ascii=False, indent=2)
        print("saved organizaciones_raw.json")
        await browser.close()

asyncio.run(main())