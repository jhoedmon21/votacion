import { useEffect, useState } from "react";
import type { ActaRecord } from "../types";
import { api } from "../api";

interface ActaValidationFormProps {
  acta: ActaRecord;
  onSave: (acta: ActaRecord) => void;
  onCancel: () => void;
}

export default function ActaValidationForm({ acta, onSave, onCancel }: ActaValidationFormProps) {
  const [formData, setFormData] = useState({
    numero_mesa: acta.numero_mesa,
    votos_distrital: acta.votos_distrital.map(v => ({ ...v })),
    votos_regional: acta.votos_regional.map(v => ({ ...v })),
    votos_blancos: acta.votos_blancos,
    votos_nulos: acta.votos_nulos,
    votos_impugnados: acta.votos_impugnados,
    total_electores: acta.total_electores,
  });

  const [errors, setErrors] = useState<{
    numero_mesa?: string;
    total_electores?: string;
    votes_sum?: string;
    [key: string]: string | undefined;
  }>({});

  const [isSaving, setIsSaving] = useState(false);
  const [saveMessage, setSaveMessage] = useState<string | null>(null);

  // Calculate totals for validation
  const calculateTotals = () => {
    const districtSum = formData.votos_distrital.reduce((sum, c) => sum + c.votes, 0);
    const regionalSum = formData.votos_regional.reduce((sum, c) => sum + c.votes, 0);
    const totalValidVotes = districtSum + regionalSum;
    const totalVotes = totalValidVotes + formData.votos_blancos + formData.votos_nulos + formData.votos_impugnados;
    
    return { districtSum, regionalSum, totalValidVotes, totalVotes };
  };

  const { districtSum, regionalSum, totalValidVotes, totalVotes } = calculateTotals();
  const participationRate = formData.total_electores > 0 ? (totalVotes / formData.total_electores) * 100 : 0;

  // Validation
  useEffect(() => {
    const newErrors: { [key: string]: string } = {};
    
    // Validate numero mesa
    if (!formData.numero_mesa.trim() || !/^\d{6}$/.test(formData.numero_mesa)) {
      newErrors.numero_mesa = "El número de mesa debe tener exactamente 6 dígitos";
    }
    
    // Validate total electores
    if (formData.total_electores < 0) {
      newErrors.total_electores = "El número de electores no puede ser negativo";
    }
    
    // Validate vote sum consistency
    if (formData.total_electores > 0 && totalVotes !== formData.total_electores) {
      newErrors.votes_sum = `La suma de votos (${totalVotes.toLocaleString()}) no coincide con el total de electores (${formData.total_electores.toLocaleString()})`;
    }
    
    setErrors(newErrors);
  }, [formData]);

  const handleInputChange = (field: keyof typeof formData, value: any) => {
    setFormData(prev => ({
      ...prev,
      [field]: value
    }));
  };

  const handleCandidateVoteChange = (type: 'distrital' | 'regional', index: number, votes: number) => {
    setFormData(prev => {
      const newData = {...prev};
      if (type === 'distrital') {
        newData.votos_distrital = [...prev.votos_distrital];
        newData.votos_distrital[index] = {...prev.votos_distrital[index], votes};
      } else {
        newData.votos_regional = [...prev.votos_regional];
        newData.votos_regional[index] = {...prev.votos_regional[index], votes};
      }
      return newData;
    });
  };

  const handleSave = async () => {
    // Check if there are validation errors
    const hasErrors = Object.keys(errors).length > 0;
    if (hasErrors) return;

    setIsSaving(true);
    setSaveMessage(null);
    
    try {
      // Prepare acta for saving
      const actaToSave = {
        numero_mesa: formData.numero_mesa,
        votos_distrital: formData.votos_distrital,
        votos_regional: formData.votos_regional,
        votos_blancos: formData.votos_blancos,
        votos_nulos: formData.votos_nulos,
        votos_impugnados: formData.votos_impugnados,
        total_electores: formData.total_electores,
        ocr_confidence: acta.ocr_confidence, // Keep original OCR confidence
        image_url: acta.image_url, // Keep original image URL
        verified: true,
      };
      
      // Save the acta using the API
      const savedActa = await api.createActa(actaToSave);
      
      // Convert the saved acta to ActaRecord format for the onSave callback
      const recordActa: ActaRecord = {
        id: savedActa.id,
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
        votos_regional: savedActa.votos_regional,
        votos_blancos: savedActa.votos_blancos,
        votos_nulos: savedActa.votos_nulos,
        votos_impugnados: savedActa.votos_impugnados,
        total_electores: savedActa.total_electores,
      };
      
      setSaveMessage("Acta guardada correctamente");
      onSave(recordActa);
    } catch (error) {
      setSaveMessage(`Error: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setIsSaving(false);
    }
  };

  // Determine confidence levels for highlighting (simplified)
  const getConfidenceClass = (field: string, value: any): string => {
    // In a real app, we would get confidence scores from OCR
    // For now, we'll highlight if validation fails
    if (errors[field as keyof typeof errors]) {
      return "bg-red-50 border-red-200";
    }
    // Special case for vote sum
    if (field === 'votes_sum' && errors.votes_sum) {
      return "bg-red-50 border-red-200";
    }
    return "";
  };

  return (
    <div className="space-y-6">
      {/* Validation Messages */}
      {saveMessage && (
        <div className={`px-4 py-2 rounded-md text-sm font-medium ${
          saveMessage.startsWith('Error') ? 'bg-red-100 text-red-800' : 'bg-green-100 text-green-800'
        }`}>
          {saveMessage}
        </div>
      )}

      {/* Side-by-side layout */}
      <div className="grid gap-6 md:grid-cols-2">
        {/* Left: Image Viewer */}
        <div className="border rounded-lg p-4 bg-white shadow-sm h-full">
          <h3 className="font-semibold text-slate-800 mb-4">Visor de Acta</h3>
          {acta.image_url ? (
            <div className="relative h-[400px]">
              <div
                className="absolute inset-0 flex items-center justify-center bg-slate-50"
              >
                <img
                  src={acta.image_url}
                  alt={`Acta mesa ${acta.numero_mesa}`}
                  className="max-h-full max-w-full object-contain"
                />
              </div>
              <div className="flex items-center justify-between p-2 bg-slate-100 rounded-t-lg">
                <button
                  onClick={() => {/* Zoom in logic */}}
                  className="text-xs bg-gray-200 px-2 py-1 rounded hover:bg-gray-300"
                >
                  + Zoom
                </button>
                <button
                  onClick={() => {/* Zoom out logic */}}
                  className="text-xs bg-gray-200 px-2 py-1 rounded hover:bg-gray-300"
                >
                  - Zoom
                </button>
                <button
                  onClick={() => {/* Rotate logic */}}
                  className="text-xs bg-gray-200 px-2 py-1 rounded hover:bg-gray-300"
                >
                  Rotar
                </button>
              </div>
            </div>
          ) : (
            <div className="h-[400px] flex items-center justify-center bg-slate-50">
              <p className="text-slate-500">No hay imagen de acta disponible</p>
            </div>
          )}
        </div>

        {/* Right: Editable Form */}
        <div className="border rounded-lg p-4 bg-white shadow-sm h-full overflow-y-auto">
          <h3 className="font-semibold text-slate-800 mb-4">Formulario de Verificación</h3>
          <form onSubmit={(e) => e.preventDefault()} className="space-y-5">
            {/* Identification Section */}
            <div className="border-b pb-3">
              <h4 className="font-medium text-slate-700 mb-2">Identificación</h4>
              <div className="space-y-3">
                <div>
                  <label className="block text-sm font-medium text-slate-700 mb-1">
                    Número de Mesa
                  </label>
                  <input
                    type="text"
                    value={formData.numero_mesa}
                    onChange={(e) => handleInputChange('numero_mesa', e.target.value)}
                    className={`w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 ${
                      errors.numero_mesa ? "border-red-500" : ""
                    }`}
                  />
                  {errors.numero_mesa && (
                    <p className="text-xs text-red-600 mt-1">{errors.numero_mesa}</p>
                  )}
                </div>
                <div>
                  <label className="block text-sm font-medium text-slate-700 mb-1">
                    Total de Electores Hábiles
                  </label>
                  <input
                    type="number"
                    value={formData.total_electores}
                    onChange={(e) => handleInputChange('total_electores', Number(e.target.value) || 0)}
                    className={`w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 ${
                      errors.total_electores ? "border-red-500" : ""
                    }`}
                    min="0"
                  />
                  {errors.total_electores && (
                    <p className="text-xs text-red-600 mt-1">{errors.total_electores}</p>
                  )}
                </div>
              </div>
            </div>

            {/* Votos Section */}
            <div className="border-b pb-3">
              <h4 className="font-medium text-slate-700 mb-2">Votos por Lista</h4>
              
              <div className="space-y-4">
                <div>
                  <h5 className="font-medium text-slate-700 mb-2">Votos Distritales</h5>
                  <div className="space-y-2">
                    {acta.votos_distrital.map((originalCandidate, index) => (
                      <div key={originalCandidate.candidate_id} className="border-t border-slate-200 pt-3">
                        <div className="flex items-center justify-between">
                          <div className="flex-1 min-w-0">
                            <p className="font-medium text-slate-800 truncate">
                              {originalCandidate.name}
                            </p>
                            <p className="text-xs text-slate-500 truncate">
                              {originalCandidate.party}
                            </p>
                          </div>
                          <div className="w-20">
                            <input
                              type="number"
                              value={formData.votos_distrital[index].votes}
                              onChange={(e) => handleCandidateVoteChange('distrital', index, Number(e.target.value) || 0)}
                              className={`w-full px-3 py-2 text-center border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 ${
                                // Highlight if this specific field has error (simplified)
                                errors[`voto_distrital_${index}`] ? "border-red-500" : ""
                              }`}
                              min="0"
                            />
                          </div>
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
                
                <div className="border-t border-slate-200 pt-4">
                  <h5 className="font-medium text-slate-700 mb-2">Votos Regionales</h5>
                  <div className="space-y-2">
                    {acta.votos_regional.map((originalCandidate, index) => (
                      <div key={originalCandidate.candidate_id} className="border-t border-slate-200 pt-3">
                        <div className="flex items-center justify-between">
                          <div className="flex-1 min-w-0">
                            <p className="font-medium text-slate-800 truncate">
                              {originalCandidate.name}
                            </p>
                            <p className="text-xs text-slate-500 truncate">
                              {originalCandidate.party}
                            </p>
                          </div>
                          <div className="w-20">
                            <input
                              type="number"
                              value={formData.votos_regional[index].votes}
                              onChange={(e) => handleCandidateVoteChange('regional', index, Number(e.target.value) || 0)}
                              className={`w-full px-3 py-2 text-center border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 ${
                                errors[`voto_regional_${index}`] ? "border-red-500" : ""
                              }`}
                              min="0"
                            />
                          </div>
                        </div>
                      </div>
                    ))}
                  </div>
                </div>
              </div>
            </div>

            {/* Otros Votos Section */}
            <div className="border-b pb-3">
              <h4 className="font-medium text-slate-700 mb-2">Otros Votos</h4>
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-slate-700 mb-1">
                    Votos Blancos
                  </label>
                  <input
                    type="number"
                    value={formData.votos_blancos}
                    onChange={(e) => handleInputChange('votos_blancos', Number(e.target.value) || 0)}
                    className={`w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 ${
                      errors.votos_blancos ? "border-red-500" : ""
                    }`}
                    min="0"
                  />
                  {errors.votos_blancos && (
                    <p className="text-xs text-red-600 mt-1">{errors.votos_blancos}</p>
                  )}
                </div>
                <div>
                  <label className="block text-sm font-medium text-slate-700 mb-1">
                    Votos Nulos
                  </label>
                  <input
                    type="number"
                    value={formData.votos_nulos}
                    onChange={(e) => handleInputChange('votos_nulos', Number(e.target.value) || 0)}
                    className={`w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 ${
                      errors.votos_nulos ? "border-red-500" : ""
                    }`}
                    min="0"
                  />
                  {errors.votos_nulos && (
                    <p className="text-xs text-red-600 mt-1">{errors.votos_nulos}</p>
                  )}
                </div>
              </div>
              
              <div className="mt-4">
                <label className="block text-sm font-medium text-slate-700 mb-1">
                  Votos Impugnados
                </label>
                <input
                  type="number"
                  value={formData.votos_impugnados}
                  onChange={(e) => handleInputChange('votos_impugnados', Number(e.target.value) || 0)}
                  className={`w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-blue-500 ${
                    errors.votos_impugnados ? "border-red-500" : ""
                  }`}
                    min="0"
                  />
                  {errors.votos_impugnados && (
                    <p className="text-xs text-red-600 mt-1">{errors.votos_impugnados}</p>
                  )}
              </div>
            </div>

            {/* Validation Summary Section */}
            <div className="border-t border-slate-200 pt-4">
              <h4 className="font-medium text-slate-700 mb-2">Resumen de Validación</h4>
              <div className="space-y-3">
                <div className="flex items-center space-x-3">
                  <div className="flex-1 text-sm text-slate-600">
                    Votos válidos distritales:
                  </div>
                  <div className="flex-1 text-sm text-slate-600 font-mono text-right">
                    {districtSum.toLocaleString()}
                  </div>
                </div>
                <div className="flex items-center space-x-3">
                  <div className="flex-1 text-sm text-slate-600">
                    Votos válidos regionales:
                  </div>
                  <div className="flex-1 text-sm text-slate-600 font-mono text-right">
                    {regionalSum.toLocaleString()}
                  </div>
                </div>
                <div className="flex items-center space-x-3">
                  <div className="flex-1 text-sm text-slate-600">
                    Total votos válidos:
                  </div>
                  <div className="flex-1 text-sm text-slate-600 font-mono text-right">
                    {totalValidVotes.toLocaleString()}
                  </div>
                </div>
                <div className="flex items-center space-x-3">
                  <div className="flex-1 text-sm text-slate-600">
                    Blancos + Nulos + Impugnados:
                  </div>
                  <div className="flex-1 text-sm text-slate-600 font-mono text-right">
                    {(formData.votos_blancos + formData.votos_nulos + formData.votos_impugnados).toLocaleString()}
                  </div>
                </div>
                <div className="flex items-center space-x-3">
                  <div className="flex-1 text-sm text-slate-600">
                    Total de votos emitidos:
                  </div>
                  <div className="flex-1 text-sm text-slate-600 font-mono text-right">
                    {totalVotes.toLocaleString()}
                  </div>
                </div>
                {errors.votes_sum && (
                  <div className="flex items-center space-x-3">
                    <div className="flex-1 text-sm text-red-600">
                      Estado:
                    </div>
                    <div className="flex-1 text-sm text-red-600 font-medium">
                      {errors.votes_sum}
                    </div>
                  </div>
                )}
                {!errors.votes_sum && formData.total_electores > 0 && (
                  <div className="flex items-center space-x-3">
                    <div className="flex-1 text-sm text-green-600">
                      Estado:
                    </div>
                    <div className="flex-1 text-sm text-green-600 font-medium">
                      Votos válidos ✓
                    </div>
                  </div>
                )}
                <div className="flex items-center space-x-3 mt-2">
                  <div className="flex-1 text-sm text-slate-600">
                    Participación:
                  </div>
                  <div className="flex-1 text-sm text-slate-600 font-mono text-right">
                    {participationRate.toFixed(1)}%
                  </div>
                </div>
              </div>
            </div>

            {/* Action Buttons */}
            <div className="mt-6 flex justify-end space-x-3">
              <button
                onClick={onCancel}
                className="px-4 py-2 border border-slate-300 rounded-md text-sm font-medium text-slate-700 hover:bg-slate-50"
              >
                Cancelar
              </button>
              <button
                onClick={handleSave}
                disabled={isSaving || Object.keys(errors).length > 0}
                className={`px-4 py-2 bg-[#002B66] text-white rounded-md text-sm font-medium hover:bg-[#003366] disabled:bg-slate-400 disabled:cursor-not-allowed`}
              >
                {isSaving ? "Guardando..." : "Confirmar y Guardar Acta"}
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
  );
}