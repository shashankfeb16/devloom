import assert from "node:assert/strict"
import test from "node:test"
import {readTranscriptPacket, TRANSCRIPT_WORKER} from "../../assets/js/meeting_transcript.mjs"

const sender = {identity: TRANSCRIPT_WORKER}
const topic = "devloom.transcript"
const encode = value => new TextEncoder().encode(value)

test("accepts a well-formed segment from the meeting transcriber", () => {
  const payload = encode(JSON.stringify({speaker: "session-32", text: " Hello, everyone. "}))

  assert.deepEqual(readTranscriptPacket(payload, sender, topic), {
    speaker: "session-32",
    text: "Hello, everyone.",
  })
})

test("rejects transcript packets from other participants or topics", () => {
  const payload = encode(JSON.stringify({speaker: "session-32", text: "Hello."}))

  assert.equal(readTranscriptPacket(payload, {identity: "session-32"}, topic), null)
  assert.equal(readTranscriptPacket(payload, undefined, topic), null)
  assert.equal(readTranscriptPacket(payload, sender, "devloom.chat"), null)
})

test("rejects oversized, malformed, and empty segments", () => {
  for (const payload of [
    new Uint8Array(8193),
    encode("{"),
    encode("null"),
    encode(JSON.stringify({speaker: "made-up", text: "Hello."})),
    encode(JSON.stringify({speaker: "session-32", text: " "})),
  ]) {
    assert.equal(readTranscriptPacket(payload, sender, topic), null)
  }
})
