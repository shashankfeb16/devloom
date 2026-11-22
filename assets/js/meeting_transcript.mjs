export const TRANSCRIPT_WORKER = "devloom-transcriber"
const transcriptTopic = "devloom.transcript"
const decoder = new TextDecoder("utf-8", {fatal: true})

export function readTranscriptPacket(payload, sender, topic) {
  if (sender?.identity !== TRANSCRIPT_WORKER || topic !== transcriptTopic) return null
  if (!(payload instanceof Uint8Array) || payload.byteLength > 8192) return null

  try {
    const message = JSON.parse(decoder.decode(payload))
    if (typeof message?.speaker !== "string" || !/^session-\d+$/.test(message.speaker)) return null
    if (typeof message.text !== "string" || !message.text.trim()) return null

    return {speaker: message.speaker, text: message.text.trim()}
  } catch {
    return null
  }
}
