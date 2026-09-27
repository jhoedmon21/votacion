import { useEffect, useRef, useState } from "react";
import { Boton } from "./ui";

/* ==================================================================== *
 *  Modales emergentes CENTRADOS para la prevención de errores del
 *  digitador (Módulo de Digitación de Actas).
 *
 *  Especificación UX:
 *   - fixed inset-0 + overlay semitransparente con desenfoque (backdrop
 *     blurred): bloquea la interacción con el formulario hasta responder.
 *   - Ventana CENTRADA en pantalla (flex items-center justify-center,
 *     z-index elevado), NUNCA un banner superior/inferior.
 *   - Codificación de color por estado:
 *       ÁMBAR luminoso  → advertencia (requiere confirmación manual).
 *       ROJO intenso    → bloqueo automático (no se puede guardar).
 *   - Accesibilidad: role=dialog + aria-modal, foco inicial en el control
 *     crítico (checkbox / botón), Escape = opción segura.
 * ==================================================================== */

interface ModalCentradoProps {
  tono: "ambar" | "rojo";
  icono: string;
  titulo: string;
  children: React.ReactNode;
  /** Al cerrar por Escape (opción segura: no confirma nada). */
  onSeguro: () => void;
}

function ModalCentrado({ tono, icono, titulo, children, onSeguro }: ModalCentradoProps) {
  const refTitulo = useRef<HTMLHeadingElement>(null);

  useEffect(() => {
    refTitulo.current?.focus();
    const cerrar = (e: KeyboardEvent) => {
      if (e.key === "Escape") onSeguro();
    };
    window.addEventListener("keydown", cerrar);
    return () => window.removeEventListener("keydown", cerrar);
  }, [onSeguro]);

  const marco = tono === "ambar"
    ? "border-4 border-amber-400 shadow-[0_0_60px_rgba(251,191,36,0.45)]"
    : "border-4 border-red-500 shadow-[0_0_60px_rgba(239,68,68,0.5)]";
  const cabecera = tono === "ambar"
    ? "bg-gradient-to-b from-amber-100 to-amber-50 text-amber-900"
    : "bg-gradient-to-b from-red-100 to-red-50 text-red-800";

  return (
    <div
      className="fixed inset-0 z-[70] flex items-center justify-center p-4"
      role="dialog"
      aria-modal="true"
      aria-label={titulo}
    >
      {/* Overlay: bloquea la interacción con el formulario de fondo */}
      <div
        className="absolute inset-0 bg-slate-950/60 backdrop-blur-sm"
        aria-hidden="true"
      />
      <div className={`relative w-full max-w-lg overflow-hidden rounded-3xl bg-white ${marco}`}>
        <div className={`flex items-center gap-3 px-6 py-4 ${cabecera}`}>
          <span className="text-3xl leading-none" aria-hidden="true">{icono}</span>
          <h3
            ref={refTitulo}
            tabIndex={-1}
            className="text-base font-black uppercase leading-tight tracking-wide outline-none"
          >
            {titulo}
          </h3>
        </div>
        <div className="px-6 py-5">{children}</div>
      </div>
    </div>
  );
}

/* ==================================================================== *
 *  MODAL 1 — ADVERTENCIA: VOTOS INUSUALES / CONCENTRACIÓN ALTA (R6)
 *
 *  Una organización concentra >90% de los votos válidos de la columna.
 *  Requiere casilla obligatoria "Validado manualmente con acta física";
 *  el botón primario permanece deshabilitado hasta marcarla.
 * ==================================================================== */
interface ModalVotosInusualesProps {
  /** Mensaje del backend: "VOTOS INUSUALES: [org] concentra [X] de [Y] ... ([P.1]%)". */
  mensaje: string;
  /** Enviando en curso (evita doble confirmación). */
  confirmando?: boolean;
  /** Botón primario: confirmar con la casilla marcada. */
  onConfirmar: () => void;
  /** Botón secundario: cerrar y enfocar la casilla del candidato líder. */
  onRevisar: () => void;
}

export function ModalVotosInusuales({
  mensaje, confirmando = false, onConfirmar, onRevisar,
}: ModalVotosInusualesProps) {
  const refCheck = useRef<HTMLInputElement>(null);
  /* Estado de la casilla: el botón primario permanece BLOQUEADO hasta que
     el digitador marque la validación manual contra el acta física. */
  const [confirmado, setConfirmado] = useState(false);
  useEffect(() => { refCheck.current?.focus(); }, []);

  return (
    <ModalCentrado
      tono="ambar"
      icono="⚠️"
      titulo="Advertencia: patrón de votación inusual"
      onSeguro={onRevisar}
    >
      <p className="rounded-xl bg-amber-50 px-4 py-3 text-sm font-bold leading-relaxed text-amber-900 ring-1 ring-amber-200">
        {mensaje}
      </p>

      <label className="mt-5 flex cursor-pointer items-start gap-3 rounded-xl border-2 border-amber-300 bg-white px-4 py-3 transition hover:bg-amber-50">
        <input
          ref={refCheck}
          type="checkbox"
          checked={confirmado}
          onChange={(e) => setConfirmado(e.target.checked)}
          className="mt-0.5 h-5 w-5 accent-amber-600"
        />
        <span className="text-sm font-bold text-amber-900">
          Validado manualmente con acta física: los números coinciden con el papel.
        </span>
      </label>

      <div className="mt-5 flex flex-col gap-2 sm:flex-row sm:justify-end">
        <Boton
          variante="borde"
          onClick={onRevisar}
        >
          Revisar digitación
        </Boton>
        <Boton
          variante="primario"
          deshabilitado={!confirmado || confirmando}
          clase={confirmando ? "opacity-60" : ""}
          onClick={onConfirmar}
        >
          {confirmando ? "Confirmando…" : "Confirmar y registrar"}
        </Boton>
      </div>
    </ModalCentrado>
  );
}

/* ==================================================================== *
 *  MODAL 2 — BLOQUEO: ACTA VACÍA (TODO EN CEROS) (R0)
 *
 *  El guardado está bloqueado: 0 = 0 cuadra, pero nadie digitó el papel.
 *  Botón único que cierra y enfoca la primera casilla de votación.
 * ==================================================================== */
interface ModalActaVaciaProps {
  /** Botón único: cerrar el modal y enfocar la primera casilla. */
  onVolverADigitar: () => void;
}

export function ModalActaVacia({ onVolverADigitar }: ModalActaVaciaProps) {
  const refBoton = useRef<HTMLButtonElement>(null);
  useEffect(() => { refBoton.current?.focus(); }, []);

  return (
    <ModalCentrado
      tono="rojo"
      icono="🚫"
      titulo="Registro bloqueado: acta vacía"
      onSeguro={onVolverADigitar}
    >
      {/* Icono de bloqueo centrado en la parte superior del cuerpo */}
      <div className="flex justify-center">
        <span
          className="flex h-16 w-16 items-center justify-center rounded-full bg-red-100 text-4xl ring-4 ring-red-200"
          aria-hidden="true"
        >
          🔒
        </span>
      </div>

      <p className="mt-4 text-center text-sm font-bold leading-relaxed text-red-800">
        No se registró ningún voto (todo en ceros). Verifique contra el acta
        física y digite los totales reales: el guardado está bloqueado.
      </p>

      <div className="mt-5 flex justify-center">
        <button
          ref={refBoton}
          type="button"
          onClick={onVolverADigitar}
          className="min-h-[48px] rounded-xl bg-red-600 px-8 text-sm font-black uppercase tracking-wider text-white shadow-lg transition hover:bg-red-700 active:scale-[0.98]"
        >
          Entendido / Volver a digitar
        </button>
      </div>
    </ModalCentrado>
  );
}
