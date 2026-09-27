import { useCallback, useEffect, useRef, useState } from "react";
import type { ActaRecord, RankingEntry, CandidateVotes } from "../../types";
import { api } from "../../api";
import { ModalVotosInusuales, ModalActaVacia } from "../ModalesDigitacion";
import { Boton, Input, Card, Alerta } from "../ui";

interface SideBySideDigitizationProps {
  acta: ActaRecord | null;
  onClose: () => void;
  onSave: (updatedActa: ActaRecord) => void;
  mode?: "edit" | "validate" | "view";
  readonly?: boolean;
}

export default function SideBySideDigitization(props: SideBySideDigitizationProps) {
  if (!props.acta) return null;
  return <SideBySideDigitizationInner {...props} acta={props.acta} />;
}

/* Los hooks viven en el componente interno: antes corrían después de un
   `return null` condicional, lo que viola las reglas de los hooks. */
function SideBySideDigitizationInner({
  acta,
  onClose,
  onSave,
  mode = "edit",
  readonly = false,
}: SideBySideDigitizationProps & { acta: ActaRecord }) {
  const [formData, setFormData] = useState({
    total_electores: acta.total_electores,
    /* Votantes que sufragaron (cabecera del acta): contra esta cifra cuadra
       la suma, no contra los electores hábiles. */
    total_votantes: (acta as unknown as { total_votantes?: number | null }).total_votantes ?? 0,
    votos_distrital: acta.votos_distrital.map((c) => ({
      candidate_id: c.candidate_id,
      votes: c.votes,
    })),
    votos_provincial: acta.votos_provincial.map((c) => ({
      candidate_id: c.candidate_id,
      votes: c.votes,
    })),
    votos_consejero: (acta.votos_consejero ?? []).map((c) => ({
      candidate_id: c.candidate_id,
      votes: c.votes,
    })),
    votos_regional: acta.votos_regional.map((c) => ({
      candidate_id: c.candidate_id,
      votes: c.votes,
    })),
    votos_blancos: acta.votos_blancos,
    votos_nulos: acta.votos_nulos,
    votos_impugnados: acta.votos_impugnados,
    /* Pie POR COLUMNA (norma ONPE): cada nivel lleva sus propios
       blancos/nulos/impugnados y cuadra independientemente. */
    blancos_distrital: (acta as any).blancos_distrital ?? 0,
    nulos_distrital: (acta as any).nulos_distrital ?? 0,
    impugnados_distrital: (acta as any).impugnados_distrital ?? 0,
    blancos_provincial: (acta as any).blancos_provincial ?? 0,
    nulos_provincial: (acta as any).nulos_provincial ?? 0,
    impugnados_provincial: (acta as any).impugnados_provincial ?? 0,
    blancos_consejero: (acta as any).blancos_consejero ?? 0,
    nulos_consejero: (acta as any).nulos_consejero ?? 0,
    impugnados_consejero: (acta as any).impugnados_consejero ?? 0,
    blancos_regional: (acta as any).blancos_regional ?? 0,
    nulos_regional: (acta as any).nulos_regional ?? 0,
    impugnados_regional: (acta as any).impugnados_regional ?? 0,
  });

  const [errors, setErrors] = useState<{
    total_electores?: string;
    votes_sum?: string;
  }>({});
  const [isSaving, setIsSaving] = useState(false);
  const [saveMessage, setSaveMessage] = useState<string | null>(null);
  const [autoSaveStatus, setAutoSaveStatus] = useState<"idle" | "saving" | "saved" | "error">("idle");
  const [lastAutoSave, setLastAutoSave] = useState<Date | null>(null);

  const imageRef = useRef<HTMLDivElement>(null);
  const [zoomLevel, setZoomLevel] = useState(1);
  const [rotation, setRotation] = useState(0);
  const [fitMode, setFitMode] = useState<"contain" | "width" | "height">("contain");
  const [isFullscreen, setIsFullscreen] = useState(false);
  const [activeField, setActiveField] = useState<string | null>(null);
  /* Foto del acta: permite CAMBIAR la imagen (o cargarla si el acta se guardó
     sin ella) desde la propia edición. Se sube a /v1/actas/foto y queda
     persistida al Guardar Cambios. */
  const [imageUrl, setImageUrl] = useState<string>(acta.image_url ?? "");
  const [subiendoFoto, setSubiendoFoto] = useState(false);
  /* Métricas WebP de la última imagen subida (para las estadísticas de
     almacenamiento; se persisten junto al acta al Guardar Cambios). */
  const [fotoPesos, setFotoPesos] = useState<{ original: number | null; final: number | null }>({ original: null, final: null });
  /* R6 — Advertencia de concentración atípica (>90% de la columna en una
     organización): exige reconfirmar contra el acta física. El servidor
     responde 409 requiere_confirmacion y aquí se muestra el modal. */
  const [avisoAtipico, setAvisoAtipico] = useState<string | null>(null);
  /* Lectura inicial (snapshot al abrir el editor): permite resaltar los
     campos que el digitador modificó respecto a la digitación previa/OCR. */
  const valoresIniciales = useRef(formData);
  /* Motivo/justificación de la modificación: obligatorio si el acta está
     observada (lo valida también el backend). Queda en la auditoría. */
  const [motivoEdicion, setMotivoEdicion] = useState("");
  /* Toast de error de guardado (red/servidor): se cierra solo; el
     formulario conserva TODO lo digitado para reintentar. */
  const [errorToast, setErrorToast] = useState(false);
  useEffect(() => {
    if (!errorToast) return;
    const t = setTimeout(() => setErrorToast(false), 6000);
    return () => clearTimeout(t);
  }, [errorToast]);
  const [confirmacionActaFisica, setConfirmacionActaFisica] = useState(false);
  /* R0 — Bloqueo por acta vacía (todo en ceros): modal rojo centrado, igual
     que en el registro (FormularioActaElectoral). */
  const [bloqueoVacia, setBloqueoVacia] = useState(false);

  const validateForm = useCallback(() => {
    const districtSum = formData.votos_distrital.reduce((sum, c) => sum + c.votes, 0);
    const regionalSum = formData.votos_regional.reduce((sum, c) => sum + c.votes, 0);
    const provincialSum = formData.votos_provincial.reduce((sum, c) => sum + c.votes, 0);
    const consejeroSum = formData.votos_consejero.reduce((sum, c) => sum + c.votes, 0);
    /* Regla ONPE POR COLUMNA: cada nivel tiene su PROPIO pie (blancos,
       nulos, impugnados) y cuadra independientemente con los votantes de
       la cabecera. Una columna activa es válida si
       votos_validos + b/n/i == votantes. */
    const columnas: Array<[string, number, number]> = [
      ["Distrital", districtSum,
        formData.blancos_distrital + formData.nulos_distrital + formData.impugnados_distrital],
      ["Provincial", provincialSum,
        formData.blancos_provincial + formData.nulos_provincial + formData.impugnados_provincial],
      ["Consejeros", consejeroSum,
        formData.blancos_consejero + formData.nulos_consejero + formData.impugnados_consejero],
      ["Regional", regionalSum,
        formData.blancos_regional + formData.nulos_regional + formData.impugnados_regional],
    ];
    const activas = columnas.filter(([, v, o]) => v + o > 0);
    const hayDatos = activas.length > 0 || formData.total_votantes > 0;
    const sumaTotal = activas.reduce((s, [, v, o]) => s + v + o, 0);

    const newErrors: { total_electores?: string; votes_sum?: string } = {};

    if (formData.total_electores < 0) {
      newErrors.total_electores = "El número de electores no puede ser negativo";
    }

    // R2 (imposible): más votantes que electores hábiles bloquea.
    if (
      formData.total_electores > 0 &&
      formData.total_votantes > formData.total_electores
    ) {
      newErrors.votes_sum = `Los votantes (${formData.total_votantes}) no pueden superar los electores hábiles (${formData.total_electores})`;
    } else if (!hayDatos) {
      // R0 (acta vacía) BLOQUEA: todo en ceros no es un acta digitada.
      newErrors.votes_sum = "ACTA VACÍA: no se registró ningún voto (todo en ceros). Verifique contra el acta física y digite los totales reales antes de guardar.";
    } else if (formData.total_votantes > 0) {
      // IMPOSIBLE por columna: ningún nivel puede superar a los votantes.
      const imposibles = activas.filter(([, v, o]) => v + o > formData.total_votantes);
      if (imposibles.length) {
        newErrors.votes_sum = `IMPOSIBLE: ${imposibles.map(([n, v, o]) => `${n} (${(v + o).toLocaleString()})`).join(", ")} supera(n) los votantes que sufragaron (${formData.total_votantes.toLocaleString()}). Corrige esos números o el total de votantes.`;
      } else {
        // R1: cada columna activa debe cuadrar con los votantes.
        const mal = activas.filter(([, v, o]) => v + o !== formData.total_votantes);
        if (mal.length) {
          newErrors.votes_sum = `NO COINCIDEN LOS DATOS: ${mal.map(([n, v, o]) => `${n} suma ${(v + o).toLocaleString()}`).join(", ")} y los votantes son ${formData.total_votantes.toLocaleString()}. Cada columna (con sus blancos/nulos/impugnados) debe cuadrar con el total de votantes.`;
        }
      }
    }

    setErrors(newErrors);
    // Cualquier error de integridad (electores, cuadre) impide guardar.
    return !newErrors.total_electores && !newErrors.votes_sum;
  }, [formData]);

  useEffect(() => {
    validateForm();
  }, [validateForm]);

  const handleInputChange = (field: keyof typeof formData, value: any) => {
    setFormData(prev => ({ ...prev, [field]: value }));
  };

  /* ---- Helpers de digitación rápida y segura ----
     1) parseEntero: sólo enteros positivos — bloquea letras, decimales,
        negativos y espacios (el backend además valida ge=0 con Pydantic).
     2) enfocarSiguiente: Enter avanza a la próxima casilla numérica (Tab
        ya funciona nativamente) para corrección rápida por teclado.
     3) claseCampo: resalta en ámbar los campos modificados respecto a la
        lectura inicial del editor (digitación previa/OCR). */
  const parseEntero = (v: string): number => {
    const digitos = v.replace(/[^0-9]/g, "");
    return digitos === "" ? 0 : parseInt(digitos.slice(0, 6), 10);
  };

  const enfocarSiguiente = (e: React.KeyboardEvent<HTMLInputElement>) => {
    if (e.key !== "Enter") return;
    e.preventDefault();
    const casillas = [...document.querySelectorAll<HTMLInputElement>(
      'input[inputmode="numeric"]:not(:disabled)')];
    const i = casillas.indexOf(e.currentTarget);
    casillas[i + 1]?.focus();
    casillas[i + 1]?.select();
  };

  const claseCampo = (modificado: boolean, error: boolean = false) =>
    error ? "border-red-500" : modificado ? "ring-2 ring-amber-400 border-amber-400" : "";

  const handleCandidateVoteChange = (type: 'distrital' | 'provincial' | 'regional', index: number, votes: number) => {
    setFormData(prev => {
      const newData = { ...prev };
      const key = `votos_${type}` as keyof typeof newData;
      newData[key] = [...prev[key]];
      newData[key][index] = { ...prev[key][index], votes };
      return newData;
    });
  };

  const handleAutoSave = useCallback(async () => {
    if (readonly || mode === "view") return;
    // R5: sin foto del acta el PUT la rechaza; el autoguardado no martilla:
    // se detiene hasta que el usuario suba la imagen (el botón Guardar
    // sí intenta y muestra el mensaje del servidor si falta).
    if (!imageUrl && !acta.image_url) {
      setAutoSaveStatus("idle");
      return;
    }
    // R0/R7: el autoguardado no persiste estados no guardables. Con la
    // cabecera en 0 nada lo es (acta vacía si todo es cero; incoherente si
    // quedan votos colgados): se detiene hasta que el digitador complete la
    // cabecera y use Guardar Cambios.
    if (formData.total_votantes === 0) {
      setAutoSaveStatus("idle");
      return;
    }
    setAutoSaveStatus("saving");
    try {
      const payload = {
        votos_distrital: formData.votos_distrital,
        votos_provincial: formData.votos_provincial,
        votos_regional: formData.votos_regional,
        votos_blancos: formData.votos_blancos,
        votos_nulos: formData.votos_nulos,
        votos_impugnados: formData.votos_impugnados,
        total_electores: formData.total_electores,
        total_votantes: formData.total_votantes,
        // Pie por columna (norma ONPE): sin esto el PUT parcial del
        // backend entendería que no vienen y conservaría los previos,
        // y el resumen validaría con ceros viejos.
        blancos_distrital: formData.blancos_distrital,
        nulos_distrital: formData.nulos_distrital,
        impugnados_distrital: formData.impugnados_distrital,
        blancos_provincial: formData.blancos_provincial,
        nulos_provincial: formData.nulos_provincial,
        impugnados_provincial: formData.impugnados_provincial,
        blancos_consejero: formData.blancos_consejero,
        nulos_consejero: formData.nulos_consejero,
        impugnados_consejero: formData.impugnados_consejero,
        blancos_regional: formData.blancos_regional,
        nulos_regional: formData.nulos_regional,
        impugnados_regional: formData.impugnados_regional,
        image_url: imageUrl || undefined,
        image_peso_original_kb: fotoPesos.original ?? undefined,
        image_peso_final_kb: fotoPesos.final ?? undefined,
        verified: false,
        motivo: motivoEdicion.trim() || undefined,
      };
      await api.updateActa(acta.id, payload);
      setAutoSaveStatus("saved");
      setLastAutoSave(new Date());
      setTimeout(() => setAutoSaveStatus("idle"), 3000);
    } catch (e) {
      setAutoSaveStatus("error");
      console.error("Auto-save failed:", e);
    }
  }, [acta.id, formData, readonly, mode]);

  useEffect(() => {
    if (readonly || mode === "view") return;
    const timer = setTimeout(handleAutoSave, 5000);
    return () => clearTimeout(timer);
  }, [formData, handleAutoSave, readonly, mode]);

  const handleSave = async () => {
    /* R0 — acta vacía: el cliente bloquea el guardado (validateForm), así que
       se detecta aquí mismo y se muestra el modal rojo centrado en lugar del
       banner genérico (misma UX que el registro). */
    const piesCero = formData.blancos_distrital + formData.nulos_distrital + formData.impugnados_distrital
      + formData.blancos_provincial + formData.nulos_provincial + formData.impugnados_provincial
      + formData.blancos_consejero + formData.nulos_consejero + formData.impugnados_consejero
      + formData.blancos_regional + formData.nulos_regional + formData.impugnados_regional === 0;
    const actaVacia = formData.total_votantes === 0 && piesCero
      && formData.votos_distrital.every((c) => c.votes === 0)
      && formData.votos_provincial.every((c) => c.votes === 0)
      && formData.votos_consejero.every((c) => c.votes === 0)
      && formData.votos_regional.every((c) => c.votes === 0);
    if (actaVacia) {
      setBloqueoVacia(true);
      setSaveMessage(null);
      return;
    }
    if (!validateForm()) return;

    setIsSaving(true);
    setSaveMessage(null);

    try {
      const payload = {
        votos_distrital: formData.votos_distrital,
        votos_provincial: formData.votos_provincial,
        votos_regional: formData.votos_regional,
        votos_blancos: formData.votos_blancos,
        votos_nulos: formData.votos_nulos,
        votos_impugnados: formData.votos_impugnados,
        total_electores: formData.total_electores,
        total_votantes: formData.total_votantes,
        // Pie por columna (norma ONPE): sin esto el PUT parcial del
        // backend entendería que no vienen y conservaría los previos,
        // y el resumen validaría con ceros viejos.
        blancos_distrital: formData.blancos_distrital,
        nulos_distrital: formData.nulos_distrital,
        impugnados_distrital: formData.impugnados_distrital,
        blancos_provincial: formData.blancos_provincial,
        nulos_provincial: formData.nulos_provincial,
        impugnados_provincial: formData.impugnados_provincial,
        blancos_consejero: formData.blancos_consejero,
        nulos_consejero: formData.nulos_consejero,
        impugnados_consejero: formData.impugnados_consejero,
        blancos_regional: formData.blancos_regional,
        nulos_regional: formData.nulos_regional,
        impugnados_regional: formData.impugnados_regional,
        image_url: imageUrl || undefined,
        image_peso_original_kb: fotoPesos.original ?? undefined,
        image_peso_final_kb: fotoPesos.final ?? undefined,
        verified: mode === "validate",
        confirmado_atipico: confirmacionActaFisica,
        motivo: motivoEdicion.trim() || undefined,
      };

      const updatedActa = await api.updateActa(acta.id, payload);

      const recordActa: ActaRecord = {
        id: updatedActa.id,
        numero_mesa: updatedActa.numero_mesa,
        status: updatedActa.status,
        requires_review: updatedActa.requires_review,
        ocr_confidence: updatedActa.ocr_confidence ?? 0,
        image_url: updatedActa.image_url ?? "",
        venue_id: updatedActa.venue_id ?? 0,
        venue_name: updatedActa.venue_name ?? "",
        sector: updatedActa.sector ?? "",
        latitude: updatedActa.latitude ?? 0,
        longitude: updatedActa.longitude ?? 0,
        votos_distrital: updatedActa.votos_distrital,
        votos_provincial: updatedActa.votos_provincial,
        votos_regional: updatedActa.votos_regional,
        votos_blancos: updatedActa.votos_blancos,
        votos_nulos: updatedActa.votos_nulos,
        votos_impugnados: updatedActa.votos_impugnados,
        total_electores: updatedActa.total_electores,
      };

      setSaveMessage("Acta guardada correctamente");
      setAvisoAtipico(null);
      setConfirmacionActaFisica(false);
      onSave(recordActa);
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      if (msg.includes("VOTOS INUSUALES")) {
        // R6: advertencia con doble confirmación (checkbox del acta física).
        setAvisoAtipico(msg);
        setSaveMessage(null);
      } else if (msg.includes("todo en ceros")) {
        // R0: acta vacía — bloqueo con modal rojo centrado (el backend
        // responde 409 con "ACTA VACÍA: ... todo en ceros ..." y errorMessage
        // lo aplana a un solo string).
        setBloqueoVacia(true);
        setSaveMessage(null);
      } else if (msg.includes("cabecera declara 0 votantes")) {
        // R7: cabecera en ceros con votos colgados — enfoca la cabecera
        // (la pestaña con la cabecera usa aria-label "Votantes que sufragaron").
        setSaveMessage(`Error: ${msg}`);
        document.querySelector<HTMLInputElement>(
          'input[aria-label="Votantes que sufragaron"]'
        )?.focus();
      } else {
        // Error de red/servidor: notificación clara SIN perder lo digitado
        // (el formulario no se toca; el usuario reintenta con Guardar).
        setSaveMessage(`Error: ${msg || "Error al guardar el acta. Intente nuevamente."}`);
        setErrorToast(true);
      }
    } finally {
      setIsSaving(false);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    // Con un modal centrado abierto (R6/R0), Escape le pertenece al modal.
    if (e.key === "Escape" && !avisoAtipico && !bloqueoVacia) onClose();
    if (e.ctrlKey && e.key === "s") {
      e.preventDefault();
      handleSave();
    }
  };

  useEffect(() => {
    window.addEventListener("keydown", handleKeyDown as EventListener);
    return () => window.removeEventListener("keydown", handleKeyDown as EventListener);
  }, [onClose, handleSave]);

  const districtSum = formData.votos_distrital.reduce((sum, c) => sum + c.votes, 0);
  const provincialSum = formData.votos_provincial.reduce((sum, c) => sum + c.votes, 0);
  const regionalSum = formData.votos_regional.reduce((sum, c) => sum + c.votes, 0);
  const consejeroSum = formData.votos_consejero.reduce((sum, c) => sum + c.votes, 0);
  /* Resumen POR COLUMNA (regla ONPE): cada nivel del acta debe cuadrar
     independientemente con los votantes que sufragaron — los mismos 200
     electores votan en la columna regional Y en la de consejeros, así que
     sumar ambos niveles (400 vs 200) es un falso descuadre. La
     participación se calcula con la columna mayor (la cabecera del papel). */
  /* Resumen POR COLUMNA con su propio pie (norma ONPE). */
  const columnasResumen: Array<{ nombre: string; votos: number; otros: number }> = [
    { nombre: "Distrital (Alcalde)", votos: districtSum,
      otros: formData.blancos_distrital + formData.nulos_distrital + formData.impugnados_distrital },
    { nombre: "Provincial (Alcalde)", votos: provincialSum,
      otros: formData.blancos_provincial + formData.nulos_provincial + formData.impugnados_provincial },
    { nombre: "Consejeros Regionales", votos: consejeroSum,
      otros: formData.blancos_consejero + formData.nulos_consejero + formData.impugnados_consejero },
    { nombre: "Regional (Gobernador)", votos: regionalSum,
      otros: formData.blancos_regional + formData.nulos_regional + formData.impugnados_regional },
  ].filter((c) => c.votos + c.otros > 0);
  const totalVotes = columnasResumen.length
    ? Math.max(...columnasResumen.map((c) => c.votos + c.otros))
    : 0;
  const participationRate = formData.total_electores > 0 ? (totalVotes / formData.total_electores) * 100 : 0;
  const toggleFullscreen = () => {
    setIsFullscreen(!isFullscreen);
    if (!isFullscreen && imageRef.current) {
      imageRef.current.requestFullscreen();
    } else {
      document.exitFullscreen();
    }
  };

  /* Sube la nueva imagen del acta inmediatamente y guarda la URL local;
     se persiste en la mesa al presionar Guardar Cambios. */
  const handleFotoSeleccionada = async (file: File | undefined) => {
    if (!file) return;
    setSubiendoFoto(true);
    setSaveMessage(null);
    try {
      const r = await api.subirFotoActa(file);
      setImageUrl(r.url);
      setFotoPesos({ original: r.pesoOriginalKb, final: r.pesoFinalKb });
      setZoomLevel(1);
      setRotation(0);
      setSaveMessage(
        r.pesoFinalKb
          ? `Imagen optimizada: ${r.pesoOriginalKb} KB → ${r.pesoFinalKb} KB (WebP). Presiona Guardar Cambios.`
          : "Imagen cargada. Presiona Guardar Cambios para adjuntarla al acta."
      );
    } catch (e) {
      setSaveMessage(`Error al subir la imagen: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setSubiendoFoto(false);
    }
  };

  const renderVoteRow = (
    candidate: RankingEntry,
    type: 'distrital' | 'provincial' | 'regional',
    index: number
  ) => {
    const voteValue = formData[`votos_${type}`][index]?.votes ?? 0;
    return (
      <div key={candidate.candidate_id} className="border-t border-slate-100 py-3 flex items-center gap-3">
        <div className="w-6 text-right font-mono text-xs text-slate-400 shrink-0">
          {candidate.candidate_id}
        </div>
        {candidate.symbol && (
          <img src={candidate.symbol} alt="" className="h-7 w-7 shrink-0 rounded object-contain" />
        )}
        <div className="min-w-0 flex-1">
          <p className="truncate font-medium text-slate-800 text-sm">{candidate.name}</p>
          <p className="truncate text-xs text-slate-500">{candidate.party}</p>
        </div>
        {!readonly && (
          <Input
            type="number"
            min={0}
            value={voteValue}
            onChange={(e) => handleCandidateVoteChange(type, index, parseEntero(e.target.value))}
            onKeyDown={enfocarSiguiente}
            onFocus={() => setActiveField(`${type}_${index}`)}
            onBlur={() => setActiveField(null)}
            className={`w-24 text-right font-mono text-base ${claseCampo(
              voteValue !== ((valoresIniciales.current as unknown as Record<string, RankingEntry[] | undefined>)[`votos_${type}`]?.[index]?.votes ?? 0)
            )}`}
            inputMode="numeric"
            aria-label={`Votos ${candidate.name}`}
          />
        )}
        {readonly && (
          <div className="w-24 text-right font-mono text-base text-slate-700">
            {voteValue.toLocaleString()}
          </div>
        )}      </div>
    );
  };

  /* Filas de votos de CONSEJEROS: el índice va sobre votos_consejero (la
     oferta provincial de la mesa), no sobre las listas distritales. */
  const renderVoteRowConsejero = (candidate: RankingEntry, index: number) => {
    const voteValue = formData.votos_consejero[index]?.votes ?? 0;
    return (
      <div key={`consejero-${candidate.candidate_id}`} className="border-t border-slate-100 py-3 flex items-center gap-3">
        <div className="w-6 text-right font-mono text-xs text-slate-400 shrink-0">
          {candidate.candidate_id}
        </div>
        {candidate.symbol && (
          <img src={candidate.symbol} alt="" className="h-7 w-7 shrink-0 rounded object-contain" />
        )}
        <div className="min-w-0 flex-1">
          <p className="truncate font-medium text-slate-800 text-sm">{candidate.name}</p>
          <p className="truncate text-xs text-slate-500">{candidate.party}</p>
        </div>
        {!readonly ? (
          <Input
            type="number"
            min={0}
            value={voteValue}
            onChange={(e) => {
              const votes = parseEntero(e.target.value);
              setFormData((prev) => {
                const newData = { ...prev };
                newData.votos_consejero = [...prev.votos_consejero];
                newData.votos_consejero[index] = { ...prev.votos_consejero[index], votes };
                return newData;
              });
            }}
            onKeyDown={enfocarSiguiente}
            className={`w-24 text-right font-mono text-base ${claseCampo(
              voteValue !== (valoresIniciales.current.votos_consejero[index]?.votes ?? 0)
            )}`}
            inputMode="numeric"
            aria-label={`Votos consejero ${candidate.name}`}
          />
        ) : (
          <div className="w-24 text-right font-mono text-base text-slate-700">
            {voteValue.toLocaleString()}
          </div>
        )}
      </div>
    );
  };

  /* Pie POR COLUMNA (norma ONPE): cada nivel tiene sus propios blancos,
     nulos e impugnados. Se renderiza DENTRO de la tarjeta de cada nivel. */
  const renderPieNivel = (nivel: "distrital" | "provincial" | "consejero" | "regional") => [
    [`blancos_${nivel}`, "Votos en Blanco"],
    [`nulos_${nivel}`, "Votos Nulos"],
    [`impugnados_${nivel}`, "Impugnación de Identidad"],
  ].map(([field, label]) => (
    <div key={field} className="flex items-center gap-3">
      <label className="text-sm font-medium text-slate-700 w-48 shrink-0">{label}</label>
      {!readonly ? (
        <Input
          type="number"
          min={0}
          value={(formData as Record<string, number | undefined>)[field as string] ?? 0}
          onChange={(e) => handleInputChange(field as keyof typeof formData, parseEntero(e.target.value))}
          onKeyDown={enfocarSiguiente}
          onFocus={() => setActiveField(field as string)}
          onBlur={() => setActiveField(null)}
          className={`w-32 text-right font-mono text-base ${claseCampo(
            ((formData as Record<string, number | undefined>)[field as string] ?? 0)
            !== ((valoresIniciales.current as unknown as Record<string, number | undefined>)[field as string] ?? 0)
          )}`}
          inputMode="numeric"
        />
      ) : (
        <div className="w-32 text-right font-mono text-base text-slate-700">
          {((formData as Record<string, number | undefined>)[field as string] ?? 0).toLocaleString()}
        </div>
      )}
    </div>
  ));

  const getStatusBadge = (status: string) => {
    const badges: Record<string, string> = {
      PENDIENTE: "bg-slate-100 text-slate-700",
      EN_DIGITACION: "bg-red-100 text-red-800",
      DIGITADA: "bg-indigo-100 text-indigo-800",
      EN_REVISION: "bg-yellow-100 text-yellow-800",
      OBSERVADA: "bg-amber-100 text-amber-800",
      VALIDADA: "bg-emerald-100 text-emerald-800",
      CERRADA: "bg-slate-100 text-slate-700",
      processed: "bg-emerald-100 text-emerald-800",
      requires_review: "bg-yellow-100 text-yellow-800",
      pending: "bg-slate-100 text-slate-700",
    };
    return badges[status] || "bg-gray-100 text-gray-800";
  };

  const getStatusLabel = (status: string) => {
    const labels: Record<string, string> = {
      PENDIENTE: "Pendiente",
      EN_DIGITACION: "En Digitación",
      DIGITADA: "Digitada",
      EN_REVISION: "En Revisión",
      OBSERVADA: "Observada",
      VALIDADA: "Validada",
      CERRADA: "Cerrada",
      processed: "Procesada",
      requires_review: "En Revisión",
      pending: "Pendiente",
    };
    return labels[status] || status;
  };

  return (
    <div className="fixed inset-0 z-50 flex items-stretch justify-center bg-black/50 sm:items-center sm:p-4">
      {/* Responsivo: pantalla completa en móvil (imagen arriba, formulario
          debajo, scroll único) y modal lado-a-lado con scroll independiente
          por columna desde sm. En pantalla completa se expande del todo. */}
      <div
        className={`relative flex h-[100dvh] w-full flex-col overflow-hidden rounded-none bg-white shadow-2xl sm:mx-4 sm:h-[90vh] sm:w-[95vw] sm:max-w-[1400px] sm:rounded-xl ${
          isFullscreen ? "fixed inset-0 h-screen w-screen max-h-none max-w-none rounded-none" : ""
        }`}
      >
        <div className="flex shrink-0 flex-wrap items-center justify-between gap-2 p-3 sm:p-4 bg-slate-100 border-b">
          <div className="flex min-w-0 flex-wrap items-center gap-2 sm:gap-4">
            <h2 className="text-base font-bold leading-tight text-[#E02020] sm:text-xl">
              {mode === "validate" ? "Validar contra Acta" : mode === "view" ? "Ver Acta" : "Editar Acta"}
              <span className="ml-2 text-sm font-normal text-slate-600">Mesa {acta.numero_mesa}</span>
            </h2>
            <span className={`px-2.5 py-1 rounded-full text-xs font-bold ${getStatusBadge(acta.status)}`}>
              {getStatusLabel(acta.status)}
            </span>
            {autoSaveStatus !== "idle" && (
              <span className="hidden text-xs text-slate-500 items-center gap-1 sm:flex">
                {autoSaveStatus === "saving" && "⟳"}
                {autoSaveStatus === "saved" && "✓"}
                {autoSaveStatus === "error" && "✗"}
                {autoSaveStatus === "saved" && lastAutoSave && ` Guardado ${lastAutoSave.toLocaleTimeString()}`}
              </span>
            )}
          </div>
          <div className="flex shrink-0 items-center gap-2">
            {mode !== "view" && !readonly && (
              <Boton variante="exito" onClick={handleSave} deshabilitado={isSaving || !!errors.total_electores || !!errors.votes_sum} clase="px-3 py-1.5 text-xs sm:px-4 sm:py-2 sm:text-sm">
                {isSaving ? "Guardando..." : "Guardar Cambios"}
              </Boton>
            )}
            <button onClick={onClose} className="text-gray-500 hover:text-gray-700 p-2">
              ✕
            </button>
          </div>
        </div>

        <div className="flex min-h-0 flex-1 flex-col overflow-y-auto sm:flex-row sm:overflow-hidden">
          {/* LEFT PANEL: IMAGE VIEWER — altura fija en móvil, columna en desktop */}
          <div className="flex w-full shrink-0 flex-col border-b border-slate-200 bg-slate-50 sm:w-1/2 sm:border-b-0 sm:border-r">
            <div className="flex flex-wrap items-center justify-between gap-2 p-3 bg-white border-b border-slate-200">
              <h3 className="font-semibold text-slate-800">Documento Original</h3>
            <div className="flex flex-wrap items-center gap-2">
                <button
                  onClick={() => setZoomLevel(z => Math.min(z + 0.2, 4))}
                  className="px-2 py-1 bg-white border border-slate-300 rounded text-xs hover:bg-slate-50"
                  title="Zoom +"
                >
                  +
                </button>
                <button
                  onClick={() => setZoomLevel(z => Math.max(z - 0.2, 0.25))}
                  className="px-2 py-1 bg-white border border-slate-300 rounded text-xs hover:bg-slate-50"
                  title="Zoom -"
                >
                  −
                </button>
                <button
                  onClick={() => setRotation(r => (r + 90) % 360)}
                  className="px-2 py-1 bg-white border border-slate-300 rounded text-xs hover:bg-slate-50"
                  title="Rotar 90°"
                >
                  ⟳
                </button>
                <select
                  value={fitMode}
                  onChange={(e) => setFitMode(e.target.value as "contain" | "width" | "height")}
                  className="px-2 py-1 bg-white border border-slate-300 rounded text-xs"
                  title="Ajuste"
                >
                  <option value="contain">Ajustar a pantalla</option>
                  <option value="width">Ajustar ancho</option>
                  <option value="height">Ajustar alto</option>
                </select>
                <button
                  onClick={toggleFullscreen}
                  className="px-2 py-1 bg-white border border-slate-300 rounded text-xs hover:bg-slate-50"
                >
                  {isFullscreen ? "⛶ Salir" : "⛶ Pantalla completa"}
                </button>
                {imageUrl && (
                  <a
                    href={imageUrl}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="px-2 py-1 bg-white border border-slate-300 rounded text-xs hover:bg-slate-50"
                  >
                    ↓ Descargar
                  </a>
                )}
                {mode !== "view" && !readonly && (
                  <label
                    title={imageUrl ? "Cambiar la imagen del acta" : "Cargar imagen del acta"}
                    className={`cursor-pointer px-2 py-1 rounded text-xs font-bold border transition ${
                      subiendoFoto
                        ? "bg-slate-100 border-slate-200 text-slate-400"
                        : "bg-[#E02020] border-[#E02020] text-white hover:bg-[#A01010]"
                    }`}
                  >
                    {subiendoFoto ? "Subiendo…" : imageUrl ? "⟳ Cambiar imagen" : "⬆ Cargar imagen"}
                    <input type="file" accept="image/*" className="hidden"
                      disabled={subiendoFoto}
                      onChange={(e) => { void handleFotoSeleccionada(e.target.files?.[0]); e.currentTarget.value = ""; }}
                    />
                  </label>
                )}
              </div>
            </div>

            <div className="flex h-72 shrink-0 items-center justify-center relative overflow-auto p-4 sm:h-auto sm:flex-1 sm:shrink" ref={imageRef}>
              {imageUrl ? (
                <div
                  className="relative flex items-center justify-center"
                  style={{
                    transform: `scale(${zoomLevel}) rotate(${rotation}deg)`,
                    transformOrigin: "center center",
                    transition: "transform 0.15s ease",
                  }}
                >
                  <img
                    src={imageUrl}
                    alt={`Acta mesa ${acta.numero_mesa}`}
                    className={`max-w-full max-h-full object-${fitMode} shadow-lg`}
                    style={fitMode === "width" ? { width: "100%" } : fitMode === "height" ? { height: "100%" } : {}}
                  />
                </div>
              ) : (
                <div className="text-center text-slate-500 py-12">
                  <div className="text-6xl mb-2">📄</div>
                  <p className="text-lg">No hay imagen de acta disponible</p>
                  {mode !== "view" && !readonly ? (
                    <label className="mt-3 inline-flex cursor-pointer items-center gap-2 rounded-lg bg-[#E02020] px-4 py-2 text-sm font-bold text-white hover:bg-[#A01010]">
                      {subiendoFoto ? "Subiendo…" : "⬆ Cargar imagen del acta"}
                      <input type="file" accept="image/*" className="hidden"
                        disabled={subiendoFoto}
                        onChange={(e) => { void handleFotoSeleccionada(e.target.files?.[0]); e.currentTarget.value = ""; }}
                      />
                    </label>
                  ) : (
                    <p className="text-sm mt-1">El acta fue registrada sin imagen.</p>
                  )}
                </div>
              )}
            </div>

            <div className="p-3 bg-white border-t border-slate-200 text-xs text-slate-500">
              Zoom: {(zoomLevel * 100).toFixed(0)}% | Rotación: {rotation}° | Ajuste: {fitMode}
            </div>
          </div>

          {/* RIGHT PANEL: DIGITIZATION FORM. El SCROLL vive SIEMPRE en la
              columna del formulario (antes sólo en sm+): en pantallas chicas
              el modal corta el flujo y secciones como "Otros Votos", el
              resumen y el botón Guardar quedaban inalcanzables. */}
          <div className="flex w-full flex-col overflow-y-auto bg-white sm:w-1/2">
            <div className="p-4 border-b border-slate-200 sticky top-0 z-5 bg-white">
              <div className="flex items-center justify-between">
                <h3 className="font-semibold text-slate-800">Formulario de Digitación</h3>
                {mode === "validate" && (
                  <span className="px-2 py-1 bg-amber-100 text-amber-800 rounded text-xs font-bold">
                    Modo Validación Visual
                  </span>
                )}
              </div>
              <p className="text-xs text-slate-500 mt-1">
                {acta.venue_name} • {acta.sector} • Electores hábiles: {acta.total_electores?.toLocaleString() ?? "—"}
              </p>
            </div>

            {saveMessage && (
              <Alerta tono={saveMessage.startsWith("Error") ? "error" : "exito"} className="m-4">
                {saveMessage}
              </Alerta>
            )}

            {/* R6 — Advertencia de concentración atípica con doble confirmación */}
            {/* R6 — el modal centrado se renderiza al final del árbol */}

            <div className="p-4 space-y-6 flex-1">
              {/* METADATOS */}
              <Card className="p-4">
                <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                  <span className="w-6 h-6 rounded-full bg-[#E02020] text-white text-xs flex items-center justify-center">1</span>
                  Identificación del Acta
                </h4>
                <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
                  <div>
                    <label className="block text-xs font-bold text-slate-600 mb-1">N° de Mesa</label>
                    <Input
                      value={acta.numero_mesa}
                      disabled
                      className="bg-slate-50 font-mono text-lg tracking-widest"
                    />
                  </div>
                  <div>
                    <label className="block text-xs font-bold text-slate-600 mb-1">Electores Hábiles de la Mesa</label>
                    {!readonly ? (
                      <Input
                        type="number"
                        min={0}
                        value={formData.total_electores}
                        onChange={(e) => handleInputChange('total_electores', parseEntero(e.target.value))}
                        onKeyDown={enfocarSiguiente}
                        onFocus={() => setActiveField('total_electores')}
                        onBlur={() => setActiveField(null)}
                        className={errors.total_electores ? "border-red-500" : ""}
                        inputMode="numeric"
                      />
                    ) : (
                      <Input value={formData.total_electores.toLocaleString()} disabled className="bg-slate-50 font-mono text-lg" />
                    )}
                    {errors.total_electores && <p className="text-xs text-red-600 mt-1">{errors.total_electores}</p>}
                  </div>
                  <div className="sm:col-span-2">
                    <label className="block text-xs font-bold text-slate-600 mb-1">Votantes que Sufragaron (cabecera del acta)</label>
                    {!readonly ? (
                      <Input
                        type="number"
                        min={0}
                        value={formData.total_votantes}
                        onChange={(e) => handleInputChange('total_votantes', parseEntero(e.target.value))}
                        onKeyDown={enfocarSiguiente}
                        onFocus={() => setActiveField('total_votantes')}
                        onBlur={() => setActiveField(null)}
                        className={`w-full ${claseCampo(
                          formData.total_votantes !== (valoresIniciales.current.total_votantes ?? 0),
                          !!(errors.votes_sum && errors.votes_sum.includes("superar"))
                        )}`}
                        inputMode="numeric"
                        aria-label="Votantes que sufragaron"
                      />
                    ) : (
                      <Input value={formData.total_votantes.toLocaleString()} disabled className="bg-slate-50 font-mono text-lg" />
                    )}
                    <p className="text-[11px] text-slate-400 mt-0.5">
                      La suma de votos debe cuadrar contra esta cifra, no contra los electores hábiles. Si no cuadra, el acta se guarda OBSERVADA.
                    </p>
                  </div>
                </div>
              </Card>

              {/* VOTOS DISTRITALES (sólo si el distrito de la mesa tiene
                  candidatas cargadas; si no, la sección confundiría al
                  corrector con una lista vacía de ceros). */}
              {formData.votos_distrital.length > 0 && (
                <Card className="p-4">
                  <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                    <span className="w-6 h-6 rounded-full bg-[#10b981] text-white text-xs flex items-center justify-center">2</span>
                    Votos Distritales (Alcalde Distrital) — {districtSum.toLocaleString()} votos
                  </h4>
                  <div className="space-y-2 max-h-64 overflow-y-auto">
                    {acta.votos_distrital.map((c, i) => renderVoteRow(c, 'distrital', i))}
                  </div>
                  {/* Pie de la columna (norma ONPE): blancos/nulos/impugnados del nivel */}
                  <div className="mt-3 pt-3 border-t border-slate-200">
                    {renderPieNivel('distrital')}
                  </div>
                </Card>
              )}

              {/* VOTOS PROVINCIALES */}
              {formData.votos_provincial.length > 0 && (
                <Card className="p-4">
                  <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                    <span className="w-6 h-6 rounded-full bg-[#8b5cf6] text-white text-xs flex items-center justify-center">3</span>
                    Votos Provinciales (Alcalde Provincial) — {provincialSum.toLocaleString()} votos
                  </h4>
                  <div className="space-y-2 max-h-64 overflow-y-auto">
                    {acta.votos_provincial.map((c, i) => renderVoteRow(c, 'provincial', i))}
                  </div>
                  {/* Pie de la columna (norma ONPE) */}
                  <div className="mt-3 pt-3 border-t border-slate-200">
                    {renderPieNivel('provincial')}
                  </div>
                </Card>
              )}

              {/* VOTOS REGIONALES */}
              {formData.votos_regional.length > 0 && (
                <Card className="p-4">
                  <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                    <span className="w-6 h-6 rounded-full bg-[#f59e0b] text-white text-xs flex items-center justify-center">4</span>
                    Votos Regionales (Gobernador Regional) — {regionalSum.toLocaleString()} votos
                  </h4>
                  <div className="space-y-2 max-h-64 overflow-y-auto">
                    {acta.votos_regional.map((c, i) => renderVoteRow(c, 'regional', i))}
                  </div>
                  {/* Pie de la columna (norma ONPE) */}
                  <div className="mt-3 pt-3 border-t border-slate-200">
                    {renderPieNivel('regional')}
                  </div>
                </Card>
              )}

              {/* CONSEJEROS REGIONALES: columna CONSEJEROS del acta física,
                  elegidos POR PROVINCIA. Sólo se muestra si la mesa tiene
                  consejeros en carrera (oferta provincial del local). */}
              {formData.votos_consejero.length > 0 && (
                <Card className="p-4">
                  <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                    <span className="w-6 h-6 rounded-full bg-[#0ea5e9] text-white text-xs flex items-center justify-center">C</span>
                    Consejeros Regionales (por provincia) — {consejeroSum.toLocaleString()} votos
                  </h4>
                  <div className="space-y-2 max-h-64 overflow-y-auto">
                    {(acta.votos_consejero ?? []).map((c, i) => renderVoteRowConsejero(c, i))}
                  </div>
                  {/* Pie de la columna (norma ONPE) */}
                  <div className="mt-3 pt-3 border-t border-slate-200">
                    {renderPieNivel('consejero')}
                  </div>
                </Card>
              )}

              {/* NOTA: el pie (blancos/nulos/impugnados) de CADA columna se
                  digita dentro de la tarjeta de su nivel, según la norma ONPE. */}

              {/* RESUMEN DE VALIDACIÓN */}
              <Card className="p-4" variant={errors.votes_sum ? "error" : "outline"}>
                <h4 className="font-semibold text-slate-800 mb-3">Resumen de Validación</h4>
                {/* Regla ONPE: CADA columna del acta (distrital, provincial,
                    regional, consejeros) cuadra independientemente contra los
                    votantes que sufragaron — no se suman entre niveles. */}
                <div className="space-y-2 text-sm">
                  {columnasResumen.map((c) => (
                    <div key={c.nombre} className="flex justify-between">
                      <span className="text-slate-600">
                        {c.nombre}: {c.votos.toLocaleString()} + {c.otros.toLocaleString()} (B/N/I)
                      </span>
                      <span className={`font-mono font-bold ${c.votos + c.otros !== totalVotes ? "text-amber-600" : "text-emerald-700"}`}
                        title={c.votos + c.otros !== totalVotes ? "Esta columna no cuadra con las demás: verifíquela contra el papel" : "Columna cuadrada"}>
                        {(c.votos + c.otros).toLocaleString()}
                      </span>
                    </div>
                  ))}
                  <div className="flex justify-between border-t border-slate-200 pt-2 font-medium">
                    <span className="text-slate-800">Emitidos por columna (cada una = votantes):</span>
                    <span className="font-mono font-bold text-lg">{totalVotes.toLocaleString()}</span>
                  </div>
                  {errors.votes_sum && (
                    <div className="rounded border-2 border-red-300 bg-red-50 px-3 py-2 text-red-600 font-medium">
                      <p className="font-black uppercase tracking-wide">Mesa descuadrada</p>
                      <p className="mt-0.5 text-xs">{errors.votes_sum}</p>
                      {!readonly && mode === "edit" && (
                        <button
                          type="button"
                          onClick={async () => {
                            const bloqueoDuro = (errors.votes_sum ?? "").includes("ACTA VACÍA")
                              || (errors.votes_sum ?? "").includes("IMPOSIBLE");
                            if (bloqueoDuro) return;
                            setIsSaving(true);
                            try {
                              await api.updateActa(acta.id, {
                                forzar_revision: true,
                              });
                              setSaveMessage("Acta enviada a Revisión / Acta Observada para control de calidad.");
                              onSave({ ...acta, status: "requires_review", requires_review: true });
                            } catch (e) {
                              setSaveMessage(`Error: ${e instanceof Error ? e.message : String(e)}`);
                            } finally {
                              setIsSaving(false);
                            }
                          }}
                          className="mt-2 rounded-lg border border-red-300 bg-white px-3 py-1.5 text-xs font-black text-red-700 hover:bg-red-100"
                        >
                          Enviar a Revisión / Acta Observada →
                        </button>
                      )}
                    </div>
                  )}
                  {!errors.votes_sum && formData.total_electores > 0 && (
                    <div className="flex justify-between text-emerald-600 font-medium bg-emerald-50 px-3 py-2 rounded">
                      <span>✓ Estado:</span>
                      <span>Votos válidos - Cuadra correctamente</span>
                    </div>
                  )}
                  <div className="flex justify-between border-t border-slate-200 pt-2 mt-2">
                    <span className="text-slate-600">Participación:</span>
                    <span className="font-mono font-bold text-[#E02020]">{participationRate.toFixed(1)}%</span>
                  </div>
                </div>
              </Card>

              {/* ACTIONS */}
              {mode !== "view" && !readonly && (
                <div className="flex flex-col justify-end gap-3 pt-4 border-t border-slate-200 sm:flex-row">
                  {/* Motivo de la modificación: obligatorio si el acta está
                      observada (backend lo revalida y lo guarda en auditoría). */}
                  {acta.requires_review && (
                    <div className="w-full">
                      <label className="block text-xs font-bold text-slate-600 mb-1">
                        Motivo de la modificación <span className="text-red-600">*</span>
                        <span className="ml-1 font-normal text-slate-400">(acta observada)</span>
                      </label>
                      <Input
                        value={motivoEdicion}
                        onChange={(e) => setMotivoEdicion(e.target.value)}
                        maxLength={400}
                        placeholder="Ej.: dígito ilegible en columna regional; corregido contra el papel"
                        className={`w-full ${motivoEdicion.trim() ? "" : "border-amber-400"}`}
                        aria-label="Motivo de la modificación"
                      />
                    </div>
                  )}
                  <Boton variante="suave" onClick={onClose} clase="w-full sm:w-auto">Cancelar</Boton>
                  <Boton
                    variante="primario"
                    onClick={handleSave}
                    deshabilitado={isSaving || Object.keys(errors).length > 0
                      || (acta.requires_review && motivoEdicion.trim().length === 0)}
                    clase="w-full sm:w-auto"
                  >
                    {isSaving ? "Guardando..." : mode === "validate" ? "Confirmar Validación" : "Guardar Cambios"}
                  </Boton>
                </div>
              )}
            </div>
          </div>
        </div>
      </div>

      {/* ===== MODAL EMERGENTE CENTRADO (R6, sobre el modal de edición) ===== */}
      {avisoAtipico && (
        <ModalVotosInusuales
          mensaje={avisoAtipico}
          onConfirmar={() => { setConfirmacionActaFisica(true); void handleSave(); }}
          onRevisar={() => {
            setAvisoAtipico(null);
            setConfirmacionActaFisica(false);
            const casillas = [...document.querySelectorAll<HTMLInputElement>(
              'input[aria-label^="Votos "]')];
            const mayor = casillas.reduce<{ el: HTMLInputElement | null; v: number }>(
              (acc, el) => {
                const v = Number(el.value) || 0;
                return v > acc.v ? { el, v } : acc;
              }, { el: null, v: -1 });
            (mayor.el ?? casillas[0])?.focus();
            (mayor.el ?? casillas[0])?.scrollIntoView({ behavior: "smooth", block: "center" });
          }}
        />
      )}

      {/* ===== TOAST DE ERROR DE GUARDADO (no pierde lo digitado) ===== */}
      {errorToast && (
        <div
          role="alert"
          className="fixed bottom-6 left-1/2 z-[80] -translate-x-1/2 rounded-xl border-2 border-red-300 bg-red-50 px-5 py-3 text-sm font-bold text-red-800 shadow-lg"
        >
          ⚠ Error al guardar el acta. Intente nuevamente — sus datos siguen en el formulario.
        </div>
      )}

      {/* ===== MODAL EMERGENTE CENTRADO (R0, bloqueo por acta vacía) ===== */}
      {bloqueoVacia && (
        <ModalActaVacia
          onVolverADigitar={() => {
            setBloqueoVacia(false);
            // Enfoca la PRIMERA casilla de votación para iniciar la corrección.
            const primera = document.querySelector<HTMLInputElement>(
              'input[aria-label^="Votos "]');
            primera?.focus();
            primera?.scrollIntoView({ behavior: "smooth", block: "center" });
          }}
        />
      )}
    </div>
  );
}