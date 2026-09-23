/* ==========================================================================
 * electoral_logic.js — Lógica de cuadre de actas, cálculo electoral y
 *                      gráficos Chart.js para el sistema de cómputo de
 *                      la Región Arequipa.
 *
 * Dependencias: Chart.js (CDN v4.x)
 * ========================================================================== */

const ELECTORAL = window.ELECTORAL || {};

/* -----------------------------------------------------------------------
 * 1. CANDIDATOS — Carga y consulta del dataset JSON
 * ----------------------------------------------------------------------- */
ELECTORAL.candidatos = {};

ELECTORAL.candidatos.cargar = async function (ruta) {
    ruta = ruta || '/candidatos_arequipa.json';
    try {
        const r = await fetch(ruta);
        const data = await r.json();
        ELECTORAL.candidatos.data = data;
        return data;
    } catch (e) {
        console.warn('No se pudo cargar candidatos_arequipa.json:', e);
        return null;
    }
};

ELECTORAL.candidatos.porNivel = function (nivel) {
    if (!ELECTORAL.candidatos.data) return [];
    return (ELECTORAL.candidatos.data.ambitos || []).filter(a => a.nivel === nivel);
};

ELECTORAL.candidatos.porUbigeo = function (ubigeo) {
    if (!ELECTORAL.candidatos.data) return null;
    return (ELECTORAL.candidatos.data.ambitos || []).find(a => a.ubigeo === ubigeo) || null;
};

ELECTORAL.candidatos.organizaciones = function (ubigeo) {
    const ambito = ELECTORAL.candidatos.porUbigeo(ubigeo);
    return ambito ? ambito.organizaciones : [];
};

/* -----------------------------------------------------------------------
 * 2. VALIDACIÓN ONPE — Regla R1 de consistencia aritmética
 * ----------------------------------------------------------------------- */
ELECTORAL.validarActa = function (votos) {
    /* votos: { organizaciones: {nombre: votos}, blancos, nulos, impugnados, total }
     *
     * Retorna: { consistente, diferencia, suma, detalle }
     */
    const sumaOrg = Object.values(votos.organizaciones || {}).reduce((a, b) => a + (parseInt(b, 10) || 0), 0);
    const blancos = parseInt(votos.blancos, 10) || 0;
    const nulos = parseInt(votos.nulos, 10) || 0;
    const impugnados = parseInt(votos.impugnados, 10) || 0;
    const totalDeclarado = parseInt(votos.total, 10) || 0;

    const sumaTotal = sumaOrg + blancos + nulos + impugnados;
    const diferencia = totalDeclarado - sumaTotal;
    const consistente = totalDeclarado > 0 && diferencia === 0;

    return {
        consistente,
        diferencia,
        sumaOrg,
        blancos,
        nulos,
        impugnados,
        sumaTotal,
        totalDeclarado,
        detalle: consistente
            ? 'ACTA CONSISTENTE — La suma cuadra correctamente.'
            : totalDeclarado === 0
                ? 'Complete la digitación del acta.'
                : `INCONSISTENTE — Diferencia: ${diferencia > 0 ? '+' : ''}${diferencia} votos. ` +
                  `Σ votos (${sumaOrg}) + B (${blancos}) + N (${nulos}) + I (${impugnados}) = ${sumaTotal}, ` +
                  `pero el acta declara ${totalDeclarado}.`,
    };
};

ELECTORAL.validarTope = function (votos, electoresHabiles) {
    const total = parseInt(votos.total, 10) || 0;
    const habiles = parseInt(electoresHabiles, 10) || 1;
    return {
        ok: total <= habiles,
        exceso: Math.max(0, total - habiles),
        participacion: habiles > 0 ? (total / habiles * 100) : 0,
    };
};

/* -----------------------------------------------------------------------
 * 3. CÁLCULO DE PORCENTAJES Y ESTADÍSTICAS
 * ----------------------------------------------------------------------- */
ELECTORAL.calcular = function (data) {
    /* data: { organizaciones: [{nombre, votos}], blancos, nulos, impugnados, totalVotantes }
     *
     * Retorna: { ranking, totalValidos, totalVotos, participacion, distribucion }
     */
    const totalVotantes = parseInt(data.totalVotantes, 10) || 0;
    const blancos = parseInt(data.blancos, 10) || 0;
    const nulos = parseInt(data.nulos, 10) || 0;
    const impugnados = parseInt(data.impugnados, 10) || 0;
    const orgVotos = (data.organizaciones || []).map(o => ({
        nombre: o.nombre,
        votos: parseInt(o.votos, 10) || 0,
        logo: o.logo_url || null,
        foto: o.foto_url || null,
    }));
    const totalValidos = orgVotos.reduce((s, o) => s + o.votos, 0);
    const totalVotos = totalValidos + blancos + nulos + impugnados;

    const ranking = orgVotos
        .map(o => ({
            ...o,
            porcentaje: totalValidos > 0 ? (o.votos / totalValidos * 100) : 0,
            porcentajeGeneral: totalVotantes > 0 ? (o.votos / totalVotantes * 100) : 0,
        }))
        .sort((a, b) => b.votos - a.votos);

    return {
        ranking,
        totalValidos,
        totalBlancos: blancos,
        totalNulos: nulos,
        totalImpugnados: impugnados,
        totalVotos,
        totalVotantes,
        participacion: totalVotantes > 0 ? (totalVotos / totalVotantes * 100) : 0,
        distribucion: [
            { label: 'Votos Válidos', value: totalValidos, color: '#12B76A' },
            { label: 'Votos en Blanco', value: blancos, color: '#F79009' },
            { label: 'Votos Nulos', value: nulos, color: '#F04438' },
            { label: 'Votos Impugnados', value: impugnados, color: '#475569' },
        ].filter(d => d.value > 0),
    };
};

/* -----------------------------------------------------------------------
 * 4. GRÁFICOS CHART.JS
 * ----------------------------------------------------------------------- */
ELECTORAL.graficos = {};

ELECTORAL.graficos.crearBarChart = function (canvasId, ranking, maxBarras) {
    const ctx = document.getElementById(canvasId);
    if (!ctx) return;
    const top = ranking.slice(0, maxBarras || 12);
    const colores = ['#002B66','#0056B3','#12B76A','#F79009','#F04438',
                     '#8B5CF6','#EC4899','#06B6D4','#84CC16','#D946EF',
                     '#F97316','#64748B'];
    new Chart(ctx, {
        type: 'bar',
        data: {
            labels: top.map(o => o.nombre.length > 20 ? o.nombre.slice(0, 18) + '…' : o.nombre),
            datasets: [{
                label: 'Votos',
                data: top.map(o => o.votos),
                backgroundColor: top.map((_, i) => colores[i % colores.length]),
                borderRadius: 6,
            }],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            indexAxis: 'y',
            plugins: {
                legend: { display: false },
                tooltip: {
                    callbacks: {
                        label: function (ctx) {
                            const o = ranking[ctx.dataIndex];
                            return `${o.votos} votos (${o.porcentaje.toFixed(1)}%)`;
                        },
                    },
                },
            },
            scales: {
                x: { grid: { color: '#E2E8F0' }, ticks: { font: { size: 11 } } },
                y: { grid: { display: false }, ticks: { font: { size: 10 } } },
            },
        },
    });
};

ELECTORAL.graficos.crearDonutChart = function (canvasId, distribucion) {
    const ctx = document.getElementById(canvasId);
    if (!ctx || !distribucion.length) return;
    new Chart(ctx, {
        type: 'doughnut',
        data: {
            labels: distribucion.map(d => d.label),
            datasets: [{
                data: distribucion.map(d => d.value),
                backgroundColor: distribucion.map(d => d.color),
                borderWidth: 0,
            }],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            cutout: '65%',
            plugins: {
                legend: {
                    position: 'bottom',
                    labels: { font: { size: 11 }, padding: 12 },
                },
                tooltip: {
                    callbacks: {
                        label: function (ctx) {
                            const total = distribucion.reduce((s, d) => s + d.value, 0);
                            const pct = total > 0 ? (ctx.parsed / total * 100).toFixed(1) : 0;
                            return `${ctx.label}: ${ctx.parsed.toLocaleString()} votos (${pct}%)`;
                        },
                    },
                },
            },
        },
    });
};

ELECTORAL.graficos.crearLineaParticipacion = function (canvasId, data) {
    const ctx = document.getElementById(canvasId);
    if (!ctx) return;
    new Chart(ctx, {
        type: 'line',
        data: {
            labels: data.map(d => d.label),
            datasets: [{
                label: '% Participación',
                data: data.map(d => d.pct),
                borderColor: '#002B66',
                backgroundColor: 'rgba(0,43,102,0.08)',
                fill: true,
                tension: 0.3,
                pointBackgroundColor: '#002B66',
            }],
        },
        options: {
            responsive: true,
            maintainAspectRatio: false,
            plugins: { legend: { display: false } },
            scales: {
                y: {
                    beginAtZero: true,
                    max: 100,
                    ticks: { callback: v => v + '%', font: { size: 11 } },
                },
            },
        },
    });
};

/* -----------------------------------------------------------------------
 * 5. UTILIDADES — Formateo, filtros, etc.
 * ----------------------------------------------------------------------- */
ELECTORAL.formatearNumero = function (n) {
    return (parseInt(n, 10) || 0).toLocaleString('es-PE');
};

ELECTORAL.porcentaje = function (valor, total, decimales) {
    if (!total) return '0%';
    return ((valor / total) * 100).toFixed(decimales || 1) + '%';
};

ELECTORAL.rankingHTML = function (ranking) {
    return ranking.map((o, i) => {
        const medalla = i === 0 ? '🥇' : i === 1 ? '🥈' : i === 2 ? '🥉' : `${i + 1}.`;
        return `<tr>
            <td class="text-center fw-bold">${medalla}</td>
            <td>
                <div class="d-flex align-items-center gap-2">
                    ${o.logo ? `<img src="${o.logo}" class="rounded" style="width:28px;height:28px;object-fit:contain" alt="">` : ''}
                    <span class="fw-semibold">${o.nombre}</span>
                </div>
            </td>
            <td class="text-end fw-bold">${ELECTORAL.formatearNumero(o.votos)}</td>
            <td class="text-end">
                <div class="progress" style="height:20px;">
                    <div class="progress-bar bg-primary" role="progressbar"
                         style="width:${Math.min(o.porcentaje, 100)}%"
                         aria-valuenow="${o.porcentaje}" aria-valuemin="0" aria-valuemax="100">
                        ${o.porcentaje.toFixed(1)}%
                    </div>
                </div>
            </td>
        </tr>`;
    }).join('');
};

/* -----------------------------------------------------------------------
 * 6. INICIALIZACIÓN — Carga de candidatos y gráficos por defecto
 * ----------------------------------------------------------------------- */
ELECTORAL.init = async function () {
    await ELECTORAL.candidatos.cargar();
    if (ELECTORAL.candidatos.data) {
        document.dispatchEvent(new CustomEvent('candidatos-cargados', {
            detail: ELECTORAL.candidatos.data,
        }));
    }
};

ELECTORAL.init();

/* Exportar para uso en módulos ES (opcional) */
if (typeof module !== 'undefined' && module.exports) {
    module.exports = ELECTORAL;
}