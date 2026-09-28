// Plantillas del informe radiológico (GET .../imaging-orders/:orderId/report
// cuando la orden todavía no tiene informe). Textos base breves y neutros:
// "technique" es un punto de partida editable; "findings" e "impression" son
// una guía de lo que hay que completar, no un texto para firmar tal cual.
//
// Para cambiar una plantilla basta editar este archivo. Para agregar una
// modalidad nueva: sumar una entrada a TEMPLATES y sus palabras clave a
// MATCHERS (se buscan, sin tildes ni mayúsculas, en la categoría y el
// nombre del examen; gana la primera que calce, por eso Mamografía va antes
// que Rayos X).

export const TEMPLATES = {
  tac: {
    key: "tac",
    label: "Tomografía computada (TAC)",
    clinicalHistory: "",
    technique:
      "Estudio de tomografía computada multicorte adquirido en plano axial, con reconstrucciones multiplanares. [Indicar si se administró contraste endovenoso y en qué fases.]",
    findings:
      "[Describir los hallazgos por región u órgano. Mencionar hallazgos relevantes y también los hallazgos negativos pertinentes.]",
    impression: "[Conclusión diagnóstica breve, numerada si hay más de un hallazgo.]",
  },
  rm: {
    key: "rm",
    label: "Resonancia magnética (RM)",
    clinicalHistory: "",
    technique:
      "Estudio de resonancia magnética con secuencias multiplanares potenciadas en T1 y T2. [Indicar secuencias adicionales y si se administró gadolinio.]",
    findings:
      "[Describir los hallazgos por estructura. Mencionar hallazgos relevantes y también los hallazgos negativos pertinentes.]",
    impression: "[Conclusión diagnóstica breve, numerada si hay más de un hallazgo.]",
  },
  eco: {
    key: "eco",
    label: "Ecotomografía",
    clinicalHistory: "",
    technique: "Examen realizado con transductor [convexo / lineal] en tiempo real. [Indicar si se usó Doppler.]",
    findings:
      "[Describir cada órgano o estructura evaluada: forma, tamaño, ecogenicidad y lesiones focales, con sus medidas.]",
    impression: "[Conclusión diagnóstica breve, numerada si hay más de un hallazgo.]",
  },
  mamografia: {
    key: "mamografia",
    label: "Mamografía",
    clinicalHistory: "",
    technique: "Mamografía bilateral en proyecciones craneocaudal y oblicua mediolateral. [Indicar proyecciones adicionales.]",
    findings:
      "[Describir la composición mamaria y los hallazgos (nódulos, calcificaciones, distorsiones, asimetrías) con su ubicación.]",
    impression: "[Conclusión diagnóstica y categoría BI-RADS con la recomendación correspondiente.]",
  },
  rx: {
    key: "rx",
    label: "Rayos X",
    clinicalHistory: "",
    technique: "Radiografía en proyecciones [frontal y lateral].",
    findings: "[Describir los hallazgos de las estructuras evaluadas.]",
    impression: "[Conclusión diagnóstica breve.]",
  },
  generica: {
    key: "generica",
    label: "Informe general",
    clinicalHistory: "",
    technique: "[Describir la técnica del examen.]",
    findings: "[Describir los hallazgos.]",
    impression: "[Conclusión diagnóstica breve.]",
  },
};

const MATCHERS = [
  { key: "mamografia", words: ["mamograf", "mamografia", "mamas", "mx"] },
  { key: "tac", words: ["tac", "tomograf", "scanner", "escaner", "ct"] },
  { key: "rm", words: ["rm", "resonancia", "mri"] },
  { key: "eco", words: ["eco", "ecotomograf", "ecograf", "ultrason", "doppler"] },
  { key: "rx", words: ["rx", "rayos", "radiograf", "radiologia"] },
];

function normalize(text) {
  return String(text ?? "")
    .normalize("NFD")
    .replace(/[̀-ͯ]/g, "")
    .toLowerCase();
}

// Palabras sueltas del texto (para no confundir "rm" con "forma", ni "ct"
// con "abdomen").
function tokens(text) {
  return normalize(text).split(/[^a-z0-9]+/).filter(Boolean);
}

/**
 * Plantilla para los tipos de examen de una orden
 * ([{ name, category }]). Siempre devuelve una (la genérica si no calza).
 */
export function templateForExams(types = []) {
  const words = types.flatMap((type) => [...tokens(type?.category), ...tokens(type?.name)]);
  for (const matcher of MATCHERS) {
    const hit = words.some((word) =>
      matcher.words.some((candidate) =>
        candidate.length <= 3 ? word === candidate : word.startsWith(candidate),
      ),
    );
    if (hit) return TEMPLATES[matcher.key];
  }
  return TEMPLATES.generica;
}
