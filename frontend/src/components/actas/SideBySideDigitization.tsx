import { useCallback, useEffect, useRef, useState } from "react";
import type { ActaRecord, RankingEntry, CandidateVotes } from "../../types";
import { api } from "../../api";
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

  const validateForm = useCallback(() => {
    const districtSum = formData.votos_distrital.reduce((sum, c) => sum + c.votes, 0);
    const regionalSum = formData.votos_regional.reduce((sum, c) => sum + c.votes, 0);
    const provincialSum = formData.votos_provincial.reduce((sum, c) => sum + c.votes, 0);
    const consejeroSum = formData.votos_consejero.reduce((sum, c) => sum + c.votes, 0);
    const totalValidVotes = districtSum + regionalSum + provincialSum + consejeroSum;
    const totalVotes = totalValidVotes + formData.votos_blancos + formData.votos_nulos + formData.votos_impugnados;

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
    } else if (formData.total_votantes > 0 && totalVotes !== formData.total_votantes) {
      // R1 (descuadre): no bloquea — se guarda y queda OBSERVADA.
      newErrors.votes_sum = `La suma de votos (${totalVotes.toLocaleString()}) no coincide con los votantes (${formData.total_votantes.toLocaleString()}). Puede guardar: el acta quedará OBSERVADA.`;
    }

    setErrors(newErrors);
    // Sólo los errores bloqueantes (no el descuadre informativo) impiden guardar.
    return !newErrors.total_electores && !(newErrors.votes_sum && newErrors.votes_sum.includes("superar"));
  }, [formData]);

  useEffect(() => {
    validateForm();
  }, [validateForm]);

  const handleInputChange = (field: keyof typeof formData, value: any) => {
    setFormData(prev => ({ ...prev, [field]: value }));
  };

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
        image_url: imageUrl || undefined,
        verified: false,
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
        image_url: imageUrl || undefined,
        verified: mode === "validate",
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
      onSave(recordActa);
    } catch (error) {
      setSaveMessage(`Error: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setIsSaving(false);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Escape") onClose();
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
  const totalValidVotes = districtSum + provincialSum + regionalSum + consejeroSum;
  const totalVotes = totalValidVotes + formData.votos_blancos + formData.votos_nulos + formData.votos_impugnados;
  const participationRate = formData.total_electores > 0 ? (totalVotes / formData.total_electores) * 100 : 0;  const toggleFullscreen = () => {
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
      const url = await api.subirFotoActa(file);
      setImageUrl(url);
      setZoomLevel(1);
      setRotation(0);
      setSaveMessage("Imagen cargada. Presiona Guardar Cambios para adjuntarla al acta.");
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
            onChange={(e) => handleCandidateVoteChange(type, index, Number(e.target.value) || 0)}
            onFocus={() => setActiveField(`${type}_${index}`)}
            onBlur={() => setActiveField(null)}
            className="w-24 text-right font-mono text-base"
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
              const votes = Number(e.target.value) || 0;
              setFormData((prev) => {
                const newData = { ...prev };
                newData.votos_consejero = [...prev.votos_consejero];
                newData.votos_consejero[index] = { ...prev.votos_consejero[index], votes };
                return newData;
              });
            }}
            className="w-24 text-right font-mono text-base"
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

  const renderOtherVotes = () => [
    ["votos_blancos", "Votos en Blanco"],
    ["votos_nulos", "Votos Nulos"],
    ["votos_impugnados", "Impugnación de Identidad"],
  ].map(([field, label]) => (
    <div key={field} className="flex items-center gap-3">
      <label className="text-sm font-medium text-slate-700 w-48 shrink-0">{label}</label>
      {!readonly ? (
        <Input
          type="number"
          min={0}
          value={formData[field as keyof typeof formData] ?? 0}
          onChange={(e) => handleInputChange(field as keyof typeof formData, Number(e.target.value) || 0)}
          onFocus={() => setActiveField(field)}
          onBlur={() => setActiveField(null)}
          className="w-32 text-right font-mono text-base"
          inputMode="numeric"
        />
      ) : (
        <div className="w-32 text-right font-mono text-base text-slate-700">
          {(formData[field as keyof typeof formData] ?? 0).toLocaleString()}
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
              <Boton variante="exito" onClick={handleSave} disabled={isSaving || (errors.total_electores ? true : (errors.votes_sum ? errors.votes_sum.includes("superar") : false))} clase="px-3 py-1.5 text-xs sm:px-4 sm:py-2 sm:text-sm">
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

          {/* RIGHT PANEL: DIGITIZATION FORM */}
          <div className="flex w-full flex-col bg-white sm:w-1/2 sm:overflow-y-auto">
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

            <div className="p-4 space-y-6 sm:flex-1 sm:overflow-y-auto">
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
                        onChange={(e) => handleInputChange('total_electores', Number(e.target.value) || 0)}
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
                        onChange={(e) => handleInputChange('total_votantes', Number(e.target.value) || 0)}
                        onFocus={() => setActiveField('total_votantes')}
                        onBlur={() => setActiveField(null)}
                        className={errors.votes_sum && errors.votes_sum.includes("superar") ? "border-red-500" : ""}
                        inputMode="numeric"
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

              {/* VOTOS DISTRITALES */}
              <Card className="p-4">
                <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                  <span className="w-6 h-6 rounded-full bg-[#10b981] text-white text-xs flex items-center justify-center">2</span>
                  Votos Distritales (Alcalde Distrital) — {districtSum.toLocaleString()} votos
                </h4>
                <div className="space-y-2 max-h-64 overflow-y-auto">
                  {acta.votos_distrital.map((c, i) => renderVoteRow(c, 'distrital', i))}
                </div>
              </Card>

              {/* VOTOS PROVINCIALES */}
              <Card className="p-4">
                <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                  <span className="w-6 h-6 rounded-full bg-[#8b5cf6] text-white text-xs flex items-center justify-center">3</span>
                  Votos Provinciales (Alcalde Provincial) — {provincialSum.toLocaleString()} votos
                </h4>
                <div className="space-y-2 max-h-64 overflow-y-auto">
                  {acta.votos_provincial.map((c, i) => renderVoteRow(c, 'provincial', i))}
                </div>
              </Card>

              {/* VOTOS REGIONALES */}
              <Card className="p-4">
                <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                  <span className="w-6 h-6 rounded-full bg-[#f59e0b] text-white text-xs flex items-center justify-center">4</span>
                  Votos Regionales (Gobernador Regional) — {regionalSum.toLocaleString()} votos
                </h4>
                <div className="space-y-2 max-h-64 overflow-y-auto">
                  {acta.votos_regional.map((c, i) => renderVoteRow(c, 'regional', i))}
                </div>
              </Card>

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
                </Card>
              )}

              {/* OTROS VOTOS */}
              <Card className="p-4 bg-slate-50 border-slate-200">
                <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                  <span className="w-6 h-6 rounded-full bg-slate-600 text-white text-xs flex items-center justify-center">5</span>
                  Otros Votos
                </h4>
                <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
                  {renderOtherVotes()}
                </div>
              </Card>

              {/* RESUMEN DE VALIDACIÓN */}
              <Card className="p-4" variant={errors.votes_sum ? "error" : "outline"}>
                <h4 className="font-semibold text-slate-800 mb-3">Resumen de Validación</h4>
                <div className="space-y-2 text-sm">
                  <div className="flex justify-between">
                    <span className="text-slate-600">Votos válidos distritales:</span>
                    <span className="font-mono font-bold">{districtSum.toLocaleString()}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-600">Votos válidos provinciales:</span>
                    <span className="font-mono font-bold">{provincialSum.toLocaleString()}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-600">Votos válidos regionales:</span>
                    <span className="font-mono font-bold">{regionalSum.toLocaleString()}</span>
                  </div>
                  {consejeroSum > 0 && (
                    <div className="flex justify-between">
                      <span className="text-slate-600">Votos válidos consejeros:</span>
                      <span className="font-mono font-bold">{consejeroSum.toLocaleString()}</span>
                    </div>
                  )}
                  <div className="flex justify-between border-t border-slate-200 pt-2">
                    <span className="text-slate-600 font-medium">Total votos válidos:</span>
                    <span className="font-mono font-bold text-[#E02020]">{totalValidVotes.toLocaleString()}</span>
                  </div>
                  <div className="flex justify-between">
                    <span className="text-slate-600">Blancos + Nulos + Impugnados:</span>
                    <span className="font-mono font-bold">
                      {(formData.votos_blancos + formData.votos_nulos + formData.votos_impugnados).toLocaleString()}
                    </span>
                  </div>
                  <div className="flex justify-between border-t border-slate-200 pt-2 font-medium">
                    <span className="text-slate-800">Total de votos emitidos:</span>
                    <span className="font-mono font-bold text-lg">{totalVotes.toLocaleString()}</span>
                  </div>
                  {errors.votes_sum && (
                    <div className="flex justify-between text-red-600 font-medium bg-red-50 px-3 py-2 rounded">
                      <span>⚠ Estado:</span>
                      <span>{errors.votes_sum}</span>
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
                  <Boton variante="secundario" onClick={onClose} clase="w-full sm:w-auto">Cancelar</Boton>
                  <Boton
                    variante="primario"
                    onClick={handleSave}
                    disabled={isSaving || Object.keys(errors).length > 0}
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
    </div>
  );
}