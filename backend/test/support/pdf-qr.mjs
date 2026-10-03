// Lee el QR de un PDF generado por reportPdf.mjs (solo tests). pdfkit guarda
// el PNG del QR (RGBA) como píxeles RGB comprimidos con Flate (más una
// máscara de alfa aparte); se descomprime y se decodifica con jsQR.
import zlib from "node:zlib";
import jsQR from "jsqr";

export function readQrFromPdf(pdf) {
  const text = pdf.toString("latin1");
  const objectRe = /<<([^>]*?\/Subtype \/Image[\s\S]*?)>>\s*stream\r?\n/g;
  for (let match; (match = objectRe.exec(text)); ) {
    const dict = match[1];
    if (!/\/ColorSpace \/DeviceRGB/.test(dict)) continue;
    const width = Number(dict.match(/\/Width (\d+)/)?.[1]);
    const height = Number(dict.match(/\/Height (\d+)/)?.[1]);
    const length = Number(dict.match(/\/Length (\d+)/)?.[1]);
    const start = match.index + match[0].length;
    const rgb = zlib.inflateSync(pdf.subarray(start, start + length));
    if (rgb.length !== width * height * 3) continue;
    const rgba = new Uint8ClampedArray(width * height * 4);
    for (let i = 0, j = 0; i < rgb.length; i += 3, j += 4) {
      rgba[j] = rgb[i];
      rgba[j + 1] = rgb[i + 1];
      rgba[j + 2] = rgb[i + 2];
      rgba[j + 3] = 255;
    }
    const code = jsQR(rgba, width, height);
    if (code) return code.data;
  }
  return null;
}
