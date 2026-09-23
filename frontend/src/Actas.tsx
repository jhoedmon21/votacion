import { useCallback, useEffect, useRef, useState } from "react";
import { api } from "./api";
import type { ActaRecord, CandidateVotes } from "./types";
import ActaDetailModal from "./components/ActaDetailModal";
import ActaEditModal from "./components/ActaEditModal";
import ActaIngresoForm from "./components/ActaIngresoForm";
import FormularioActaElectoral from "./components/FormularioActaElectoral";
import FormularioPersonero from "./components/FormularioPersonero";
import GestionActas from "./components/GestionActas";
import { Alerta, Boton } from "./components/ui";

export default function Actas() {
  const [review, setReview] = useState<ActaRecord[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [uploading, setUploading] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [selectedActa, setSelectedActa] = useState<ActaRecord | null>(null);
  const [actaToEdit, setActaToEdit] = useState<ActaRecord | null>(null);
  const [mostrarIngreso, setMostrarIngreso] = useState(false);
  const [mostrarOficial, setMostrarOficial] = useState(false);
  const [mostrarRapido, setMostrarRapido] = useState(false);
  const [mesaCargar, setMesaCargar] = useState<string | undefined>(undefined);
  const fileRef = useRef<HTMLInputElement>(null);

  const load = useCallback(() => {
    api
      .reviewList()
      .then(setReview)
      .catch((e) => setError(String(e)));
  }, []);

  useEffect(load, [load]);

  const onUpload = async () => {
    const file = fileRef.current?.files?.[0];
    if (!file) return;
    setUploading(true);
    setMessage(null);
    try {
      const res = await api.process(file);
      setMessage(
        `Acta ${res.numero_mesa} procesada (confianza ${(res.ocr_confidence * 100).toFixed(0)}%)`
      );
      load();
    } catch (e) {
      setMessage(`Error: ${e instanceof Error ? e.message : String(e)}`);
    } finally {
      setUploading(false);
      // Allow re-selecting the same file
      if (fileRef.current) fileRef.current.value = "";
    }
  };

  const approve = async (a: ActaRecord) => {
    const district = a.votos_distrital.map(
      (c): CandidateVotes => ({ candidate_id: c.candidate_id, votes: c.votes })
    );
    const regional = a.votos_regional.map(
      (c): CandidateVotes => ({ candidate_id: c.candidate_id, votes: c.votes })
    );
    await api.updateActa(a.id, {
      votos_distrital: district,
      votos_regional: regional,
      votos_blancos: a.votos_blancos,
      votos_nulos: a.votos_nulos,
      votos_impugnados: a.votos_impugnados,
      verified: true,
    });
    load();
  };

  return (
    <div>
      {/* Gestión territorial: filtros en cascada + KPIs + tabla paginada */}
      <div className="mb-8">
        <GestionActas
          onCargarMesa={(mesa) => {
            setMesaCargar(mesa);
            setMostrarOficial(true);
            setMostrarIngreso(false);
            setMostrarRapido(false);
          }}
        />
      </div>

      {/* Header with two buttons: Cargar Acta and Acta */}
      <div className="mb-6">
        <div className="flex flex-wrap items-center justify-between gap-4">
          {/* Button 1: Cargar Acta */}
          <div className="flex items-center space-x-3">
            <div className="relative">
              <button
                onClick={() => fileRef.current?.click()}
                disabled={uploading}
                className="w-full px-6 py-3 bg-[#002B66] text-white rounded-lg text-base font-medium hover:bg-[#003366] transition-all duration-200 flex items-center justify-center space-x-2 shadow-md hover:shadow-lg disabled:opacity-60"
              >
                {uploading ? "⏳ Procesando…" : "📄 Cargar Acta"}
              </button>
              <input
                ref={fileRef}
                type="file"
                accept="image/*"
                onChange={onUpload}
                className="hidden"
              />
            </div>
          </div>
          
          {/* Ingresar acta (plantilla dinámica) */}
          <Boton
            variante="exito"
            onClick={() => {
              setMostrarIngreso((v) => !v);
              setMostrarOficial(false);
              setMostrarRapido(false);
            }}
          >
            {mostrarIngreso ? "✕ Cerrar" : "✏️ Ingresar acta"}
          </Boton>

          {/* Acta ONPE oficial */}
          <Boton
            onClick={() => {
              setMostrarOficial((v) => !v);
              setMostrarIngreso(false);
              setMostrarRapido(false);
            }}
          >
            {mostrarOficial ? "✕ Cerrar" : "📋 Acta ONPE"}
          </Boton>

          {/* Registro rápido del personero */}
          <Boton
            variante="exito"
            onClick={() => {
              setMostrarRapido((v) => !v);
              setMostrarIngreso(false);
              setMostrarOficial(false);
            }}
          >
            {mostrarRapido ? "✕ Cerrar" : "🧾 Registro rápido"}
          </Boton>

          {/* Button 3: Acta */}
          <div className="flex items-center space-x-3">
            <button
              onClick={() => {
                // Focus on the actas table section
                const element = document.getElementById('actas-table-section');
                if (element) {
                  element.scrollIntoView({ behavior: 'smooth', block: 'center' });
                  // Brief highlight effect
                  const originalBg = element.style.backgroundColor;
                  element.style.backgroundColor = '#f0f9ff';
                  setTimeout(() => {
                    element.style.backgroundColor = originalBg;
                  }, 2000);
                }
              }}
              className="w-full px-6 py-3 bg-gray-100 text-gray-800 rounded-lg text-base font-medium hover:bg-gray-200 transition-all duration-200 flex items-center justify-center space-x-2 shadow-md hover:shadow-lg"
            >
              📋 Acta
              <span className="ml-2 text-xs bg-blue-100 text-blue-800 rounded-full px-2 py-0.5">
                {review.length}
              </span>
            </button>
          </div>
          
          {message && (
            <Alerta tono={message.startsWith("Error") ? "error" : "exito"}>
              {message}
            </Alerta>
          )}
        </div>
      </div>

      {error && <div className="error">Error: {error}</div>}

      {mostrarIngreso && (
        <div className="mb-8 rounded-2xl border border-emerald-200 bg-slate-50 p-6">
          <ActaIngresoForm
            onGuardada={() => {
              setMostrarIngreso(false);
              load();
            }}
            onCancelar={() => setMostrarIngreso(false)}
          />
        </div>
      )}

      {mostrarOficial && (
        <div className="mb-8 rounded-2xl border-2 border-[#002B66] bg-slate-50 p-6">
          <FormularioActaElectoral
            key={mesaCargar ?? "oficial"}
            mesaInicial={mesaCargar}
            onGuardada={() => {
              setMostrarOficial(false);
              setMesaCargar(undefined);
              load();
            }}
            onCancelar={() => {
              setMostrarOficial(false);
              setMesaCargar(undefined);
            }}
          />
        </div>
      )}

      {mostrarRapido && (
        <div className="mb-8 rounded-2xl border-2 border-emerald-700 bg-slate-50 p-6">
          <FormularioPersonero
            onGuardada={() => {
              setMostrarRapido(false);
              load();
            }}
            onCancelar={() => setMostrarRapido(false)}
          />
        </div>
      )}

      <h2 id="actas-table-section" className="mb-4">Actas en revisión ({review.length})</h2>
      {review.length === 0 ? (
        <p style={{ color: "var(--muted)" }} className="text-center py-8">
          No hay actas pendientes.
        </p>
      ) : (
        <div className="overflow-x-auto">
          <table className="table w-full">
            <thead>
              <tr>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Mesa
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Confianza
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Blancos
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Nulos
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Impugnados
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Estado
                </th>
                <th className="px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase tracking-wider">
                  Acciones
                </th>
              </tr>
            </thead>
            <tbody>
              {review.map((a) => (
                <tr key={a.id} className="border-b hover:bg-gray-50">
                  <td className="px-6 py-4 text-left text-sm font-medium text-gray-900">
                    {a.numero_mesa}
                  </td>
                  <td className="px-6 py-4 text-left text-sm text-gray-900">
                    {((a.ocr_confidence ?? 0) * 100).toFixed(0)}%
                  </td>
                  <td className="px-6 py-4 text-left text-sm text-gray-900">
                    {a.votos_blancos}
                  </td>
                  <td className="px-6 py-4 text-left text-sm text-gray-900">
                    {a.votos_nulos}
                  </td>
                  <td className="px-6 py-4 text-left text-sm text-gray-900">
                    {a.votos_impugnados}
                  </td>
                  <td className="px-6 py-4 text-left text-sm text-gray-900">
                    <span className={`px-2 py-1 rounded-full text-xs font-medium ${
                      a.status === 'processed'
                        ? 'bg-green-100 text-green-800'
                        : a.status === 'requires_review'
                        ? 'bg-yellow-100 text-yellow-800'
                        : 'bg-gray-100 text-gray-800'
                    }`}>
                      {a.status === 'processed' ? 'Procesada' : a.status === 'requires_review' ? 'En revisión' : a.status}
                    </span>
                  </td>
                  <td className="px-6 py-4 text-left text-sm space-x-2">
                    <button
                      onClick={() => approve(a)}
                      className="px-3 py-1.5 bg-blue-100 text-blue-800 rounded text-xs font-medium hover:bg-blue-200 transition-colors"
                    >
                      Validar
                    </button>
                    <button
                      onClick={() => setSelectedActa(a)}
                      className="px-3 py-1.5 bg-blue-50 text-blue-800 rounded text-xs font-medium hover:bg-blue-100 transition-colors"
                    >
                      Ver
                    </button>
                    <button
                      onClick={() => setActaToEdit(a)}
                      className="px-3 py-1.5 bg-green-50 text-green-800 rounded text-xs font-medium hover:bg-green-100 transition-colors"
                    >
                      Editar
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
      <ActaDetailModal acta={selectedActa} onClose={() => setSelectedActa(null)} />
      <ActaEditModal 
        acta={actaToEdit} 
        onClose={() => setActaToEdit(null)} 
        onSave={(updatedActa) => {
          // Update the review list with the modified acta
          setReview(prev => prev.map(acta => 
            acta.id === updatedActa.id ? updatedActa : acta
          ));
          setActaToEdit(null);
        }} 
      />
    </div>
  );
}