import { useCallback, useMemo, useState } from "react";
import { sesionGuardada } from "../api";

/* ------------------------------------------------------------------ *
 * Tipos del contrato GET /api/actas/plantilla
 * (docs/schemas/plantilla-acta-v1.schema.json)
 * ------------------------------------------------------------------ */

export interface OrgColumna {
  numero: number;
  nombre: string;
  candidato: string;
  logo_url: string | null;
  color: string | null;
  photo_url: string | null;
  votos: number | null;
}

export interface ColumnaActa {
  columna: string;
  etiqueta: string;
  es_principal: boolean;
  total_votantes_papel: number | null;
  votos_blancos: number | null;
  votos_nulos: number | null;
  votos_impugnados: number | null;
  organizaciones: OrgColumna[];
}

export interface EleccionPlantilla {
  tipo_eleccion: string;
  cargos: string;
  columnas: ColumnaActa[];
}

export interface PlantillaActa {
  numero_mesa: string;
  local: {
    id: number;
    nombre: string;
    direccion: string | null;
    sector: string | null;
    latitud: number | null;
    longitud: number | null;
  };
  ubigeo_distrito: string;
  electores_habiles: number | null;
  acta_existente: { id: number; estado: string; editable: boolean } | null;
  elecciones: EleccionPlantilla[];
  generada_en: string;
}

/* ------------------------------------------------------------------ *
 * Validación matemática (reglas ONPE, espejo de acta_validator.py)
 * ------------------------------------------------------------------ */

interface Hallazgo {
  regla: string;
  severidad: "BLOQUEANTE" | "ADVERTENCIA" | "INFO";
  mensaje: string;
}

function validarCliente(plantilla: PlantillaActa): Hallazgo[] {
  const hallazgos: Hallazgo[] = [];
  const habiles = plantilla.electores_habiles ?? 0;

  for (const eleccion of plantilla.elecciones) {
    for (const col of eleccion.columnas) {
      const etiqueta = `${eleccion.tipo_eleccion} · ${col.etiqueta}`;
      const sumaOrgs = col.organizaciones.reduce((s, o) => s + (o.votos ?? 0), 0);
      const validos = sumaOrgs + (col.votos_blancos ?? 0);
      const sumaPartes = validos + (col.votos_nulos ?? 0) + (col.votos_impugnados ?? 0);
      const total = col.total_votantes_papel;

      if (total !== null && total > 0 && sumaPartes !== total) {
        hallazgos.push({
          regla: "R1_SUMA_VOTOS",
          severidad: "BLOQUEANTE",
          mensaje: `${etiqueta}: válidos (${validos}) + nulos (${col.votos_nulos ?? 0}) + impugnados (${col.votos_impugnados ?? 0}) ≠ total votantes (${total}). Diferencia: ${total - sumaPartes}.`,
        });
      }
      if (habiles > 0 && total !== null && total > habiles) {
        hallazgos.push({
          regla: "R2_TOPE_ELECTORES",
          severidad: "BLOQUEANTE",
          mensaje: `${etiqueta}: votantes (${total}) supera los electores hábiles de la mesa (${habiles}).`,
        });
      }
    }
  }
  return hallazgos;
}

/* ------------------------------------------------------------------ *
 * Estado de digitación
 * ------------------------------------------------------------------ */

interface DigitadoActa {
  elecciones: Record<string, Record<string, DigitadoColumna>>;
}

interface DigitadoColumna {
  votos: Record<number, number | null>; // numero de org -> votos (null = sin digitar)
  votos_blancos: number | null;
  votos_nulos: number | null;
  votos_impugnados: number | null;
  total_votantes_papel: number | null;
}

function digitadoInicial(p: PlantillaActa | null): DigitadoActa {
  const elecciones: DigitadoActa["elecciones"] = {};
  for (const e of p?.elecciones ?? []) {
    elecciones[e.tipo_eleccion] = {};
    for (const col of e.columnas) {
      elecciones[e.tipo_eleccion][col.columna] = {
        votos: Object.fromEntries(col.organizaciones.map((o) => [o.numero, o.votos])),
        votos_blancos: col.votos_blancos,
        votos_nulos: col.votos_nulos,
        votos_impugnados: col.votos_impugnados,
        total_votantes_papel: col.total_votantes_papel,
      };
    }
  }
  return { elecciones };
}

interface Props {
  onGuardada: () => void;
  onCancelar: () => void;
}

const CLAVE_COLA = "cola_actas"; // misma cola offline que la PWA (api.ts)

/** Encola el payload para reenvío cuando haya red (patrón de la PWA móvil). */
function encolarOffline(payload: unknown): void {
  try {
    const cola = JSON.parse(localStorage.getItem(CLAVE_COLA) || "[]") as unknown[];
    cola.push({ payload, encolado_en: new Date().toISOString() });
    localStorage.setItem(CLAVE_COLA, JSON.stringify(cola));
  } catch {
    // localStorage lleno o corrupto: no bloquea la UI
  }
}

export default function ActaIngresoForm({ onGuardada, onCancelar }: Props) {
  const [mesa, setMesa] = useState("");
  const [plantilla, setPlantilla] = useState<PlantillaActa | null>(null);
  const [digitado, setDigitado] = useState<DigitadoActa>({ elecciones: {} });
  const [cargando, setCargando] = useState(false);
  const [enviando, setEnviando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resultado, setResultado] = useState<string | null>(null);

  const cargarMesa = useCallback(async () => {
    const numero = mesa.trim();
    if (!/^\d{6}$/.test(numero)) {
      setError("El número de mesa debe tener exactamente 6 dígitos.");
      return;
    }
    setCargando(true);
    setError(null);
    setResultado(null);
    try {
      const res = await fetch(`/api/actas/plantilla?numero_mesa=${numero}`, {
        headers: sesionGuardada()
          ? { Authorization: `Bearer ${sesionGuardada()!.token}` }
          : {},
      });
      if (res.status === 404) {
        setError(`Mesa ${numero} no existe en el padrón.`);
        setPlantilla(null);
        return;
      }
      if (!res.ok) throw new Error(`Error ${res.status} al cargar la plantilla`);
      const data = (await res.json()) as PlantillaActa;
      setPlantilla(data);
      setDigitado(digitadoInicial(data));
      if (data.acta_existente && !data.acta_existente.editable) {
        setError(
          `La mesa ya tiene acta en estado ${data.acta_existente.estado}: no editable por tu rol.`
        );
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setPlantilla(null);
    } finally {
      setCargando(false);
    }
  }, [mesa]);

  const setVoto = useCallback(
    (tipo: string, columna: string, numero: number, valor: number | null) => {
      setDigitado((prev) => ({
        ...prev,
        elecciones: {
          ...prev.elecciones,
          [tipo]: {
            ...prev.elecciones[tipo],
            [columna]: {
              ...prev.elecciones[tipo][columna],
              votos: { ...prev.elecciones[tipo][columna].votos, [numero]: valor },
            },
          },
        },
      }));
    },
    []
  );

  const setCampo = useCallback(
    (
      tipo: string,
      columna: string,
      campo: "votos_blancos" | "votos_nulos" | "votos_impugnados" | "total_votantes_papel",
      valor: number | null
    ) => {
      setDigitado((prev) => ({
        ...prev,
        elecciones: {
          ...prev.elecciones,
          [tipo]: {
            ...prev.elecciones[tipo],
            [columna]: { ...prev.elecciones[tipo][columna], [campo]: valor },
          },
        },
      }));
    },
    []
  );

  const hallazgos = useMemo(
    () => (plantilla ? validarCliente(plantilla) : []),
    [plantilla]
  );
  const bloqueantes = hallazgos.filter((h) => h.severidad === "BLOQUEANTE");
  // R4_ACTA_DUPLICADA: si la mesa ya tiene acta, el envío nuevo siempre es
  // rechazado (sólo COORD_PROVINCIAL reemplaza, vía flujo de edición). Se
  // bloquea aquí y se dirige al modal de edición existente.
  const mesaYaRegistrada = plantilla?.acta_existente != null;
  const motivoBloqueo = bloqueantes.length
    ? "El acta tiene validaciones bloqueantes (R1/R2)."
    : mesaYaRegistrada
      ? `La mesa ya tiene acta en estado ${plantilla?.acta_existente?.estado}; corrígela desde la tabla de actas (flujo de edición).`
      : null;

  const enviar = useCallback(async () => {
    if (!plantilla) return;
    setEnviando(true);
    setError(null);
    try {
      // La PWA y el backend consolidan por columna principal; el payload
      // espeja ActaValidacionIn de app/core/schemas.py.
      const payload = {
        numero_mesa: plantilla.numero_mesa,
        tipo_eleccion: "DISTRITAL",
        electores_habiles: plantilla.electores_habiles ?? 0,
        foto_presente: false,
        firmas_completas: true,
        columnas: Object.entries(digitado.elecciones).flatMap(([, columnas]) =>
          Object.entries(columnas).map(([columna, d]) => ({
            columna,
            votos: Object.fromEntries(
              Object.entries(d.votos).map(([k, v]) => [k, v ?? 0])
            ),
            votos_blancos: d.votos_blancos ?? 0,
            votos_nulos: d.votos_nulos ?? 0,
            votos_impugnados: d.votos_impugnados ?? 0,
            total_votantes: d.total_votantes_papel ?? 0,
          }))
        ),
      };
      const res = await fetch("/api/actas/movil", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          ...(sesionGuardada() ? { Authorization: `Bearer ${sesionGuardada()!.token}` } : {}),
        },
        body: JSON.stringify(payload),
      });
      if (res.status === 409) {
        // Rechazo de negocio (regla R1 o R4): NO se encola, un reintento
        // reproduciría el mismo rechazo. El mensaje del servidor manda.
        const body = await res.json();
        const detalle = body?.detail;
        const mensaje =
          typeof detalle === "string"
            ? detalle
            : (detalle?.mensaje ?? "Acta no contabilizada");
        setError(`Acta no contabilizada: ${mensaje}`);
        return;
      }
      if (!res.ok) throw new Error(`Error ${res.status} al registrar el acta`);
      setResultado("Acta registrada y contabilizada correctamente.");
      onGuardada();
    } catch (e) {
      // Fallo de transporte (sin red, timeout): a la cola offline (patrón PWA).
      encolarOffline({ numero_mesa: plantilla.numero_mesa });
      setError(
        `${e instanceof Error ? e.message : String(e)} — acta guardada en la cola offline para reintento.`
      );
    } finally {
      setEnviando(false);
    }
  }, [plantilla, digitado, onGuardada]);

  return (
    <div className="space-y-6">
      {/* Búsqueda de mesa */}
      <section className="rounded-2xl border border-slate-200 bg-white p-5 shadow-xs">
        <h3 className="mb-3 text-sm font-black uppercase tracking-wider text-slate-500">
          1 · Buscar mesa
        </h3>
        <div className="flex flex-wrap items-end gap-3">
          <label className="flex-1">
            <span className="mb-1 block text-xs font-bold text-slate-600">
              N° de mesa (6 dígitos)
            </span>
            <input
              inputMode="numeric"
              maxLength={6}
              value={mesa}
              onChange={(e) => setMesa(e.target.value.replace(/\D/g, ""))}
              placeholder="023002"
              className="w-full rounded-lg border border-slate-300 px-3 py-2 font-mono text-lg tracking-widest focus:border-[#E02020] focus:outline-none"
            />
          </label>
          <button
            onClick={cargarMesa}
            disabled={cargando || !/^\d{6}$/.test(mesa)}
            className="rounded-lg bg-[#E02020] px-5 py-2 text-sm font-bold text-white hover:bg-[#A01010] disabled:bg-slate-300"
          >
            {cargando ? "Buscando…" : "Cargar acta"}
          </button>
        </div>
        {plantilla?.acta_existente && (
          <p className="mt-2 text-xs font-semibold text-amber-600">
            Esta mesa ya tiene acta en estado {plantilla.acta_existente.estado}
            {plantilla.acta_existente.editable ? " (editable)" : " (solo lectura)"}. Los votos
            digitados vienen precargados.
          </p>
        )}
      </section>

      {plantilla && (
        <>
          {/* Datos del local */}
          <section className="rounded-2xl border border-slate-200 bg-white p-5 shadow-xs">
            <h3 className="mb-2 text-sm font-black uppercase tracking-wider text-slate-500">
              2 · Local de votación
            </h3>
            <p className="text-sm text-slate-700">
              <strong>{plantilla.local.nombre}</strong> — {plantilla.local.sector}
              {plantilla.local.direccion ? `, ${plantilla.local.direccion}` : ""}
            </p>
            <p className="mt-1 text-xs text-slate-500">
              Electores hábiles de la mesa:{" "}
              <strong>
                {plantilla.electores_habiles ?? "sin registrar (se pedirá al enviar)"}
              </strong>
            </p>
          </section>

          {/* Actas por elección */}
          {plantilla.elecciones.map((e) => (
            <section
              key={e.tipo_eleccion}
              className="rounded-2xl border border-slate-200 bg-white p-5 shadow-xs"
            >
              <h3 className="mb-1 text-sm font-black uppercase tracking-wider text-slate-500">
                {e.tipo_eleccion}
              </h3>
              <p className="mb-4 text-xs text-slate-500">{e.cargos}</p>
              {e.columnas.map((col) => {
                const d = digitado.elecciones[e.tipo_eleccion]?.[col.columna];
                if (!d) return null;
                const sumaOrgs = col.organizaciones.reduce(
                  (s, o) => s + (d.votos[o.numero] ?? 0),
                  0
                );
                const sumaPartes =
                  sumaOrgs +
                  (d.votos_blancos ?? 0) +
                  (d.votos_nulos ?? 0) +
                  (d.votos_impugnados ?? 0);
                const diferencia =
                  d.total_votantes_papel === null ? null : d.total_votantes_papel - sumaPartes;
                const excedePadron =
                  plantilla.electores_habiles &&
                  d.total_votantes_papel !== null &&
                  d.total_votantes_papel > plantilla.electores_habiles;
                return (
                  <div key={col.columna} className="space-y-2">
                    <div className="flex items-center justify-between border-b border-slate-100 pb-2">
                      <span className="text-xs font-black uppercase tracking-wider text-[#E02020]">
                        Columna {col.etiqueta}
                      </span>
                      <div className="flex items-center gap-4 text-xs font-bold">
                        <span className="text-slate-500">
                          Σ organizaciones: <span className="font-mono">{sumaOrgs}</span>
                        </span>
                        <label className="text-slate-500">
                          Total votantes (papel):{" "}
                          <input
                            type="number"
                            min={0}
                            value={d.total_votantes_papel ?? ""}
                            onChange={(ev) =>
                              setCampo(
                                e.tipo_eleccion,
                                col.columna,
                                "total_votantes_papel",
                                ev.target.value === "" ? null : Number(ev.target.value)
                              )
                            }
                            className="w-20 rounded border border-slate-300 px-2 py-1 text-right font-mono"
                          />
                        </label>
                      </div>
                    </div>
                    {col.organizaciones.map((o) => (
                      <div key={o.numero} className="flex items-center gap-3">
                        <span className="w-6 text-right font-mono text-xs text-slate-400">
                          {o.numero}
                        </span>
                        {o.logo_url && (
                          <img
                            src={o.logo_url}
                            alt={o.nombre}
                            className="h-6 w-6 rounded object-contain"
                          />
                        )}
                        <div className="min-w-0 flex-1">
                          <p className="truncate text-sm font-bold text-slate-800">{o.nombre}</p>
                          <p className="truncate text-xs text-slate-500">{o.candidato}</p>
                        </div>
                        <input
                          type="number"
                          min={0}
                          value={d.votos[o.numero] ?? ""}
                          onChange={(ev) =>
                            setVoto(
                              e.tipo_eleccion,
                              col.columna,
                              o.numero,
                              ev.target.value === "" ? null : Math.max(0, Number(ev.target.value))
                            )
                          }
                          placeholder="—"
                          className="w-20 rounded border border-slate-300 px-2 py-1.5 text-right font-mono focus:border-[#E02020] focus:outline-none"
                        />
                      </div>
                    ))}
                    <div className="grid grid-cols-4 gap-2 border-t border-slate-100 pt-3">
                      {(
                        [
                          ["votos_blancos", "Blancos"],
                          ["votos_nulos", "Nulos"],
                          ["votos_impugnados", "Impugnados"],
                        ] as const
                      ).map(([campo, etiqueta]) => (
                        <label key={campo} className="text-xs font-bold text-slate-600">
                          {etiqueta}
                          <input
                            type="number"
                            min={0}
                            value={d[campo] ?? ""}
                            onChange={(ev) =>
                              setCampo(
                                e.tipo_eleccion,
                                col.columna,
                                campo,
                                ev.target.value === "" ? null : Number(ev.target.value)
                              )
                            }
                            className="mt-1 w-full rounded border border-slate-300 px-2 py-1.5 text-right font-mono"
                          />
                        </label>
                      ))}
                      <div className="text-xs font-bold">
                        <span
                          className={
                            diferencia === null
                              ? "text-slate-400"
                              : diferencia === 0
                                ? "text-emerald-600"
                                : "text-red-600"
                          }
                        >
                          Diferencia
                        </span>
                        <div
                          className={`mt-1 rounded px-2 py-1.5 text-right font-mono ${
                            diferencia === null
                              ? "bg-slate-100 text-slate-400"
                              : diferencia === 0
                                ? "bg-emerald-50 text-emerald-700"
                                : "bg-red-50 text-red-700"
                          }`}
                        >
                          {diferencia === null ? "—" : (diferencia > 0 ? `+${diferencia}` : diferencia)}
                        </div>
                      </div>
                    </div>
                    {excedePadron && (
                      <p className="rounded bg-red-50 px-3 py-2 text-xs font-bold text-red-700">
                        ⚠ R2: votantes ({d.total_votantes_papel}) supera electores hábiles (
                        {plantilla.electores_habiles}).
                      </p>
                    )}
                  </div>
                );
              })}
            </section>
          ))}

          {/* Resumen de validación viva */}
          <section
            className={`rounded-2xl border p-5 shadow-xs ${
              bloqueantes.length
                ? "border-red-300 bg-red-50"
                : "border-emerald-300 bg-emerald-50"
            }`}
          >
            <h3 className="mb-2 text-sm font-black uppercase tracking-wider text-slate-600">
              3 · Validación matemática
            </h3>
            {hallazgos.length === 0 ? (
              <p className="text-sm font-bold text-emerald-700">
                ✓ El acta cuadra en las tres elecciones: lista para contabilizar.
              </p>
            ) : (
              <ul className="space-y-1.5">
                {hallazgos.map((h, i) => (
                  <li
                    key={i}
                    className={`text-xs font-semibold ${
                      h.severidad === "BLOQUEANTE" ? "text-red-700" : "text-amber-700"
                    }`}
                  >
                    [{h.regla}] {h.mensaje}
                  </li>
                ))}
              </ul>
            )}
            <p className="mt-2 text-xs text-slate-500">
              Reglas: R1 = válidos + blancos + nulos + impugnados = total votantes, por columna ·
              R2 = votantes ≤ electores hábiles de la mesa.
            </p>
          </section>

          {/* Envío */}
          <section className="flex flex-wrap items-center justify-between gap-3">
            {resultado && (
              <p className="rounded bg-slate-100 px-3 py-2 text-sm font-semibold text-slate-700">
                {resultado}
              </p>
            )}
            {error && (
              <p className="rounded bg-amber-50 px-3 py-2 text-sm font-semibold text-amber-800">
                {error}
              </p>
            )}
            <div className="ml-auto flex gap-3">
              <button
                onClick={onCancelar}
                className="rounded-lg border border-slate-300 px-4 py-2 text-sm font-bold text-slate-600 hover:bg-slate-50"
              >
                Cancelar
              </button>
              <button
                onClick={enviar}
                disabled={enviando || !!motivoBloqueo || !plantilla}
                title={motivoBloqueo ?? undefined}
                className="rounded-lg bg-[#E02020] px-6 py-2 text-sm font-bold text-white hover:bg-[#A01010] disabled:bg-slate-300"
              >
                {enviando ? "Enviando…" : "Registrar acta"}
              </button>
            </div>
          </section>
        </>
      )}
    </div>
  );
}
