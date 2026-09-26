import { useState } from "react";
import type { ActaRecord } from "../types";
import { api } from "../api";
import ActaValidationForm from "./ActaValidationForm";

interface ActaUploaderProps {
  onSuccess: () => void; // Callback when acta is successfully saved
}

export default function ActaUploader({ onSuccess }: ActaUploaderProps) {
  const [step, setStep] = useState<'choice' | 'ocr' | 'manual' | 'validation'>('choice');
  const [ocrResult, setOcrResult] = useState<ActaRecord | null>(null);
  const [manualData, setManualData] = useState<ActaRecord | null>(null);
  const [validationActa, setValidationActa] = useState<ActaRecord | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [processing, setProcessing] = useState(false);

  const handleOcrUpload = async (file: File) => {
    setProcessing(true);
    setError(null);
    try {
      const result = await api.ocrActa(file);
      // Convert OCR result to ActaRecord format (missing some fields, we'll fill with defaults)
      const acta: ActaRecord = {
        id: 0, // temporary ID, will be replaced when saved
        numero_mesa: result.numero_mesa,
        status: "pending",
        requires_review: false,
        ocr_confidence: result.ocr_confidence,
        image_url: result.image_url ?? "",
        venue_id: 0,
        venue_name: "",
        sector: "",
        latitude: 0,
        longitude: 0,
        votos_distrital: result.votos_distrital,
        votos_provincial: result.votos_provincial ?? [],
        votos_consejero: result.votos_consejero ?? [],
        votos_regional: result.votos_regional,
        votos_blancos: result.votos_blancos,
        votos_nulos: result.votos_nulos,
        votos_impugnados: result.votos_impugnados,
        total_electores: 0, // OCR doesn't provide this, user must enter in validation
      };
      setOcrResult(acta);
      setValidationActa(acta);
      setStep('validation');
    } catch (err) {
      setError(`Error en OCR: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setProcessing(false);
    }
  };

  const handleManualSubmit = (acta: ActaRecord) => {
    setManualData(acta);
    setValidationActa(acta);
    setStep('validation');
  };

  const handleValidationSave = async (acta: ActaRecord) => {
    setProcessing(true);
    try {
      // For new acta, we use createActa API
      const savedActa = await api.createActa(acta);
      // Update the acta with the saved ID and status
      const finalActa: ActaRecord = {
        ...savedActa,
        numero_mesa: savedActa.numero_mesa,
        status: savedActa.status,
        requires_review: savedActa.requires_review,
        ocr_confidence: savedActa.ocr_confidence ?? 0,
        image_url: savedActa.image_url ?? "",
        venue_id: savedActa.venue_id ?? 0,
        venue_name: savedActa.venue_name ?? "",
        sector: savedActa.sector ?? "",
        latitude: savedActa.latitude ?? 0,
        longitude: savedActa.longitude ?? 0,
        votos_distrital: savedActa.votos_distrital,
        votos_provincial: savedActa.votos_provincial ?? [],
        votos_consejero: savedActa.votos_consejero ?? [],
        votos_regional: savedActa.votos_regional,
        votos_blancos: savedActa.votos_blancos,
        votos_nulos: savedActa.votos_nulos,
        votos_impugnados: savedActa.votos_impugnados,
        total_electores: savedActa.total_electores,
      };
      setStep('choice');
      onSuccess(); // Notify parent to refresh list
    } catch (err) {
      setError(`Error al guardar: ${err instanceof Error ? err.message : String(err)}`);
    } finally {
      setProcessing(false);
    }
  };

  const handleValidationCancel = () => {
    setStep('choice');
    setValidationActa(null);
  };

  return (
    <div className="space-y-4">
      {step === 'choice' && (
        <div className="border rounded-lg p-4 bg-white shadow-sm">
          <h3 className="font-semibold text-slate-800 mb-4">Cargar Nueva Acta</h3>
          <div className="grid gap-4 md:grid-cols-2">
            <button
              onClick={() => setStep('ocr')}
              className="flex flex-col items-center justify-center p-6 border border-dashed rounded-lg hover:border-[#E02020] hover:bg-red-50 transition"
            >
              <div className="mb-3">
                {/* Upload icon */}
                <svg className="h-8 w-8 text-[#E02020] mb-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 16l4.586-4.586a2 2 0 012.828 0L16 16m-2-2l1.586-1.586a2 2 0 012.828 0L20 12m-2 2l-1.586-1.586a2 2 0 00-2.828 0L4 12m-2 2l1.586 1.586a2 2 0 002.828 0L12 16m5-9V4a2 2 0 00-2-2H6a2 2 0 00-2 2v2"></path>
                </svg>
                <p className="text-sm font-medium text-[#E02020]">Subir Imagen</p>
              </div>
              <p className="text-xs text-slate-500 text-center">
                Use OCR para extraer datos automáticamente de una foto del acta
              </p>
            </button>
            <button
              onClick={() => setStep('manual')}
              className="flex flex-col items-center justify-center p-6 border border-dashed rounded-lg hover:border-[#E02020] hover:bg-red-50 transition"
            >
              <div className="mb-3">
                {/* Edit icon */}
                <svg className="h-8 w-8 text-[#E02020] mb-2" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M15.232 5.232l3.536 3.536m-2.036-5.036a2.5 2.5 0 013.536 3.536L19.5 12l-4 4 2 2 4-4c.895-1.135.25-2.508-1.508-2.508H4.75a2 2 0 00-2 2v1.268c0 .271.11.528.292.707l1.768 1.768a2.5 2.5 0 003.536 3.536l1.242-1.242a2.5 2.5 0 013.536-3.536z"></path>
                </svg>
                <p className="text-sm font-medium text-[#E02020]">Entrada Manual</p>
              </div>
              <p className="text-xs text-slate-500 text-center">
                Ingrese los datos del acta manualmente en un formulario
              </p>
            </button>
          </div>
        </div>
      )}
      {step === 'ocr' && (
        <div className="border rounded-lg p-4 bg-white shadow-sm">
          <h3 className="font-semibold text-slate-800 mb-4">Subir Imagen para OCR</h3>
          <div className="space-y-4">
            <div>
              <label className="block text-sm font-medium text-slate-700 mb-1">
                Seleccione una imagen del acta (JPG, PNG)
              </label>
              <input
                type="file"
                accept="image/*"
                className="w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
                onChange={(e) => {
                  const file = e.target.files?.[0];
                  if (file) {
                    handleOcrUpload(file);
                  }
                }}
              />
            </div>
            {processing && (
              <div className="flex items-center justify-center py-4">
                <div className="flex items-center space-x-3">
                  <div className="h-4 w-4 border-2 border-red-500 border-t-transparent rounded-full animate-spin"></div>
                  <span className="text-sm text-slate-600">Procesando acta con OCR...</span>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
      {step === 'manual' && (
        <div className="border rounded-lg p-4 bg-white shadow-sm">
          <h3 className="font-semibold text-slate-800 mb-4">Entrada Manual de Datos</h3>
          <ManualEntryForm onSubmit={handleManualSubmit} onError={setError} />
        </div>
      )}
      {step === 'validation' && validationActa && (
        <div className="border rounded-lg p-4 bg-white shadow-sm">
          <h3 className="font-semibold text-slate-800 mb-4">Verificar y Corregir Datos</h3>
          <ActaValidationForm
            acta={validationActa}
            onSave={handleValidationSave}
            onCancel={handleValidationCancel}
          />
        </div>
      )}
      {error && (
        <div className="p-4 bg-red-50 border border-red-200 rounded-lg text-sm">
          <div className="flex items-start">
            <div className="flex-shrink-0">
              <svg className="h-5 w-5 text-red-400" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M12 8v4m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"></path>
              </svg>
            </div>
            <div className="ml-3">
              <p className="text-red-600">{error}</p>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// Simple manual entry form - in a real app, this would be more detailed
function ManualEntryForm({ onSubmit, onError }: { onSubmit: (acta: ActaRecord) => void; onError: (error: string) => void }) {
  const [formData, setFormData] = useState({
    numero_mesa: '',
    votos_distrital: [] as Array<{ candidate_id: number; votes: number }>,
    votos_regional: [] as Array<{ candidate_id: number; votes: number }>,
    votos_blancos: 0,
    votos_nulos: 0,
    votos_impugnados: 0,
    total_electores: 0,
  });

  // In a real app, we would fetch the list of candidates from the API
  // For now, we'll use dummy data
  const [districtCandidates, setDistrictCandidates] = useState([]);
  const [regionalCandidates, setRegionalCandidates] = useState([]);

  // Fetch candidates on mount (simplified)
  // useEffect(() => {
  //   // api.candidates().then(setDistrictCandidates); // etc.
  // }, []);

  // For demo, we'll use hardcoded candidates
  useState(() => {
    setDistrictCandidates([
      { candidate_id: 1, name: "Carlos Torres", party: "Paucarpata Avanza" },
      { candidate_id: 2, name: "María Quispe", party: "Unión por Paucarpata" },
      { candidate_id: 3, name: "Jorge Huamán", party: "Fuerza Popular" },
      { candidate_id: 4, name: "Rosa Paredes", party: "Nueva Esperanza" },
    ]);
    setRegionalCandidates([
      { candidate_id: 1, name: "Pedro Flores", party: "Arequipa Renace" },
      { candidate_id: 2, name: "Luisa Mendoza", party: "Somos Arequipa" },
      { candidate_id: 3, name: "Andrés Chávez", party: "Región Unida" },
      { candidate_id: 4, name: "Carmen Vilca", party: "Alianza Regional" },
    ]);
  });

  const handleSubmit = (e: React.FormEvent) => {
    e.preventDefault();
    // Basic validation
    if (!formData.numero_mesa.trim()) {
      onError("El número de mesa es requerido");
      return;
    }
    // Convert to ActaRecord format
    const acta: ActaRecord = {
      id: 0,
      numero_mesa: formData.numero_mesa.trim(),
      status: "pending",
      requires_review: false,
      ocr_confidence: 1.0, // Manual entry has high confidence
      image_url: "",
      venue_id: 0,
      venue_name: "",
      sector: "",
      latitude: 0,
      longitude: 0,
      votos_distrital: formData.votos_distrital,
      votos_regional: formData.votos_regional,
      votos_blancos: formData.votos_blancos,
      votos_nulos: formData.votos_nulos,
      votos_impugnados: formData.votos_impugnados,
      total_electores: formData.total_electores,
    };
    onSubmit(acta);
  };

  return (
    <form onSubmit={handleSubmit} className="space-y-4">
      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">
          Número de Mesa
        </label>
        <input
          type="text"
          value={formData.numero_mesa}
          onChange={(e) => setFormData({ ...formData, numero_mesa: e.target.value })}
          className="w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
        />
      </div>

      <div>
        <label className="block text-sm font-medium text-slate-700 mb-1">
          Total de Electores Hábiles
        </label>
        <input
          type="number"
          value={formData.total_electores}
          onChange={(e) => setFormData({ ...formData, total_electores: Number(e.target.value) || 0 })}
          className="w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
          min="0"
        />
      </div>

      <div>
        <h4 className="font-medium text-slate-700 mb-2">Votos Distritales</h4>
        <div className="space-y-2">
          {districtCandidates.map((candidate) => (
            <div key={candidate.candidate_id} className="flex items-center justify-between">
              <span className="flex-1">{candidate.name} ({candidate.party})</span>
              <input
                type="number"
                value={formData.votos_distrital.find(v => v.candidate_id === candidate.candidate_id)?.votes ?? 0}
                onChange={(e) => {
                  const votes = Number(e.target.value) || 0;
                  setFormData({
                    ...formData,
                    votos_distrital: formData.votos_distrital.map(v =>
                      v.candidate_id === candidate.candidate_id
                        ? { ...v, votes }
                        : v
                    ),
                  });
                }}
                className="w-20 px-3 py-2 text-center border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
                min="0"
              />
            </div>
          ))}
        </div>
      </div>

      <div>
        <h4 className="font-medium text-slate-700 mb-2">Votos Regionales</h4>
        <div className="space-y-2">
          {regionalCandidates.map((candidate) => (
            <div key={candidate.candidate_id} className="flex items-center justify-between">
              <span className="flex-1">{candidate.name} ({candidate.party})</span>
              <input
                type="number"
                value={formData.votos_regional.find(v => v.candidate_id === candidate.candidate_id)?.votes ?? 0}
                onChange={(e) => {
                  const votes = Number(e.target.value) || 0;
                  setFormData({
                    ...formData,
                    votos_regional: formData.votos_regional.map(v =>
                      v.candidate_id === candidate.candidate_id
                        ? { ...v, votes }
                        : v
                    ),
                  });
                }}
                className="w-20 px-3 py-2 text-center border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
                min="0"
              />
            </div>
          ))}
        </div>
      </div>

      <div className="grid grid-cols-2 gap-4">
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">
            Votos Blancos
          </label>
          <input
            type="number"
            value={formData.votos_blancos}
            onChange={(e) => setFormData({ ...formData, votos_blancos: Number(e.target.value) || 0 })}
            className="w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
            min="0"
          />
        </div>
        <div>
          <label className="block text-sm font-medium text-slate-700 mb-1">
            Votos Nulos
          </label>
          <input
            type="number"
            value={formData.votos_nulos}
            onChange={(e) => setFormData({ ...formData, votos_nulos: Number(e.target.value) || 0 })}
            className="w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
            min="0"
          />
        </div>
      </div>

      <div className="mt-4">
        <label className="block text-sm font-medium text-slate-700 mb-1">
          Votos Impugnados
        </label>
        <input
          type="number"
          value={formData.votos_impugnados}
          onChange={(e) => setFormData({ ...formData, votos_impugnados: Number(e.target.value) || 0 })}
          className="w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
          min="0"
        />
      </div>

      <div className="flex justify-end">
        <button
          type="submit"
          className="px-4 py-2 bg-[#E02020] text-white rounded-md text-sm font-medium hover:bg-[#A01010] disabled:bg-slate-400 disabled:cursor-not-allowed"
        >
          Continuar a Verificación
        </button>
      </div>
    </form>
  );
}