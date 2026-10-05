import { useEffect, useState } from "react";
import { api } from "../api";
import type { ElectorFicha } from "../types";
import { Alerta, Boton, Campo, Input } from "./ui";

/* ==================================================================== *
 *  Ventana de edición de ELECTORES HÁBILES de una mesa (tables).
 *
 *  El usuario manda el N° de mesa; el backend busca el id que le
 *  corresponde en `tables` y aplica en una transacción:
 *
 *    UPDATE tables SET electores_habiles = :n, processed = 0,
 *           requires_review = 0, status = 'pending' WHERE id = :id;
 *    DELETE FROM acta_metadata WHERE table_id = :id;
 *    DELETE FROM records        WHERE table_id = :id;
 *
 *  O sea: editar el padrón REINICIA el acta de la mesa (vuelve a
 *  PENDIENTE y se borran sus votos). La ventana muestra la ficha
 *  actual de la mesa y avisa del borrado antes de confirmar.
 * ==================================================================== */

interface Props {
  /** Mesa con la que abrir pre-cargada (clic en una fila de la tabla). */
  mesaInicial?: string | null;
  onClose: () => void;
  /** Se dispara al guardar OK para refrescar la tabla detrás. */
  onGuardado: () => void;
}

interface ResultadoGuardado {
  id: number;
  numero_mesa: string;
  electores_habiles: number | null;
  eliminados: { records: number; acta_metadata: number };
}

const num = (v: number | null | undefined) => (v ?? 0).toLocaleString("es-PE");

export default function EditarElectoresHabilesModal({ mesaInicial, onClose, onGuardado }: Props) {
  const [mesa, setMesa] = useState(mesaInicial ?? "");
  const [habiles, setHabiles] = useState("");
  const [motivo, setMotivo] = useState("");
  const [ficha, setFicha] = useState<ElectorFicha | null>(null);
  const [buscando, setBuscando] = useState(false);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [resultado, setResultado] = useState<ResultadoGuardado | null>(null);

  /* Cerrar con Escape (misma convención que los otros modales). */
  useEffect(() => {
    const cerrar = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", cerrar);
    return () => window.removeEventListener("keydown", cerrar);
  }, [onClose]);

  /* Ficha de la mesa (local, distrito, padrón actual, estado) mientras
     se escribe el número: es la misma consulta ONPE por mesa. */
  useEffect(() => {
    const m = mesa.trim();
    if (!/^\d{6}$/.test(m)) {
      setFicha(null);
      setError(null);
      return;
    }
    let vigente = true;
    setBuscando(true);
    setError(null);
    api
      .electorBuscar({ mesa: m })
      .then((f) => {
        if (vigente) setFicha(f);
      })
      .catch((e) => {
        if (!vigente) return;
        setFicha(null);
        setError(
          e instanceof Error && e.message.includes("padrón")
            ? `La mesa ${m} no está en el padrón.`
            : e instanceof Error ? e.message : String(e)
        );
      })
      .finally(() => {
        if (vigente) setBuscando(false);
      });
    return () => {
      vigente = false;
    };
  }, [mesa]);

  const guardar = async () => {
    const n = Number(habiles);
    if (!/^\d{6}$/.test(mesa.trim()) || !Number.isFinite(n) || n <= 0) return;
    setGuardando(true);
    setError(null);
    try {
      const res = await api.digitadorPadronMesa({
        numero_mesa: mesa.trim(),
        electores_habiles: n,
        ...(motivo.trim() ? { motivo: motivo.trim() } : {}),
      });
      setResultado({
        id: res.mesa.id,
        numero_mesa: res.mesa.numero_mesa,
        electores_habiles: res.mesa.electores_habiles,
        eliminados: res.eliminados,
      });
      onGuardado();
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setGuardando(false);
    }
  };

  const mesaValida = /^\d{6}$/.test(mesa.trim());
  const habilesValidos = /^\d+$/.test(habiles.trim()) && Number(habiles) > 0;
  const puedeGuardar = mesaValida && habilesValidos && !guardando && !buscando;

  return (
    <div
      className="fixed inset-0 z-[70] flex items-start justify-center overflow-y-auto bg-black/50 p-4 sm:items-center"
      onClick={onClose}
    >
      <div
        className="w-full max-w-lg rounded-2xl border border-slate-200 bg-white shadow-2xl"
        onClick={(e) => e.stopPropagation()}
      >
        {/* Cabecera */}
        <div className="flex items-center justify-between rounded-t-2xl bg-[#E02020] px-5 py-3.5">
          <h3 className="text-sm font-black uppercase tracking-wider text-white">
            Editar electores hábiles
          </h3>
          <button
            onClick={onClose}
            title="Cerrar"
            className="rounded-lg px-2 py-1 text-lg font-black text-white/90 hover:bg-white/20"
          >
            ✕
          </button>
        </div>

        {resultado ? (
          /* -------- Confirmación del resultado -------- */
          <div className="space-y-4 p-5">
            <Alerta tono="exito">
              Mesa {resultado.numero_mesa} actualizada: {num(resultado.electores_habiles)}{" "}
              electores hábiles. Vuelve a estar <b>PENDIENTE</b>.
            </Alerta>
            <div className="rounded-xl border border-slate-200 bg-slate-50 p-4 font-mono text-xs text-slate-600">
              <p>
                id de la mesa: <b className="text-[#E02020]">{resultado.id}</b> (buscado por
                N° de mesa {resultado.numero_mesa})
              </p>
              <p className="mt-1">
                records eliminados: <b>{resultado.eliminados.records}</b> · acta_metadata
                eliminados: <b>{resultado.eliminados.acta_metadata}</b>
              </p>
            </div>
            <div className="flex justify-end">
              <Boton onClick={onClose} variante="primario">Cerrar</Boton>
            </div>
          </div>
        ) : (
          /* -------- Formulario de edición -------- */
          <div className="space-y-4 p-5">
            <Campo etiqueta="N° de mesa" ayuda="6 dígitos. El id se busca automáticamente en `tables`.">
              <Input
                value={mesa}
                onChange={(e) => setMesa(e.target.value.replace(/\D/g, "").slice(0, 6))}
                placeholder="006528"
                inputMode="numeric"
                className="font-mono"
              />
            </Campo>

            {/* Ficha actual de la mesa */}
            {buscando && (
              <p className="text-xs font-semibold text-slate-400">Buscando mesa…</p>
            )}
            {ficha && (
              <div className="rounded-xl border border-slate-200 bg-slate-50 p-3 text-xs text-slate-600">
                <p className="font-black text-slate-800">{ficha.local.nombre}</p>
                <p className="mt-0.5">
                  {ficha.distrito} · {ficha.provincia} · ubigeo {ficha.ubigeo}
                </p>
                <p className="mt-1">
                  Padrón actual:{" "}
                  <b className="text-[#E02020]">{num(ficha.electoresHabiles)}</b> electores
                  hábiles · estado del acta: <b>{ficha.estadoActa}</b>
                </p>
              </div>
            )}

            <Campo
              etiqueta="Nueva cantidad de electores hábiles"
              ayuda="Sustituye a tables.electores_habiles (tope de la regla R2)."
            >
              <Input
                value={habiles}
                onChange={(e) => setHabiles(e.target.value.replace(/\D/g, "").slice(0, 6))}
                placeholder="300"
                inputMode="numeric"
                className="font-mono"
              />
            </Campo>

            <Campo etiqueta="Motivo (opcional)" ayuda="Queda en la huella de auditoría del acta.">
              <Input
                value={motivo}
                onChange={(e) => setMotivo(e.target.value.slice(0, 500))}
                placeholder="p. ej. corrección del padrón ONPE"
              />
            </Campo>

            <Alerta tono="aviso">
              Al guardar, la mesa queda <b>PENDIENTE</b> y se <b>eliminan</b> sus votos
              (records) y metadatos del acta (acta_metadata). Operación registrada en
              auditoría.
            </Alerta>

            {error && <Alerta tono="error">{error}</Alerta>}

            <div className="flex justify-end gap-2 pt-1">
              <Boton onClick={onClose} variante="suave">Cancelar</Boton>
              <Boton onClick={() => void guardar()} variante="peligro" deshabilitado={!puedeGuardar}>
                {guardando ? "Guardando…" : "Guardar y reiniciar mesa"}
              </Boton>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}
