import asyncio
import hmac
import json
import logging
import os
import re

from aiohttp import web
from livekit import rtc
from vosk import KaldiRecognizer, Model, SetLogLevel


LOG = logging.getLogger(__name__)
IDENTITY = "devloom-transcriber"
TOPIC = "devloom.transcript"
MEMBER_ID = re.compile(r"session-[1-9][0-9]{0,18}")
SAMPLE_RATE = 16000
BATCH_BYTES = SAMPLE_RATE // 2
MAX_SEGMENT_BYTES = SAMPLE_RATE * 2 * 6


class TranscriptRoom:
    def __init__(self, model):
        self.model = model
        self.room = rtc.Room()
        self.ready = asyncio.get_running_loop().create_future()
        self.stopping = asyncio.Event()
        self.tracks = {}
        self.tasks = set()

        self.room.on("track_published", self.subscribe_microphone)
        self.room.on("track_unpublished", self.on_track_unpublished)
        self.room.on("track_subscribed", self.listen_to_track)
        self.room.on("track_unsubscribed", self.on_track_unsubscribed)
        self.room.on("track_muted", self.on_track_muted)
        self.room.on("track_unmuted", self.on_track_unmuted)
        self.room.on("participant_disconnected", self.on_participant_disconnected)
        self.room.on("reconnected", self.subscribe_existing_tracks)
        self.room.on("disconnected", lambda _reason: self.stopping.set())

    async def run(self, url, token, name):
        try:
            async with asyncio.timeout(7):
                await self.room.connect(url, token, rtc.RoomOptions(auto_subscribe=False))

            if self.room.name != name or self.room.local_participant.identity != IDENTITY:
                return

            if self.stopping.is_set() or not self.has_members():
                return

            self.subscribe_existing_tracks()
            self.ready.set_result(True)
            await self.stopping.wait()
        except Exception as error:
            LOG.warning("Transcript room connection failed (%s)", type(error).__name__)
        finally:
            self.stopping.set()
            for task in tuple(self.tasks):
                task.cancel()
            await asyncio.gather(*self.tasks, return_exceptions=True)

            try:
                async with asyncio.timeout(3):
                    await self.room.disconnect()
            except Exception as error:
                LOG.warning("Transcript room disconnect failed (%s)", type(error).__name__)
            finally:
                if not self.ready.done():
                    self.ready.set_result(False)

    def has_members(self):
        return any(MEMBER_ID.fullmatch(identity) for identity in self.room.remote_participants)

    def on_participant_disconnected(self, participant):
        for publication in participant.track_publications.values():
            self.cancel_track(publication.sid)
        if not self.has_members():
            self.stopping.set()

    def subscribe_existing_tracks(self):
        for participant in self.room.remote_participants.values():
            for publication in participant.track_publications.values():
                self.subscribe_microphone(publication, participant)

    def subscribe_microphone(self, publication, participant):
        if (
            not self.stopping.is_set()
            and MEMBER_ID.fullmatch(participant.identity)
            and publication.source == rtc.TrackSource.SOURCE_MICROPHONE
            and publication.kind == rtc.TrackKind.KIND_AUDIO
            and not publication.muted
        ):
            if publication.track:
                self.listen_to_track(publication.track, publication, participant)
            else:
                publication.set_subscribed(True)

    def on_track_muted(self, _participant, publication):
        self.cancel_track(publication.sid)

    def on_track_unmuted(self, participant, publication):
        self.subscribe_microphone(publication, participant)

    def on_track_unsubscribed(self, _track, publication, _participant):
        self.cancel_track(publication.sid)

    def on_track_unpublished(self, publication, _participant):
        self.cancel_track(publication.sid)

    def cancel_track(self, sid):
        if task := self.tracks.pop(sid, None):
            task.cancel()

    def listen_to_track(self, track, publication, participant):
        if (
            self.stopping.is_set()
            or publication.muted
            or publication.sid in self.tracks
            or publication.source != rtc.TrackSource.SOURCE_MICROPHONE
            or not MEMBER_ID.fullmatch(participant.identity)
        ):
            return

        task = asyncio.create_task(self.transcribe(track, participant.identity))
        self.tracks[publication.sid] = task
        self.tasks.add(task)
        task.add_done_callback(lambda finished: self.track_finished(publication.sid, finished))

    def track_finished(self, sid, task):
        self.tasks.discard(task)
        if self.tracks.get(sid) is task:
            self.tracks.pop(sid)
        if not task.cancelled() and (error := task.exception()):
            LOG.warning("Microphone transcription failed (%s)", type(error).__name__)

    async def transcribe(self, track, speaker):
        stream = rtc.AudioStream(track, sample_rate=SAMPLE_RATE, num_channels=1, capacity=25)
        batch = bytearray()
        segment_bytes = 0
        try:
            recognizer = await asyncio.to_thread(KaldiRecognizer, self.model, SAMPLE_RATE)

            async for event in stream:
                if self.stopping.is_set():
                    break
                batch.extend(event.frame.data.cast("B"))
                if len(batch) < BATCH_BYTES:
                    continue

                segment_bytes += len(batch)
                final = segment_bytes >= MAX_SEGMENT_BYTES
                result = await asyncio.to_thread(decode, recognizer, bytes(batch), final)
                batch.clear()

                if result is not None:
                    segment_bytes = 0
                    if result and not self.stopping.is_set():
                        await self.room.local_participant.publish_data(
                            json.dumps({"speaker": speaker, "text": result}, ensure_ascii=False),
                            reliable=True,
                            topic=TOPIC,
                        )
        finally:
            await stream.aclose()


def decode(recognizer, pcm, final):
    if recognizer.AcceptWaveform(pcm):
        result = recognizer.Result()
    elif final:
        result = recognizer.FinalResult()
    else:
        return None
    return json.loads(result)["text"].strip()[:2000]


class TranscriptionService:
    def __init__(self, model, url, secret):
        self.model = model
        self.url = url
        self.authorization = ("Bearer " + secret).encode()
        self.rooms = {}

    def require_authorization(self, request):
        received = request.headers.get("Authorization", "").encode()
        if not hmac.compare_digest(received, self.authorization):
            raise web.HTTPUnauthorized()

    async def start(self, request):
        self.require_authorization(request)
        name = request.match_info["room"]
        try:
            body = await request.json()
        except ValueError:
            raise web.HTTPBadRequest() from None
        token = body.get("token") if isinstance(body, dict) else None
        if not isinstance(token, str) or not token or len(token) > 6144:
            raise web.HTTPBadRequest()

        session = self.rooms.get(name)
        if session and session.stopping.is_set():
            await asyncio.shield(session.task)
            session = self.rooms.get(name)
        if not session:
            session = TranscriptRoom(self.model)
            self.rooms[name] = session
            session.task = asyncio.create_task(self.run_session(session, name, token))

        active = await asyncio.shield(session.ready)
        if not active or session.stopping.is_set():
            raise web.HTTPServiceUnavailable()

        return web.json_response({"active": True})

    async def stop(self, request):
        self.require_authorization(request)
        if session := self.rooms.get(request.match_info["room"]):
            session.stopping.set()
            await asyncio.shield(session.task)
        return web.json_response({"active": False})

    async def run_session(self, session, name, token):
        try:
            await session.run(self.url, token, name)
        finally:
            self.rooms.pop(name, None)

    async def shutdown(self, _app):
        sessions = list(self.rooms.values())
        for session in sessions:
            session.stopping.set()
        await asyncio.gather(*(session.task for session in sessions), return_exceptions=True)


async def health(_request):
    return web.json_response({"status": "ok"})


def main():
    logging.basicConfig(level=logging.WARNING)
    SetLogLevel(-1)
    url = os.environ["LIVEKIT_URL"]
    secret = os.environ["TRANSCRIPTION_SECRET"]
    if not url or not secret:
        raise ValueError("LiveKit URL and transcription secret are required")

    service = TranscriptionService(Model("/models/en-us"), url, secret)
    app = web.Application(client_max_size=8192)
    prefix = r"/rooms/{room:devloom-[0-9a-f-]{36}}"
    app.add_routes(
        [
            web.get("/health", health),
            web.post(prefix + "/start", service.start),
            web.post(prefix + "/stop", service.stop),
        ]
    )
    app.on_shutdown.append(service.shutdown)
    web.run_app(app, host="0.0.0.0", port=8095, access_log=None)


if __name__ == "__main__":
    main()
