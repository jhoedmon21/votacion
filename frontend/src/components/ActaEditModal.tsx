import { useEffect, useState } from "react";
import type { ActaRecord } from "../types";
import { api } from "../api";
import SideBySideDigitization from "./actas/SideBySideDigitization";

interface ActaEditModalProps {
  acta: ActaRecord | null;
  onClose: () => void;
  onSave: (updatedActa: ActaRecord) => void;
}

export default function ActaEditModal({ acta, onClose, onSave }: ActaEditModalProps) {
  if (!acta) return null;
  if (acta.image_url) {
    return (
      <SideBySideDigitization acta={acta} onClose={onClose} onSave={onSave} mode="edit" />
    );
  }
  return <ActaEditForm acta={acta} onClose={onClose} onSave={onSave} />;
}

/* El formulario vive en su propio componente: los hooks corren siempre en el
   mismo orden. Antes se llamaban después de un `return null` condicional, lo
   que viola las reglas de los hooks y rompía el modal al abrir una acta. */
function ActaEditForm({ acta, onClose, onSave }: {
  acta: ActaRecord;
  onClose: () => void;
  onSave: (a: ActaRecord) => void;
}) {
  const [formData, setFormData] = useState({
    total_electores: acta.total_electores,
    votos_distrital: acta.votos_distrital.map((c) => ({
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

  useEffect(() => {
    const districtSum = formData.votos_distrital.reduce((sum, c) => sum + c.votes, 0);
    const consejeroSum = formData.votos_consejero.reduce((sum, c) => sum + c.votes, 0);
    const regionalSum = formData.votos_regional.reduce((sum, c) => sum + c.votes, 0);
    const totalValidVotes = districtSum + consejeroSum + regionalSum;
    const totalVotes = totalValidVotes + formData.votos_blancos + formData.votos_nulos + formData.votos_impugnados;

    const newErrors: { total_electores?: string; votes_sum?: string } = {};

    if (formData.total_electores < 0) {
      newErrors.total_electores = "El número de electores no puede ser negativo";
    }

    if (formData.total_electores > 0 && totalVotes !== formData.total_electores) {
      newErrors.votes_sum = `La suma de votos (${totalVotes.toLocaleString()}) no coincide con el total de electores (${formData.total_electores.toLocaleString()})`;
    }

    setErrors(newErrors);
  }, [formData]);

  const handleInputChange = (field: keyof typeof formData, value: any) => {
    setFormData(prev => ({ ...prev, [field]: value }));
  };

  const handleCandidateVoteChange = (type: 'distrital' | 'consejero' | 'regional', index: number, votes: number) => {
    setFormData(prev => {
      const newData = { ...prev };
      if (type === 'distrital') {
        newData.votos_distrital = [...prev.votos_distrital];
        newData.votos_distrital[index] = { ...prev.votos_distrital[index], votes };
      } else if (type === 'consejero') {
        newData.votos_consejero = [...prev.votos_consejero];
        newData.votos_consejero[index] = { ...prev.votos_consejero[index], votes };
      } else {
        newData.votos_regional = [...prev.votos_regional];
        newData.votos_regional[index] = { ...prev.votos_regional[index], votes };
      }
      return newData;
    });
  };

  const handleSave = async () => {
    if (Object.keys(errors).length > 0) return;

    setIsSaving(true);
    setSaveMessage(null);

    try {
      const payload = {
        votos_distrital: formData.votos_distrital,
        votos_consejero: formData.votos_consejero,
        votos_regional: formData.votos_regional,
        votos_blancos: formData.votos_blancos,
        votos_nulos: formData.votos_nulos,
        votos_impugnados: formData.votos_impugnados,
        total_electores: formData.total_electores,
        verified: true,
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
        votos_consejero: updatedActa.votos_consejero,
        votos_regional: updatedActa.votos_regional,
        votos_blancos: updatedActa.votos_blancos,
        votos_nulos: updatedActa.votos_nulos,
        votos_impugnados: updatedActa.votos_impugnados,
        total_electores: updatedActa.total_electores,
      };

      setSaveMessage("Acta actualizada correctamente");
      onSave(recordActa);
    } catch (error) {
      setSaveMessage(`Error: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setIsSaving(false);
    }
  };

  const districtSum = formData.votos_distrital.reduce((sum, c) => sum + c.votes, 0);
  const consejeroSum = formData.votos_consejero.reduce((sum, c) => sum + c.votes, 0);
  const regionalSum = formData.votos_regional.reduce((sum, c) => sum + c.votes, 0);
  const totalValidVotes = districtSum + consejeroSum + regionalSum;
  const totalVotes = totalValidVotes + formData.votos_blancos + formData.votos_nulos + formData.votos_impugnados;
  const participationRate = formData.total_electores > 0 ? (totalVotes / formData.total_electores) * 100 : 0;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div className="relative w-[90vw] max-w-[600px] mx-4 bg-white rounded-xl shadow-2xl overflow-hidden">
        <div className="flex items-center justify-between p-4 bg-slate-100 border-b">
          <h2 className="text-xl font-bold">Editar Mesa {acta.numero_mesa}</h2>
          <button onClick={onClose} className="text-gray-500 hover:text-gray-700">✕</button>
        </div>

        <div className="p-6 space-y-6">
          <div>
            <h3 className="font-semibold text-slate-800">Metadatos</h3>
            <div className="space-y-4">
              <div>
                <label className="block text-sm font-medium text-slate-700 mb-1">Total de electores hábiles</label>
                <input
                  type="number"
                  value={formData.total_electores || 0}
                  onChange={(e) => handleInputChange('total_electores', Number(e.target.value) || 0)}
                  className="w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
                  min="0"
                />
                {errors.total_electores && <p className="text-xs text-red-600 mt-1">{errors.total_electores}</p>}
              </div>
            </div>
          </div>

          <div>
            <h3 className="font-semibold text-slate-800">Votos por Lista</h3>
            <div className="space-y-4">
              <div>
                <h4 className="font-medium text-slate-700 mb-2">Votos Distritales</h4>
                {formData.votos_distrital.map((candidate, index) => (
                  <div key={candidate.candidate_id} className="border-t border-slate-200 pt-3">
                    <div className="flex items-center justify-between">
                      <div className="flex-1 min-w-0">
                        <p className="font-medium text-slate-800 truncate">
                          {acta.votos_distrital.find(v => v.candidate_id === candidate.candidate_id)?.name || `Candidato ${candidate.candidate_id}`}
                        </p>
                        <p className="text-xs text-slate-500 truncate">
                          {acta.votos_distrital.find(v => v.candidate_id === candidate.candidate_id)?.party || ''}
                        </p>
                      </div>
                      <div className="w-20">
                        <input
                          type="number"
                          value={candidate.votes}
                          onChange={(e) => handleCandidateVoteChange('distrital', index, Number(e.target.value) || 0)}
                          className="w-full px-3 py-2 text-center border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
                          min="0"
                        />
                      </div>
                    </div>
                  </div>
                ))}
              </div>

              {formData.votos_consejero.length > 0 && (
              <div className="border-t border-slate-200 pt-4">
                <h4 className="font-medium text-slate-700 mb-2">Consejeros Regionales (por provincia)</h4>
                {formData.votos_consejero.map((candidate, index) => (
                  <div key={candidate.candidate_id} className="border-t border-slate-200 pt-3">
                    <div className="flex items-center justify-between">
                      <div className="flex-1 min-w-0">
                        <p className="font-medium text-slate-800 truncate">
                          {acta.votos_consejero?.find(v => v.candidate_id === candidate.candidate_id)?.name || `Candidato ${candidate.candidate_id}`}
                        </p>
                        <p className="text-xs text-slate-500 truncate">
                          {acta.votos_consejero?.find(v => v.candidate_id === candidate.candidate_id)?.party || ''}
                        </p>
                      </div>
                      <div className="w-20">
                        <input
                          type="number"
                          value={candidate.votes}
                          onChange={(e) => handleCandidateVoteChange('consejero', index, Number(e.target.value) || 0)}
                          className="w-full px-3 py-2 text-center border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
                          min="0"
                        />
                      </div>
                    </div>
                  </div>
                ))}
              </div>
              )}

              <div className="border-t border-slate-200 pt-4">
                <h4 className="font-medium text-slate-700 mb-2">Votos Regionales</h4>
                {formData.votos_regional.map((candidate, index) => (
                  <div key={candidate.candidate_id} className="border-t border-slate-200 pt-3">
                    <div className="flex items-center justify-between">
                      <div className="flex-1 min-w-0">
                        <p className="font-medium text-slate-800 truncate">
                          {acta.votos_regional.find(v => v.candidate_id === candidate.candidate_id)?.name || `Candidato ${candidate.candidate_id}`}
                        </p>
                        <p className="text-xs text-slate-500 truncate">
                          {acta.votos_regional.find(v => v.candidate_id === candidate.candidate_id)?.party || ''}
                        </p>
                      </div>
                      <div className="w-20">
                        <input
                          type="number"
                          value={candidate.votes}
                          onChange={(e) => handleCandidateVoteChange('regional', index, Number(e.target.value) || 0)}
                          className="w-full px-3 py-2 text-center border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
                          min="0"
                        />
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>

          <div>
            <h3 className="font-semibold text-slate-800">Otros Votos</h3>
            <div className="space-y-4">
              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="block text-sm font-medium text-slate-700 mb-1">Votos Blancos</label>
                  <input
                    type="number"
                    value={formData.votos_blancos}
                    onChange={(e) => handleInputChange('votos_blancos', Number(e.target.value) || 0)}
                    className="w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
                    min="0"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-slate-700 mb-1">Votos Nulos</label>
                  <input
                    type="number"
                    value={formData.votos_nulos}
                    onChange={(e) => handleInputChange('votos_nulos', Number(e.target.value) || 0)}
                    className="w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
                    min="0"
                  />
                </div>
                <div>
                  <label className="block text-sm font-medium text-slate-700 mb-1">Votos Impugnados</label>
                  <input
                    type="number"
                    value={formData.votos_impugnados}
                    onChange={(e) => handleInputChange('votos_impugnados', Number(e.target.value) || 0)}
                    className="w-full px-3 py-2 border border-slate-300 rounded-md focus:outline-none focus:ring-2 focus:ring-red-500"
                    min="0"
                  />
                </div>
                <div className="col-span-2">
                  <div className="flex items-center space-x-3 pt-2">
                    <div className="flex-1 text-sm text-slate-600">Votos válidos: <span className="font-medium">{totalValidVotes.toLocaleString()}</span></div>
                    <div className="flex-1 text-sm text-slate-600 text-right">Total votos: <span className="font-medium">{totalVotes.toLocaleString()}</span></div>
                  </div>
                </div>
              </div>
            </div>
          </div>

          <div className="border-t border-slate-200 pt-4">
            <h3 className="font-semibold text-slate-800">Resumen de Validación</h3>
            <div className="space-y-3">
              <div className="flex items-center space-x-3">
                <div className="flex-1 text-sm text-slate-600">Electores hábiles:</div>
                <div className="flex-1 text-sm text-slate-600 font-mono text-right">{formData.total_electores ? formData.total_electores.toLocaleString() : '0'}</div>
              </div>
              <div className="flex items-center space-x-3">
                <div className="flex-1 text-sm text-slate-600">Total de votos:</div>
                <div className="flex-1 text-sm text-slate-600 font-mono text-right">{totalVotes.toLocaleString()}</div>
              </div>
              {errors.votes_sum && <div className="flex items-center space-x-3"><div className="flex-1 text-sm text-red-600">Estado:</div><div className="flex-1 text-sm text-red-600 font-medium">{errors.votes_sum}</div></div>}
              {!errors.votes_sum && formData.total_electores > 0 && <div className="flex items-center space-x-3"><div className="flex-1 text-sm text-green-600">Estado:</div><div className="flex-1 text-sm text-green-600 font-medium">Votos válidos ✓</div></div>}
              <div className="flex items-center space-x-3 mt-2">
                <div className="flex-1 text-sm text-slate-600">Participación:</div>
                <div className="flex-1 text-sm text-slate-600 font-mono text-right">{participationRate.toFixed(1)}%</div>
              </div>
            </div>
          </div>

          {saveMessage && (
            <div className={`px-4 py-2 rounded-md text-sm font-medium ${saveMessage.startsWith('Error') ? 'bg-red-100 text-red-800' : 'bg-green-100 text-green-800'}`}>
              {saveMessage}
            </div>
          )}

          <div className="flex justify-end space-x-3">
            <button onClick={onClose} className="px-4 py-2 border border-slate-300 rounded-md text-sm font-medium text-slate-700 hover:bg-slate-50">Cancelar</button>
            <button onClick={handleSave} disabled={isSaving || Object.keys(errors).length > 0} className={`px-4 py-2 bg-[#E02020] text-white rounded-md text-sm font-medium hover:bg-[#A01010] disabled:bg-slate-400 disabled:cursor-not-allowed`}>
              {isSaving ? "Guardando..." : "Guardar Cambios"}
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}