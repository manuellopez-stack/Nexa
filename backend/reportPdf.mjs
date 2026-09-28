// PDF del informe radiológico con pdfkit (sin navegador). Lo usan la firma
// (POST .../report/sign, se guarda como documento) y la vista previa
// (GET .../report/preview, con marca de agua "BORRADOR", no se guarda).
//
// Las fuentes estándar de PDF (Helvetica) cubren tildes, ñ, ¿ y ¡.

import PDFDocument from "pdfkit";

const MARGIN = 56;
const COLORS = { text: "#0F172A", muted: "#475569", line: "#CBD5E1", accent: "#0F766E" };

const SECTIONS = [
  ["clinicalHistory", "Antecedentes clínicos"],
  ["technique", "Técnica"],
  ["findings", "Hallazgos"],
  ["impression", "Impresión diagnóstica"],
];

// Marca de agua de la vista previa. Se dibuja al final sobre cada página ya
// armada (bufferPages), así no interfiere con el flujo del texto. Sin
// márgenes mientras tanto, para que pdfkit no agregue páginas.
function drawWatermark(doc) {
  const { width, height } = doc.page;
  doc.page.margins = { top: 0, bottom: 0, left: 0, right: 0 };
  doc.save();
  doc.fillColor("#DC2626").opacity(0.12).font("Helvetica-Bold").fontSize(96);
  doc.rotate(-35, { origin: [width / 2, height / 2] });
  doc.text("BORRADOR", -width / 2, height / 2 - 50, { width: width * 2, align: "center", lineBreak: false });
  doc.restore();
}

function label(doc, text) {
  doc.font("Helvetica-Bold").fontSize(9).fillColor(COLORS.muted).text(text.toUpperCase(), { characterSpacing: 0.5 });
}

/**
 * @param {object} data
 * @param {string} data.clinicName
 * @param {Buffer|null} data.logo  PNG o JPEG (el llamador convierte otros formatos)
 * @param {string} data.examTitle  nombre del examen ("Informe de <examTitle>")
 * @param {{name?: string, rut?: string, age?: number|string}} data.patient
 * @param {string|null} data.accessionNumber
 * @param {string|null} data.examDate  ya formateada
 * @param {string[]} data.fonasaCodes
 * @param {{clinicalHistory?: string, technique?: string, findings?: string, impression?: string}} data.sections
 * @param {{name: string, rut: string, specialty: string, signedAtText: string}|null} data.signature
 * @param {boolean} [data.draft]  marca de agua "BORRADOR" y sin firma
 * @returns {Promise<Buffer>}
 */
export function buildReportPdf(data) {
  return new Promise((resolve, reject) => {
    const doc = new PDFDocument({
      size: "LETTER",
      bufferPages: true,
      margins: { top: MARGIN, bottom: MARGIN, left: MARGIN, right: MARGIN },
      info: {
        Title: `Informe de ${data.examTitle}`,
        Author: data.signature?.name ?? "Imagenda",
        Creator: "Imagenda",
      },
    });
    const chunks = [];
    doc.on("data", (chunk) => chunks.push(chunk));
    doc.on("end", () => resolve(Buffer.concat(chunks)));
    doc.on("error", reject);

    try {
      const contentWidth = doc.page.width - MARGIN * 2;

      // Encabezado: logo + nombre de la clínica.
      const headerTop = doc.y;
      let textLeft = MARGIN;
      if (data.logo) {
        try {
          doc.image(data.logo, MARGIN, headerTop, { fit: [110, 48] });
          textLeft = MARGIN + 124;
        } catch {
          // Logo ilegible: el informe sale igual, sin logo.
        }
      }
      doc
        .font("Helvetica-Bold")
        .fontSize(14)
        .fillColor(COLORS.text)
        .text(data.clinicName || "", textLeft, headerTop + 14, { width: contentWidth - (textLeft - MARGIN) });
      doc.y = Math.max(doc.y, headerTop + 52);
      doc.moveTo(MARGIN, doc.y).lineTo(MARGIN + contentWidth, doc.y).strokeColor(COLORS.line).lineWidth(1).stroke();
      doc.moveDown(0.8);

      // Título.
      doc
        .font("Helvetica-Bold")
        .fontSize(17)
        .fillColor(COLORS.accent)
        .text(`Informe de ${data.examTitle}`, MARGIN, doc.y, { width: contentWidth });
      doc.moveDown(0.6);

      // Datos del paciente y del examen, en dos columnas.
      const age = data.patient?.age;
      const leftRows = [
        ["Paciente", data.patient?.name || "—"],
        ["RUT", data.patient?.rut || "—"],
        ["Edad", age !== null && age !== undefined && age !== "" ? `${age} años` : "—"],
      ];
      const rightRows = [
        ["N° de acceso", data.accessionNumber || "—"],
        ["Fecha del examen", data.examDate || "—"],
        ["Código FONASA", data.fonasaCodes?.length ? data.fonasaCodes.join(", ") : "—"],
      ];
      const columnWidth = contentWidth / 2 - 8;
      const rowsTop = doc.y;
      const drawRows = (rows, x) => {
        doc.y = rowsTop;
        for (const [name, value] of rows) {
          doc.font("Helvetica-Bold").fontSize(10).fillColor(COLORS.muted).text(`${name}: `, x, doc.y, {
            width: columnWidth,
            continued: true,
          });
          doc.font("Helvetica").fillColor(COLORS.text).text(String(value));
          doc.moveDown(0.2);
        }
        return doc.y;
      };
      const leftBottom = drawRows(leftRows, MARGIN);
      const rightBottom = drawRows(rightRows, MARGIN + columnWidth + 16);
      doc.y = Math.max(leftBottom, rightBottom) + 6;
      doc.moveTo(MARGIN, doc.y).lineTo(MARGIN + contentWidth, doc.y).strokeColor(COLORS.line).stroke();
      doc.moveDown(1);

      // Las 4 secciones.
      for (const [key, title] of SECTIONS) {
        const body = (data.sections?.[key] ?? "").trim();
        doc.x = MARGIN;
        label(doc, title);
        doc.moveDown(0.25);
        doc
          .font("Helvetica")
          .fontSize(11)
          .fillColor(body ? COLORS.text : COLORS.muted)
          .text(body || "—", MARGIN, doc.y, { width: contentWidth, align: "left", lineGap: 2 });
        doc.moveDown(1);
      }

      // Firma.
      doc.moveDown(1);
      if (doc.y > doc.page.height - MARGIN - 110) doc.addPage();
      doc.x = MARGIN;
      doc.moveTo(MARGIN, doc.y).lineTo(MARGIN + 240, doc.y).strokeColor(COLORS.muted).stroke();
      doc.moveDown(0.4);
      if (data.signature && !data.draft) {
        doc.font("Helvetica-Bold").fontSize(11).fillColor(COLORS.text).text(data.signature.name, MARGIN, doc.y);
        doc.font("Helvetica").fontSize(10).text(`RUT ${data.signature.rut}`);
        doc.text(data.signature.specialty);
        doc.moveDown(0.4);
        doc
          .fontSize(9)
          .fillColor(COLORS.muted)
          .text(`Firmado electrónicamente en Imagenda el ${data.signature.signedAtText}.`);
      } else {
        doc
          .font("Helvetica-Oblique")
          .fontSize(10)
          .fillColor(COLORS.muted)
          .text("Borrador sin firma: este documento no tiene validez clínica.", MARGIN, doc.y);
      }

      if (data.draft) {
        const range = doc.bufferedPageRange();
        for (let i = range.start; i < range.start + range.count; i++) {
          doc.switchToPage(i);
          drawWatermark(doc);
        }
      }

      doc.end();
    } catch (error) {
      reject(error);
    }
  });
}
