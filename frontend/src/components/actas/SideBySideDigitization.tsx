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
    votos_distrital: acta.votos_distrital.map((c) => ({
      candidate_id: c.candidate_id,
      votes: c.votes,
    })),
    votos_provincial: acta.votos_provincial.map((c) => ({
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

  const validateForm = useCallback(() => {
    const districtSum = formData.votos_distrital.reduce((sum, c) => sum + c.votes, 0);
    const regionalSum = formData.votos_regional.reduce((sum, c) => sum + c.votes, 0);
    const provincialSum = formData.votos_provincial.reduce((sum, c) => sum + c.votes, 0);
    const totalValidVotes = districtSum + regionalSum + provincialSum;
    const totalVotes = totalValidVotes + formData.votos_blancos + formData.votos_nulos + formData.votos_impugnados;

    const newErrors: { total_electores?: string; votes_sum?: string } = {};

    if (formData.total_electores < 0) {
      newErrors.total_electores = "El número de electores no puede ser negativo";
    }

    if (formData.total_electores > 0 && totalVotes !== formData.total_electores) {
      newErrors.votes_sum = `La suma de votos (${totalVotes.toLocaleString()}) no coincide con el total de electores (${formData.total_electores.toLocaleString()})`;
    }

    setErrors(newErrors);
    return Object.keys(newErrors).length === 0;
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
  const totalValidVotes = districtSum + provincialSum + regionalSum;
  const totalVotes = totalValidVotes + formData.votos_blancos + formData.votos_nulos + formData.votos_impugnados;
  const participationRate = formData.total_electores > 0 ? (totalVotes / formData.total_electores) * 100 : 0;

  const toggleFullscreen = () => {
    setIsFullscreen(!isFullscreen);
    if (!isFullscreen && imageRef.current) {
      imageRef.current.requestFullscreen();
    } else {
      document.exitFullscreen();
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
      EN_DIGITACION: "bg-blue-100 text-blue-800",
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
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onKeyDown={handleKeyDown}>
      <div
        className={`relative w-[95vw] max-w-[1400px] h-[90vh] mx-4 bg-white rounded-xl shadow-2xl overflow-hidden flex ${
          isFullscreen ? "fixed inset-0 w-screen h-screen max-w-none max-h-none rounded-none" : ""
        }`}
      >
        <div className="flex items-center justify-between p-4 bg-slate-100 border-b sticky top-0 z-10">
          <div className="flex items-center gap-4">
            <h2 className="text-xl font-bold text-[#002B66]">
              {mode === "validate" ? "Validar contra Acta" : mode === "view" ? "Ver Acta" : "Editar Acta"}
              <span className="ml-2 text-sm font-normal text-slate-600">Mesa {acta.numero_mesa}</span>
            </h2>
            <span className={`px-2.5 py-1 rounded-full text-xs font-bold ${getStatusBadge(acta.status)}`}>
              {getStatusLabel(acta.status)}
            </span>
            {autoSaveStatus !== "idle" && (
              <span className="text-xs text-slate-500 flex items-center gap-1">
                {autoSaveStatus === "saving" && "⟳"}
                {autoSaveStatus === "saved" && "✓"}
                {autoSaveStatus === "error" && "✗"}
                {autoSaveStatus === "saved" && lastAutoSave && ` Guardado ${lastAutoSave.toLocaleTimeString()}`}
              </span>
            )}
          </div>
          <div className="flex items-center gap-2">
            {mode !== "view" && !readonly && (
              <Boton variante="exito" onClick={handleSave} disabled={isSaving || Object.keys(errors).length > 0}>
                {isSaving ? "Guardando..." : "Guardar Cambios"}
              </Boton>
            )}
            <button onClick={onClose} className="text-gray-500 hover:text-gray-700 p-2">
              ✕
            </button>
          </div>
        </div>

        <div className="flex flex-1 overflow-hidden">
          {/* LEFT PANEL: IMAGE VIEWER */}
          <div className="w-1/2 border-r border-slate-200 bg-slate-50 flex flex-col relative">
            <div className="flex items-center justify-between p-3 bg-white border-b border-slate-200 sticky top-0 z-5">
              <h3 className="font-semibold text-slate-800">Documento Original - Acta Digitalizada</h3>
              <div className="flex items-center gap-2">
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
                {acta.image_url && (
                  <a
                    href={acta.image_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="px-2 py-1 bg-white border border-slate-300 rounded text-xs hover:bg-slate-50"
                  >
                    ↓ Descargar
                  </a>
                )}
              </div>
            </div>

            <div className="flex-1 flex items-center justify-center relative overflow-auto p-4" ref={imageRef}>
              {acta.image_url ? (
                <div
                  className="relative flex items-center justify-center"
                  style={{
                    transform: `scale(${zoomLevel}) rotate(${rotation}deg)`,
                    transformOrigin: "center center",
                    transition: "transform 0.15s ease",
                  }}
                >
                  <img
                    src={acta.image_url}
                    alt={`Acta mesa ${acta.numero_mesa}`}
                    className={`max-w-full max-h-full object-${fitMode} shadow-lg`}
                    style={fitMode === "width" ? { width: "100%" } : fitMode === "height" ? { height: "100%" } : {}}
                  />
                </div>
              ) : (
                <div className="text-center text-slate-500 py-12">
                  <div className="text-6xl mb-2">📄</div>
                  <p className="text-lg">No hay imagen de acta disponible</p>
                  <p className="text-sm mt-1">Suba una imagen para poder digitalizar contra el original</p>
                </div>
              )}
            </div>

            <div className="p-3 bg-white border-t border-slate-200 text-xs text-slate-500">
              Zoom: {(zoomLevel * 100).toFixed(0)}% | Rotación: {rotation}° | Ajuste: {fitMode}
            </div>
          </div>

          {/* RIGHT PANEL: DIGITIZATION FORM */}
          <div className="w-1/2 flex flex-col overflow-y-auto bg-white">
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

            <div className="p-4 space-y-6 flex-1 overflow-y-auto">
              {/* METADATOS */}
              <Card className="p-4">
                <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                  <span className="w-6 h-6 rounded-full bg-[#002B66] text-white text-xs flex items-center justify-center">1</span>
                  Identificación del Acta
                </h4>
                <div className="grid grid-cols-2 gap-4">
                  <div>
                    <label className="block text-xs font-bold text-slate-600 mb-1">N° de Mesa</label>
                    <Input
                      value={acta.numero_mesa}
                      disabled
                      className="bg-slate-50 font-mono text-lg tracking-widest"
                    />
                  </div>
                  <div>
                    <label className="block text-xs font-bold text-slate-600 mb-1">Total Electores Hábiles</label>
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

              {/* OTROS VOTOS */}
              <Card className="p-4 bg-slate-50 border-slate-200">
                <h4 className="font-semibold text-slate-800 mb-3 flex items-center gap-2">
                  <span className="w-6 h-6 rounded-full bg-slate-600 text-white text-xs flex items-center justify-center">5</span>
                  Otros Votos
                </h4>
                <div className="grid grid-cols-3 gap-4">
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
                  <div className="flex justify-between border-t border-slate-200 pt-2">
                    <span className="text-slate-600 font-medium">Total votos válidos:</span>
                    <span className="font-mono font-bold text-[#002B66]">{totalValidVotes.toLocaleString()}</span>
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
                    <span className="font-mono font-bold text-[#002B66]">{participationRate.toFixed(1)}%</span>
                  </div>
                </div>
              </Card>

              {/* ACTIONS */}
              {mode !== "view" && !readonly && (
                <div className="flex justify-end gap-3 pt-4 border-t border-slate-200">
                  <Boton variante="secundario" onClick={onClose}>Cancelar</Boton>
                  <Boton
                    variante="primario"
                    onClick={handleSave}
                    disabled={isSaving || Object.keys(errors).length > 0}
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