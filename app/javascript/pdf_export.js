import PdfInk from "pdf_ink"

export const EXPORT_DPI = 240
export const MAX_EXPORT_PIXELS = 16_000_000

// Snapshot operations, never screen canvases: virtualized pages have no backing store.
export function snapshotPages(states) {
  return states.map(({ page, ink }) => ({ page, operations: structuredClone(ink.pages.get(ink.pageNumber)) }))
}

export async function generateAnswerPdf({ source, pages, progress = () => {}, current = () => true }) {
  const { PDFDocument, PDFDict, PDFName } = await import("pdf-lib")
  if (!current()) throw new Error("PDF生成を中止しました。")
  const document = await PDFDocument.load(source, { updateMetadata: false })
  // Editing invalidates signatures. Reject signed documents rather than implying validity.
  for (const [, object] of document.context.enumerateIndirectObjects()) {
    if (object instanceof PDFDict && (object.has(PDFName.of("ByteRange")) ||
        object.get(PDFName.of("FT"))?.toString() === "/Sig")) {
      throw new Error("署名付きPDFには対応していません。")
    }
  }
  if (document.getPageCount() !== pages.length) throw new Error("PDFのページ構成を確認できません。")
  for (let index = 0; index < pages.length; index++) {
    if (!current()) throw new Error("PDF生成を中止しました。")
    const { page, operations } = pages[index]
    progress(index + 1, pages.length)
    if (!operations.length) continue
    // Unrotated viewport maps the actual CropBox to transparent pixels. The original
    // PDF's /Rotate then rotates both original content and overlay together.
    const viewport = page.getViewport({ scale: EXPORT_DPI / 72, rotation: 0 })
    const [x, y, right, top] = page.view
    if (![x, y, right, top, viewport.width, viewport.height].every(Number.isFinite) ||
        right <= x || top <= y || Math.ceil(viewport.width) * Math.ceil(viewport.height) > MAX_EXPORT_PIXELS) {
      throw new Error("このページのサイズでは安全にPDFを生成できません。")
    }
    const canvas = window.document.createElement("canvas")
    try {
      const ink = new PdfInk(canvas, index + 1)
      ink.pages.set(index + 1, operations)
      ink.setViewport(viewport, 1)
      const blob = await new Promise((resolve, reject) => canvas.toBlob(
        result => result ? resolve(result) : reject(new Error("手書き画像を生成できません。")), "image/png"))
      if (!current()) throw new Error("PDF生成を中止しました。")
      const image = await document.embedPng(await blob.arrayBuffer())
      await image.embed() // Release decoded PNG channels before processing the next page.
      document.getPage(index).drawImage(image, { x, y, width: right - x, height: top - y })
    } finally {
      canvas.width = canvas.height = 0
    }
    await new Promise(resolve => window.setTimeout(resolve, 0))
  }
  if (!current()) throw new Error("PDF生成を中止しました。")
  return document.save()
}
