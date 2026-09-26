import sharp from "sharp";

/**
 * Splits a page scan into top and bottom halves with a small overlap.
 * Vision models downscale each image, so two halves are read at roughly twice the
 * detail of one full page. Small Bangla digits (৮১ vs ৭৯) were being misread otherwise.
 */
export async function splitHalves(data: Buffer): Promise<{ mime: string; data: Buffer }[]> {
  const img = sharp(data);
  const { width, height } = await img.metadata();
  if (!width || !height) return [{ mime: "image/jpeg", data }];
  const overlap = Math.round(height * 0.04);
  const half = Math.ceil(height / 2);
  const top = { left: 0, top: 0, width, height: Math.min(height, half + overlap) };
  const bottom = { left: 0, top: Math.max(0, half - overlap), width, height: height - Math.max(0, half - overlap) };
  const [a, b] = await Promise.all(
    [top, bottom].map((region) => sharp(data).extract(region).jpeg({ quality: 90 }).toBuffer()),
  );
  return [
    { mime: "image/jpeg", data: a },
    { mime: "image/jpeg", data: b },
  ];
}
