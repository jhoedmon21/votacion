import type { ActaRecord } from "../types";
import SideBySideDigitization from "./actas/SideBySideDigitization";

interface ActaEditModalProps {
  acta: ActaRecord | null;
  onClose: () => void;
  onSave: (updatedActa: ActaRecord) => void;
}

export default function ActaEditModal({ acta, onClose, onSave }: ActaEditModalProps) {
  if (!acta) return null;
  /* SIEMPRE el modal lado-a-lado: es el único que muestra todos los niveles
     (distrital, provincial, consejeros y regional) y trae la carga/cambio de
     imagen del acta incluso cuando se registró sin foto. Antes las actas sin
     imagen caían en un formulario simple sin foto y sin nivel provincial. */
  return (
    <SideBySideDigitization acta={acta} onClose={onClose} onSave={onSave} mode="edit" />
  );
}
