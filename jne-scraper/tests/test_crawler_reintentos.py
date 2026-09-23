"""Pruebas de la política de reintentos y backoff del crawler del JNE.

Se ejecutan sin red: el cliente recibe un `httpx.MockTransport` que responde lo
que cada caso necesita, y `asyncio.sleep` se sustituye para observar las
esperas del backoff en lugar de sufrirlas.

    cd jne-scraper && python tests/test_crawler_reintentos.py
"""
from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

import httpx

RAIZ = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(RAIZ))

import crawler_arequipa as crawler  # noqa: E402


class Respuestas:
    """Secuencia de respuestas por intento, más el registro de peticiones."""

    def __init__(self, *respuestas: httpx.Response) -> None:
        self.respuestas = list(respuestas)
        self.peticiones: list[httpx.Request] = []

    def __call__(self, request: httpx.Request) -> httpx.Response:
        self.peticiones.append(request)
        if not self.respuestas:
            return httpx.Response(200, json={"success": True, "data": []})
        respuesta = self.respuestas.pop(0)
        respuesta.request = request
        return respuesta

    @property
    def intentos(self) -> int:
        return len(self.peticiones)


class BaseCaso(unittest.IsolatedAsyncioTestCase):
    async def con_cliente(self, manejador, **kw):
        """Cliente con transporte falso y backoff capturado, sin esperas reales.

        Se sustituye `asyncio.sleep` por un no-op para no pagar el jitter del
        rate limiter, y se observa el backoff por su propio punto de paso: así
        `self.esperas` contiene sólo las esperas de reintento.
        """
        self.esperas: list[float] = []

        async def instantaneo(_segundos):
            return None

        async def registrar(segundos):
            self.esperas.append(segundos)

        cliente = crawler.JNEClient(
            crawler.RateLimiter(rps=1000.0),
            transport=httpx.MockTransport(manejador),
            **kw,
        )
        cliente._dormir = registrar  # type: ignore[method-assign]
        parche = mock.patch("asyncio.sleep", new=instantaneo)
        parche.start()
        self.addCleanup(parche.stop)
        await cliente.__aenter__()
        self.addAsyncCleanup(cliente.__aexit__)
        return cliente


class TestReintentos(BaseCaso):
    async def test_reintenta_5xx_y_acaba_ok(self):
        """503 dos veces y luego 200: reintenta, respeta el backoff y devuelve datos."""
        manejador = Respuestas(
            httpx.Response(503), httpx.Response(503),
            httpx.Response(200, json={"success": True, "data": [{"tipoEleccion": "REGIONAL"}]}),
        )
        cliente = await self.con_cliente(manejador, base_espera=2.0)

        datos = await cliente._post(crawler.API_ORG, {"dep": "04", "pro": "00", "dis": "00"})

        self.assertEqual(manejador.intentos, 3)
        self.assertEqual(len(datos["data"]), 1)
        self.assertEqual(len(self.esperas), 2, "debe esperar una vez por reintento")
        # Backoff exponencial (2s, 4s) con jitter de hasta 1s encima
        self.assertTrue(2.0 <= self.esperas[0] <= 3.0, self.esperas)
        self.assertTrue(4.0 <= self.esperas[1] <= 5.0, self.esperas)

    async def test_no_reintenta_un_4xx_de_cliente(self):
        """Un 404 es un fallo del cliente: no se insiste ni se espera."""
        manejador = Respuestas(httpx.Response(404))
        cliente = await self.con_cliente(manejador)

        with self.assertRaises(RuntimeError) as ctx:
            await cliente._post(crawler.API_ORG, {"dep": "04", "pro": "00", "dis": "00"})

        self.assertEqual(manejador.intentos, 1)
        self.assertEqual(self.esperas, [])
        self.assertIn("HTTP 404", str(ctx.exception))

    async def test_reintenta_timeouts_de_transporte(self):
        """Un fallo de conexión también se reintenta."""
        estado = {"n": 0}

        def manejador(request):
            estado["n"] += 1
            if estado["n"] == 1:
                raise httpx.ConnectTimeout("sin respuesta")
            return httpx.Response(200, json={"success": True, "data": []})

        cliente = await self.con_cliente(manejador, base_espera=1.0)
        datos = await cliente._post(crawler.API_ORG, {"dep": "04", "pro": "00", "dis": "00"})

        self.assertEqual(estado["n"], 2)
        self.assertEqual(datos["data"], [])
        self.assertEqual(len(self.esperas), 1)

    async def test_respeta_retry_after(self):
        """Un 429 con `Retry-After` manda sobre el backoff exponencial."""
        manejador = Respuestas(
            httpx.Response(429, headers={"Retry-After": "7"}),
            httpx.Response(200, json={"success": True, "data": []}),
        )
        cliente = await self.con_cliente(manejador, base_espera=2.0)

        await cliente._post(crawler.API_ORG, {"dep": "04", "pro": "00", "dis": "00"})

        self.assertEqual(self.esperas, [7.0])

    async def test_backoff_tiene_tope(self):
        """Con `max_espera` bajo, el backoff no se dispara sin límite."""
        manejador = Respuestas(*[httpx.Response(500) for _ in range(3)])
        cliente = await self.con_cliente(manejador, base_espera=2.0, max_espera=5.0,
                                         intentos=3)

        with self.assertRaises(RuntimeError):
            await cliente._post(crawler.API_ORG, {"dep": "04", "pro": "00", "dis": "00"})

        self.assertEqual(manejador.intentos, 3)
        self.assertTrue(all(e <= 6.0 for e in self.esperas), self.esperas)

    async def test_falla_rapido_sin_json(self):
        """Una respuesta que no es JSON se reporta como error, no como lista vacía."""
        manejador = Respuestas(httpx.Response(200, text="<html>portal</html>"))
        cliente = await self.con_cliente(manejador)

        with self.assertRaises(RuntimeError) as ctx:
            await cliente._post(crawler.API_ORG, {"dep": "04", "pro": "00", "dis": "00"})

        self.assertIn("no devolvió JSON", str(ctx.exception))

    async def test_success_false_es_error(self):
        """El sobre `{success: false}` del portal no debe degradarse a lista vacía."""
        manejador = Respuestas(
            httpx.Response(200, json={"success": False, "message": "sin proceso activo"})
        )
        cliente = await self.con_cliente(manejador)

        with self.assertRaises(RuntimeError) as ctx:
            await cliente.organizaciones({"dep": "04", "pro": "00", "dis": "00"})

        self.assertIn("success=False", str(ctx.exception))


class TestMedios(BaseCaso):
    def destino(self, nombre: str) -> Path:
        """Ruta real dentro de un temporal que se limpia al terminar el caso."""
        carpeta = Path(self.enterContext(tempfile.TemporaryDirectory()))
        return carpeta / "candidatos" / nombre

    async def test_no_tumba_el_ambito_si_falla_un_medio(self):
        """Un medio caído se cuenta pero no propaga la excepción."""
        manejador = Respuestas(*[httpx.Response(500) for _ in range(4)])
        cliente = await self.con_cliente(manejador)
        media = crawler.MediaDownloader(cliente, habilitado=True)
        destino = self.destino("x.jpg")

        resultado = await media.bajar("https://blob.invalido/x.jpg", destino)

        self.assertIsNone(resultado)
        self.assertEqual(media.fallidos, 1)
        self.assertEqual(media.descargados, 0)
        self.assertFalse(destino.exists())

    async def test_guarda_el_binario_y_deduplica_la_url(self):
        manejador = Respuestas(httpx.Response(200, content=b"png"))
        cliente = await self.con_cliente(manejador)
        media = crawler.MediaDownloader(cliente, habilitado=True)
        destino = self.destino("x.png")

        primero = await media.bajar("https://blob/x.png", destino)
        segundo = await media.bajar("https://blob/x.png", destino)

        self.assertEqual(primero, "x.png")
        self.assertEqual(destino.read_bytes(), b"png")
        self.assertEqual(media.descargados, 1)
        self.assertIsNone(segundo, "la segunda vez no debe volver a pedirla")
        self.assertEqual(manejador.intentos, 1)

    async def test_no_rebaja_un_archivo_ya_descargado(self):
        """Si el archivo ya existe y no está vacío, no se vuelve a pedir."""
        manejador = Respuestas()
        cliente = await self.con_cliente(manejador)
        media = crawler.MediaDownloader(cliente, habilitado=True)
        destino = self.destino("ya.jpg")
        destino.parent.mkdir(parents=True, exist_ok=True)
        destino.write_bytes(b"contenido")

        self.assertEqual(await media.bajar("https://blob/ya.jpg", destino), "ya.jpg")
        self.assertEqual(manejador.intentos, 0)

    async def test_deshabilitado_no_pide_nada(self):
        manejador = Respuestas()
        cliente = await self.con_cliente(manejador)
        media = crawler.MediaDownloader(cliente, habilitado=False)
        self.assertIsNone(await media.bajar("https://blob/x.png", Path("no-se-usa.jpg")))
        self.assertEqual(manejador.intentos, 0)


class TestPlan(unittest.TestCase):
    def test_el_plan_cubre_los_118_ambitos(self):
        """1 regional + 8 provincias + 109 distritos."""
        plan = crawler.construir_plan(crawler.cargar_ubigeo())
        por_nivel: dict[str, int] = {}
        for ambito in plan:
            por_nivel[ambito.nivel] = por_nivel.get(ambito.nivel, 0) + 1
        self.assertEqual(por_nivel, {"regional": 1, "provincial": 8, "distrital": 109})
        self.assertEqual(len(plan), 118)

    def test_los_codigos_jne_no_son_el_ubigeo_inei(self):
        """El `dis` del JNE difiere del sufijo INEI: Paucarpata es 040112 pero dis=09."""
        plan = {a.ubigeo: a for a in crawler.construir_plan(crawler.cargar_ubigeo())}
        paucarpata = plan["040112"]
        self.assertEqual(paucarpata.loc, {"dep": "04", "pro": "01", "dis": "09"})


if __name__ == "__main__":
    unittest.main(verbosity=2)
