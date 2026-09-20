import dicomParser from "dicom-parser";
import sharp from "sharp";

// Convierte un DICOM sin comprimir (pixel data crudo) a un PNG de vista
// previa. Se usa tanto al subir una imagen manualmente desde la app
// (server.mjs) como al sincronizar estudios desde Orthanc (syncOrthanc.mjs),
// para que ambos flujos generen el mismo tipo de preview.
export async function convertDicomToPng(dicomBuffer) {
  const byteArray = new Uint8Array(dicomBuffer);
  const dataSet = dicomParser.parseDicom(byteArray);

  const pixelDataElement = dataSet.elements.x7fe00010;
  if (!pixelDataElement) {
    throw new Error(
      "El archivo DICOM no contiene datos de imagen (pixel data).",
    );
  }

  if (pixelDataElement.encapsulatedPixelData) {
    throw new Error(
      "Este archivo DICOM usa un formato comprimido que Imagenda todavía no puede convertir a imagen.",
    );
  }

  const rows = dataSet.uint16("x00280010");
  const columns = dataSet.uint16("x00280011");
  const bitsAllocated = dataSet.uint16("x00280100") || 16;
  const pixelRepresentation = dataSet.uint16("x00280103") || 0;
  const samplesPerPixel = dataSet.uint16("x00280002") || 1;
  const photometricInterpretation = (
    dataSet.string("x00280004") || "MONOCHROME2"
  ).trim();

  if (!rows || !columns) {
    throw new Error(
      "No fue posible leer las dimensiones de la imagen DICOM.",
    );
  }

  const numPixels = rows * columns * samplesPerPixel;

  if (samplesPerPixel === 3) {
    const rgbValues = new Uint8Array(
      dataSet.byteArray.buffer,
      pixelDataElement.dataOffset,
      numPixels,
    );
    return sharp(Buffer.from(rgbValues), {
      raw: { width: columns, height: rows, channels: 3 },
    })
      .png()
      .toBuffer();
  }

  const rescaleSlopeRaw = dataSet.floatString("x00281053");
  const rescaleInterceptRaw = dataSet.floatString("x00281052");
  const slope = rescaleSlopeRaw !== undefined ? rescaleSlopeRaw : 1;
  const intercept = rescaleInterceptRaw !== undefined ? rescaleInterceptRaw : 0;

  let rawValues;
  if (bitsAllocated === 16) {
    rawValues =
      pixelRepresentation === 1
        ? new Int16Array(
            dataSet.byteArray.buffer,
            pixelDataElement.dataOffset,
            numPixels,
          )
        : new Uint16Array(
            dataSet.byteArray.buffer,
            pixelDataElement.dataOffset,
            numPixels,
          );
  } else {
    rawValues = new Uint8Array(
      dataSet.byteArray.buffer,
      pixelDataElement.dataOffset,
      numPixels,
    );
  }

  const rescaled = new Float64Array(numPixels);
  let min = Infinity;
  let max = -Infinity;
  for (let i = 0; i < numPixels; i++) {
    const value = rawValues[i] * slope + intercept;
    rescaled[i] = value;
    if (value < min) min = value;
    if (value > max) max = value;
  }

  const windowCenterRaw = dataSet.string("x00281050");
  const windowWidthRaw = dataSet.string("x00281051");
  let windowCenter = windowCenterRaw
    ? parseFloat(windowCenterRaw.split("\\")[0])
    : NaN;
  let windowWidth = windowWidthRaw
    ? parseFloat(windowWidthRaw.split("\\")[0])
    : NaN;

  if (Number.isNaN(windowCenter) || Number.isNaN(windowWidth)) {
    windowCenter = (max + min) / 2;
    windowWidth = max - min || 1;
  }

  const low = windowCenter - windowWidth / 2;
  const high = windowCenter + windowWidth / 2;
  const range = high - low || 1;
  const invert = photometricInterpretation === "MONOCHROME1";

  const output = new Uint8Array(numPixels);
  for (let i = 0; i < numPixels; i++) {
    let normalized = ((rescaled[i] - low) / range) * 255;
    normalized = Math.max(0, Math.min(255, normalized));
    output[i] = invert ? 255 - normalized : normalized;
  }

  return sharp(Buffer.from(output), {
    raw: { width: columns, height: rows, channels: 1 },
  })
    .png()
    .toBuffer();
}
