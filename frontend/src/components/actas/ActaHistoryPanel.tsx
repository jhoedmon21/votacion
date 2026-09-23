import { useEffect, useState } from "react";
import type { ActaRecord } from "../../types";
import { api } from "../../api";
import { Card } from "../ui";

interface ActaHistoryEntry {
  id: number;
  acta_id: number;
  numero_mesa: string;
  accion: string;
  usuario_id: number | null;
  usuario_email: string;
  usuario_rol: string;
  ip: string | null;
  valores_anteriores: Record<string, unknown>;
  valores_nuevos: Record<string, unknown>;
  motivo: string | null;
  created_at: string;
}

interface ActaHistoryPanelProps {
  acta: ActaRecord | null;
  onClose: () => void;
}

export default function ActaHistoryPanel({ acta, onClose }: ActaHistoryPanelProps) {
  const [history, setHistory] = useState<ActaHistoryEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [expandedId, setExpandedId] = useState<number | null>(null);

  useEffect(() => {
    if (!acta) return;
    loadHistory();
  }, [acta]);

  const loadHistory = async () => {
    if (!acta) return;
    setLoading(true);
    setError(null);
    try {
      // Try to get from digitador auditoria endpoint first
      const data = await api.digitadorAuditoria(acta.id);
      setHistory(data as ActaHistoryEntry[]);
    } catch (e) {
      // If not DIGITADOR_GLOBAL, try a generic history endpoint
      try {
        const res = await fetch(`${api.actas}/${acta.id}/history`, {
          headers: { Authorization: `Bearer ${api.sesionGuardada()?.token}` }
        });
        if (res.ok) {
          const data = await res.json();
          setHistory(data);
        } else {
          setHistory([]);
        }
      } catch {
        setHistory([]);
      }
    } finally {
      setLoading(false);
    }
  };

  const formatDate = (iso: string) => {
    try {
      return new Date(iso).toLocaleString("es-PE", {
        day: "2-digit", month: "2-digit", year: "numeric",
        hour: "2-digit", minute: "2-digit", second: "2-digit"
      });
    } catch {
      return iso;
    }
  };

  const getActionLabel = (action: string) => {
    const labels: Record<string, string> = {
      CREAR: "Creación",
      MODIFICAR: "Modificación",
      VALIDAR: "Validación",
      CERRAR: "Cierre",
      OBSERVAR: "Observación",
      REABRIR: "Reapertura",
    };
    return labels[action] || action;
  };

  const getActionColor = (action: string) => {
    const colors: Record<string, string> = {
      CREAR: "bg-emerald-100 text-emerald-800",
      MODIFICAR: "bg-red-100 text-red-800",
      VALIDAR: "bg-amber-100 text-amber-800",
      CERRAR: "bg-slate-100 text-slate-800",
      OBSERVAR: "bg-red-100 text-red-800",
      REABRIR: "bg-indigo-100 text-indigo-800",
    };
    return colors[action] || "bg-gray-100 text-gray-800";
  };

  const diffObjects = (old: Record<string, unknown>, neu: Record<string, unknown>) => {
    const keys = new Set([...Object.keys(old), ...Object.keys(neu)]);
    const changes: Array<{ key: string; old: unknown; new: unknown }> = [];
    for (const key of keys) {
      const o = old[key];
      const n = neu[key];
      if (JSON.stringify(o) !== JSON.stringify(n)) {
        changes.push({ key, old: o, new: n });
      }
    }
    return changes;
  };

  if (!acta) return null;

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50">
      <div className="relative w-[90vw] max-w-[1000px] h-[90vh] mx-4 bg-white rounded-xl shadow-2xl overflow-hidden flex flex-col">
        <div className="flex items-center justify-between p-4 bg-slate-100 border-b sticky top-0 z-10">
          <h2 className="text-xl font-bold text-[#E02020]">
            Historial de Cambios - Mesa {acta.numero_mesa}
          </h2>
          <button onClick={onClose} className="text-gray-500 hover:text-gray-700 p-2">✕</button>
        </div>

        {error && <Alerta tono="error" className="m-4">{error}</Alerta>}

        <div className="flex-1 overflow-y-auto p-4">
          {loading ? (
            <div className="text-center text-slate-500 py-12">Cargando historial...</div>
          ) : history.length === 0 ? (
            <div className="text-center text-slate-500 py-12">
              <div className="text-4xl mb-2">📋</div>
              <p>No hay historial de cambios registrado para esta acta</p>
              <p className="text-sm mt-1">El historial se registra automáticamente en cada modificación</p>
            </div>
          ) : (
            <div className="space-y-4">
              {history.map((entry) => {
                const changes = diffObjects(entry.valores_anteriores, entry.valores_nuevos);
                const isExpanded = expandedId === entry.id;

                return (
                  <Card key={entry.id} className="overflow-hidden" variant="outline">
                    <div
                      className="flex items-center justify-between p-4 cursor-pointer hover:bg-slate-50 transition-colors"
                      onClick={() => setExpandedId(isExpanded ? null : entry.id)}
                    >
                      <div className="flex items-center gap-4">
                        <span className={`px-2.5 py-1 rounded-full text-xs font-bold ${getActionColor(entry.accion)}`}>
                          {getActionLabel(entry.accion)}
                        </span>
                        <div>
                          <p className="font-medium text-slate-800">{entry.usuario_email}</p>
                          <p className="text-xs text-slate-500">{entry.usuario_rol} • {formatDate(entry.created_at)}</p>
                        </div>
                        {entry.motivo && (
                          <span className="px-2 py-1 bg-slate-100 text-slate-600 text-xs rounded max-w-xs truncate block">
                            {entry.motivo}
                          </span>
                        )}
                      </div>
                      <span className="text-slate-400 transition-transform" style={{ transform: isExpanded ? "rotate(180deg)" : "" }}>
                        ▼
                      </span>
                    </div>

                    {isExpanded && changes.length > 0 && (
                      <div className="border-t border-slate-200 bg-slate-50 p-4">
                        <h4 className="font-semibold text-slate-800 mb-3">Detalle de Cambios ({changes.length})</h4>
                        <div className="space-y-3">
                          {changes.map((change, i) => (
                            <div key={i} className="bg-white border border-slate-200 rounded-lg p-3">
                              <p className="text-xs font-bold text-slate-600 uppercase tracking-wider mb-2">{change.key}</p>
                              <div className="grid grid-cols-2 gap-4 text-sm">
                                <div>
                                  <p className="text-xs text-red-600 font-medium mb-1">Valor Anterior</p>
                                  <pre className="text-xs bg-red-50 p-2 rounded font-mono whitespace-pre-wrap max-h-24 overflow-auto">
                                    {JSON.stringify(change.old, null, 2) || "—"}
                                  </pre>
                                </div>
                                <div>
                                  <p className="text-xs text-emerald-600 font-medium mb-1">Valor Nuevo</p>
                                  <pre className="text-xs bg-emerald-50 p-2 rounded font-mono whitespace-pre-wrap max-h-24 overflow-auto">
                                    {JSON.stringify(change.new, null, 2) || "—"}
                                  </pre>
                                </div>
                              </div>
                            </div>
                          ))}
                        </div>
                      </div>
                    )}

                    {isExpanded && changes.length === 0 && entry.accion !== "CREAR" && (
                      <div className="border-t border-slate-200 bg-slate-50 p-4 text-center text-slate-500 text-sm">
                        Sin cambios de valores detectados (posible cambio de estado o metadatos)
                      </div>
                    )}
                  </Card>
                );
              })}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}