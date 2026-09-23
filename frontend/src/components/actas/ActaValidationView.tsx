import { useCallback, useEffect, useRef, useState } from "react";
import type { ActaRecord, RankingEntry } from "../../types";
import { api } from "../../api";
import { Boton, Card, Alerta } from "../ui";

interface ActaValidationViewProps {
  acta: ActaRecord | null;
  onClose: () => void;
  onValidated: (acta: ActaRecord) => void;
}

export default function ActaValidationView({ acta, onClose, onValidated }: ActaValidationViewProps) {
  if (!acta) return null;

  const [step, setStep] = useState<"verify" | "confirm">("verify");
  const [checkedFields, setCheckedFields] = useState<Record<string, boolean>>({});
  const [validatorName, setValidatorName] = useState("");
  const [validatorDni, setValidatorDni] = useState("");
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [message, setMessage] = useState<string | null>(null);

  const imageRef = useRef<HTMLDivElement>(null);
  const [zoomLevel, setZoomLevel] = useState(1);
  const [rotation, setRotation] = useState(0);
  const [fitMode, setFitMode] = useState<"contain" | "width" | "height">("contain");
  const [isFullscreen, setIsFullscreen] = useState(false);

  const toggleFullscreen = () => {
    setIsFullscreen(!isFullscreen);
    if (!isFullscreen && imageRef.current) {
      imageRef.current.requestFullscreen();
    } else {
      document.exitFullscreen();
    }
  };

  const allFields = useMemo(() => {
    if (!acta) return [];
    const fields: Array<{ key: string; label: string; value: string }> = [
      { key: "numero_mesa", label: "Número de Mesa", value: acta.numero_mesa },
      { key: "venue_name", label: "Local de Votación", value: acta.venue_name || "—" },
      { key: "total_electores", label: "Electores Hábiles", value: acta.total_electores.toLocaleString() },
    ];

    acta.votos_distrital.forEach((c, i) => {
      fields.push({ key: `votos_distrital_${i}`, label: `Distrital - ${c.name} (${c.party})`, value: c.votes.toLocaleString() });
    });
    acta.votos_provincial.forEach((c, i) => {
      fields.push({ key: `votos_provincial_${i}`, label: `Provincial - ${c.name} (${c.party})`, value: c.votes.toLocaleString() });
    });
    acta.votos_regional.forEach((c, i) => {
      fields.push({ key: `votos_regional_${i}`, label: `Regional - ${c.name} (${c.party})`, value: c.votes.toLocaleString() });
    });

    fields.push(
      { key: "votos_blancos", label: "Votos en Blanco", value: acta.votos_blancos.toLocaleString() },
      { key: "votos_nulos", label: "Votos Nulos", value: acta.votos_nulos.toLocaleString() },
      { key: "votos_impugnados", label: "Impugnación de Identidad", value: acta.votos_impugnados.toLocaleString() }
    );

    const totalVotos = 
      acta.votos_distrital.reduce((s, c) => s + c.votes, 0) +
      acta.votos_provincial.reduce((s, c) => s + c.votes, 0) +
      acta.votos_regional.reduce((s, c) => s + c.votes, 0) +
      acta.votos_blancos + acta.votos_nulos + acta.votos_impugnados;
    fields.push({ key: "total_votos", label: "Total Votos Emitidos", value: totalVotos.toLocaleString() });

    const participacion = acta.total_electores > 0 ? (totalVotos / acta.total_electores) * 100 : 0;
    fields.push({ key: "participacion", label: "Participación", value: `${participacion.toFixed(1)}%` });

    return fields;
  }, [acta]);

  const allChecked = Object.keys(checkedFields).length === allFields.length && 
    allFields.every(f => checkedFields[f.key]);

  const handleFieldCheck = (key: string, checked: boolean) => {
    setCheckedFields(prev => ({ ...prev, [key]: checked }));
  };

  const handleValidate = async () => {
    if (!validatorName.trim() || !validatorDni.trim()) {
      setMessage("Debe ingresar nombre y DNI del validador");
      return;
    }
    if (!allChecked) {
      setMessage("Debe verificar todos los campos antes de confirmar");
      return;
    }

    setIsSubmitting(true);
    setMessage(null);

    try {
      const payload = {
        votos_distrital: acta.votos_distrital.map(c => ({ candidate_id: c.candidate_id, votes: c.votes })),
        votos_provincial: acta.votos_provincial.map(c => ({ candidate_id: c.candidate_id, votes: c.votes })),
        votos_regional: acta.votos_regional.map(c => ({ candidate_id: c.candidate_id, votes: c.votes })),
        votos_blancos: acta.votos_blancos,
        votos_nulos: acta.votos_nulos,
        votos_impugnados: acta.votos_impugnados,
        total_electores: acta.total_electores,
        verified: true,
      };

      const updatedActa = await api.updateActa(acta.id, payload);

      const recordActa: ActaRecord = {
        id: updatedActa.id,
        numero_mesa: updatedActa.numero_mesa,
        status: "VALIDADA",
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

      setMessage("Acta validada correctamente");
      setTimeout(() => {
        onValidated(recordActa);
        onClose();
      }, 1500);
    } catch (error) {
      setMessage(`Error: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setIsSubmitting(false);
    }
  };

  const handleKeyDown = (e: React.KeyboardEvent) => {
    if (e.key === "Escape") onClose();
    if (e.ctrlKey && e.key === "Enter" && step === "confirm") handleValidate();
  };

  useEffect(() => {
    window.addEventListener("keydown", handleKeyDown as EventListener);
    return () => window.removeEventListener("keydown", handleKeyDown as EventListener);
  }, [onClose]);

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50" onKeyDown={handleKeyDown}>
      <div
        className={`relative w-[95vw] max-w-[1400px] h-[90vh] mx-4 bg-white rounded-xl shadow-2xl overflow-hidden flex ${
          isFullscreen ? "fixed inset-0 w-screen h-screen max-w-none max-h-none rounded-none" : ""
        }`}
      >
        <div className="flex items-center justify-between p-4 bg-slate-100 border-b sticky top-0 z-10">
          <div className="flex items-center gap-4">
            <h2 className="text-xl font-bold text-[#E02020]">
              Validación Visual contra Acta Original
              <span className="ml-2 text-sm font-normal text-slate-600">Mesa {acta.numero_mesa}</span>
            </h2>
            <span className="px-2.5 py-1 bg-amber-100 text-amber-800 rounded-full text-xs font-bold">
              Paso {step === "verify" ? "1/2" : "2/2"}: {step === "verify" ? "Verificar Campos" : "Confirmar Validación"}
            </span>
          </div>
          <button onClick={onClose} className="text-gray-500 hover:text-gray-700 p-2">✕</button>
        </div>

        <div className="flex flex-1 overflow-hidden">
          {/* LEFT: IMAGE */}
          <div className="w-1/2 border-r border-slate-200 bg-slate-50 flex flex-col relative">
            <div className="flex items-center justify-between p-3 bg-white border-b border-slate-200 sticky top-0 z-5">
              <h3 className="font-semibold text-slate-800">Documento Original - Acta Digitalizada</h3>
              <div className="flex items-center gap-2">
                <button onClick={() => setZoomLevel(z => Math.min(z + 0.2, 4))} className="px-2 py-1 bg-white border border-slate-300 rounded text-xs hover:bg-slate-50">+</button>
                <button onClick={() => setZoomLevel(z => Math.max(z - 0.2, 0.25))} className="px-2 py-1 bg-white border border-slate-300 rounded text-xs hover:bg-slate-50">−</button>
                <button onClick={() => setRotation(r => (r + 90) % 360)} className="px-2 py-1 bg-white border border-slate-300 rounded text-xs hover:bg-slate-50">⟳</button>
                <select value={fitMode} onChange={(e) => setFitMode(e.target.value as any)} className="px-2 py-1 bg-white border border-slate-300 rounded text-xs">
                  <option value="contain">Ajustar a pantalla</option>
                  <option value="width">Ajustar ancho</option>
                  <option value="height">Ajustar alto</option>
                </select>
                <button onClick={toggleFullscreen} className="px-2 py-1 bg-white border border-slate-300 rounded text-xs hover:bg-slate-50">
                  {isFullscreen ? "⛶ Salir" : "⛶ Pantalla completa"}
                </button>
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
                  <p className="text-sm mt-1">No se puede validar sin imagen de referencia</p>
                </div>
              )}
            </div>
            <div className="p-3 bg-white border-t border-slate-200 text-xs text-slate-500">
              Zoom: {(zoomLevel * 100).toFixed(0)}% | Rotación: {rotation}° | Ajuste: {fitMode}
            </div>
          </div>

          {/* RIGHT: VALIDATION CHECKLIST */}
          <div className="w-1/2 flex flex-col overflow-y-auto bg-white">
            <div className="p-4 border-b border-slate-200 sticky top-0 z-5 bg-white">
              <h3 className="font-semibold text-slate-800">Checklist de Validación</h3>
              <p className="text-xs text-slate-500 mt-1">
                Marque cada campo después de comparar el valor digitado con la imagen del acta
              </p>
              <div className="mt-2 flex items-center gap-3 text-sm">
                <span className={allChecked ? "text-emerald-600" : "text-slate-500"}>
                  {Object.keys(checkedFields).filter(k => checkedFields[k]).length} / {allFields.length} verificados
                </span>
                <div className="flex-1 h-2 bg-slate-200 rounded-full overflow-hidden">
                  <div className="h-full bg-emerald-500 transition-all" style={{ width: `${(Object.keys(checkedFields).filter(k => checkedFields[k]).length / allFields.length) * 100}%` }} />
                </div>
              </div>
            </div>

            {message && <Alerta tono={message.startsWith("Error") ? "error" : "exito"} className="m-4">{message}</Alerta>}

            {step === "verify" && (
              <div className="p-4 flex-1 overflow-y-auto">
                <div className="space-y-2">
                  {allFields.map((field) => (
                    <label
                      key={field.key}
                      className={`flex items-center gap-3 p-3 rounded-lg border transition-colors ${
                        checkedFields[field.key]
                          ? "bg-emerald-50 border-emerald-200"
                          : "bg-white border-slate-200 hover:bg-slate-50"
                      }`}
                    >
                      <input
                        type="checkbox"
                        checked={checkedFields[field.key]}
                        onChange={(e) => handleFieldCheck(field.key, e.target.checked)}
                        className="w-5 h-5 text-emerald-600 border-slate-300 rounded focus:ring-emerald-500"
                      />
                      <div className="flex-1 min-w-0">
                        <p className="text-sm font-medium text-slate-800 truncate">{field.label}</p>
                        <p className="text-xs font-mono text-slate-500 truncate">{field.value}</p>
                      </div>
                      {checkedFields[field.key] && (
                        <span className="text-emerald-600 text-sm">✓ Verificado</span>
                      )}
                    </label>
                  ))}
                </div>

                {allChecked && (
                  <div className="mt-6 p-4 bg-emerald-50 border border-emerald-200 rounded-xl">
                    <div className="flex items-center gap-3">
                      <span className="text-2xl">✓</span>
                      <div>
                        <p className="font-bold text-emerald-800">Todos los campos verificados</p>
                        <p className="text-sm text-emerald-600">Puede proceder a confirmar la validación</p>
                      </div>
                    </div>
                    <button
                      onClick={() => setStep("confirm")}
                      className="mt-4 w-full bg-emerald-600 text-white py-3 rounded-lg font-bold hover:bg-emerald-700 transition-colors"
                    >
                      Continuar a Confirmación →
                    </button>
                  </div>
                )}
              </div>
            )}

            {step === "confirm" && (
              <div className="p-4 flex-1 overflow-y-auto">
                <Card className="mb-4" variant="outline">
                  <h4 className="font-semibold text-slate-800 mb-3">Resumen de Validación</h4>
                  <div className="space-y-2 text-sm">
                    <div className="flex justify-between">
                      <span className="text-slate-600">Mesa:</span>
                      <span className="font-mono font-bold">{acta.numero_mesa}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-600">Local:</span>
                      <span className="font-mono font-bold">{acta.venue_name || "—"}</span>
                    </div>
                    <div className="flex justify-between">
                      <span className="text-slate-600">Total electores:</span>
                      <span className="font-mono font-bold">{acta.total_electores.toLocaleString()}</span>
                    </div>
                    <div className="flex justify-between border-t pt-2">
                      <span className="text-slate-600">Campos verificados:</span>
                      <span className="font-mono font-bold text-emerald-600">{allFields.length} / {allFields.length}</span>
                    </div>
                  </div>
                </Card>

                <Card className="mb-4" variant="outline">
                  <h4 className="font-semibold text-slate-800 mb-3">Datos del Validador</h4>
                  <div className="grid grid-cols-2 gap-4">
                    <div>
                      <label className="block text-xs font-bold text-slate-600 mb-1">Nombre completo</label>
                      <input
                        type="text"
                        value={validatorName}
                        onChange={(e) => setValidatorName(e.target.value)}
                        className="w-full px-3 py-2 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-red-500"
                        placeholder="Juan Pérez García"
                      />
                    </div>
                    <div>
                      <label className="block text-xs font-bold text-slate-600 mb-1">DNI</label>
                      <input
                        type="text"
                        value={validatorDni}
                        onChange={(e) => setValidatorDni(e.target.value.replace(/\D/g, "").slice(0, 8))}
                        className="w-full px-3 py-2 border border-slate-300 rounded-lg focus:outline-none focus:ring-2 focus:ring-red-500"
                        placeholder="12345678"
                        inputMode="numeric"
                        maxLength={8}
                      />
                    </div>
                  </div>
                </Card>

                <div className="p-4 bg-amber-50 border border-amber-200 rounded-xl">
                  <p className="text-sm font-semibold text-amber-800 mb-2">⚠ Confirmación de Validación</p>
                  <p className="text-sm text-amber-700">
                    Al confirmar, declara bajo responsabilidad que ha comparado <strong>cada campo</strong> 
                    con la imagen digitalizada del acta original y que los valores digitados son correctos.
                    Esta acción <strong>no se puede deshacer</strong> y quedará registrada en la auditoría.
                  </p>
                </div>

                <div className="flex justify-end gap-3 pt-4 border-t border-slate-200">
                  <Boton variante="secundario" onClick={() => setStep("verify")}>← Volver a Verificación</Boton>
                  <Boton
                    variante="primario"
                    onClick={handleValidate}
                    disabled={isSubmitting || !validatorName.trim() || !validatorDni.trim()}
                  >
                    {isSubmitting ? "Validando..." : "Confirmar Validación Final"}
                  </Boton>
                </div>
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}