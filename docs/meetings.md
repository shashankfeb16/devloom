# Self-host LiveKit for Devloom

Devloom owns workspace membership and starts one room per workspace. LiveKit handles WebRTC audio, video, and screen sharing. The development Compose stack includes a loopback-only LiveKit service and applies the meetings migration on startup. Its bundled keys are for local development.

## Shared deployments

1. Run a dedicated LiveKit server using the [LiveKit virtual machine guide](https://docs.livekit.io/transport/self-hosting/vm/). Choose a public hostname such as `rtc.example.com`, use a trusted TLS certificate, and configure WebRTC UDP and TURN/TLS following the [LiveKit firewall guidance](https://docs.livekit.io/transport/self-hosting/ports-firewall/). Devloom's production Caddy listens on TCP 443. A separate media VM or a TCP-aware load balancer avoids contention with TURN/TLS for that port.
2. Set `room.auto_create: false` in the LiveKit configuration. Devloom creates rooms explicitly. This setting prevents previously issued credentials from recreating a room after the host ends the call. Generate a dedicated API key and secret for Devloom.
3. Add these settings to the private environment file used by the Devloom web container. The Hostinger deployment reads them from its existing shared `app.env` and preserves them on redeploy.

   ```dotenv
   LIVEKIT_URL=wss://rtc.example.com
   LIVEKIT_API_URL=https://rtc.example.com
   LIVEKIT_API_KEY=<your-api-key>
   LIVEKIT_API_SECRET=<your-api-secret>
   ```

   `LIVEKIT_URL` is the address participants use. `LIVEKIT_API_URL` is the HTTP(S) address Phoenix uses for room administration. An internal address is suitable when only Devloom can reach it. Restart or redeploy Devloom after setting the variables. With settings missing, the Meetings page shows that the service is unavailable.

4. Test with two workspace accounts on different networks. Confirm that both can join, publish mic and camera tracks, and share a screen. Include a restrictive network to test the TURN fallback. Size the media server against your largest expected meeting and concurrent workspace calls.

Devloom rechecks membership before issuing each join token and removes participants whose workspace membership or sign-in session is revoked. Self-hosted LiveKit can still accept a previously issued token until it expires. Devloom checks connected participants again during room reconciliation and removes any participant whose access was revoked. See [LiveKit token revocation](https://docs.livekit.io/frontends/reference/tokens-grants/#token-revocation).

## Enable meeting recordings

The meeting host or workspace owner can start and stop recording during a call. Devloom displays a recording indicator to participants and saves a composite MP4 with the cameras, shared screens, and audio. Workspace members can play and download the video under **Recordings**. Only the workspace owner can delete an individual recording.

### Local development

Use the local storage overlay to run a private bucket on your machine. Set these values in your private `.env`:

```dotenv
RECORDINGS_S3_BUCKET=devloom-recordings
RECORDINGS_S3_REGION=us-east-1
RECORDINGS_S3_ACCESS_KEY_ID=<generate a random access key>
RECORDINGS_S3_SECRET_ACCESS_KEY=<generate a random secret key>
RECORDINGS_S3_ENDPOINT=http://recording-storage.localhost:19000
```

Start Devloom, LiveKit Egress, and the local bucket together:

```sh
docker compose -f compose.yaml -f compose.recordings.yaml -f compose.recordings.local.yaml up -d
```

On macOS or Linux, add `COMPOSE_FILE=compose.yaml:compose.recordings.yaml:compose.recordings.local.yaml` to `.env` to use the same services with `docker compose up -d`. Compose creates the bucket on first startup and stores recordings in a named volume. For an existing S3-compatible bucket, set its credentials and endpoint and start only `compose.yaml` and `compose.recordings.yaml`.

### Shared deployments

1. Create a private, unversioned S3 bucket for recordings. Give Devloom's storage credentials permission to put, read, and delete objects under `recordings/` and abort incomplete multipart uploads. For AWS S3, grant `s3:ListBucket` on the bucket so that a missing object can be distinguished from denied access during recovery.
2. Configure the following in the Devloom environment. Keep the same bucket and endpoint when rotating the credentials so existing recordings remain available.

   ```dotenv
   RECORDINGS_S3_BUCKET=devloom-recordings
   RECORDINGS_S3_REGION=us-east-1
   RECORDINGS_S3_ACCESS_KEY_ID=<storage-access-key>
   RECORDINGS_S3_SECRET_ACCESS_KEY=<storage-secret-key>
   ```

   Omit `RECORDINGS_S3_ENDPOINT` for AWS S3. When using S3-compatible storage, set it to a path-style endpoint origin reachable by Devloom, Egress, and users' browsers. Use HTTPS for shared deployments. Devloom checks workspace membership before issuing a playback or download redirect. The signed storage URL expires after 15 minutes.

3. Use LiveKit server v1.13.5 or newer and run a compatible [LiveKit Egress worker](https://docs.livekit.io/transport/self-hosting/egress/) such as v1.15.0. Configure LiveKit and Egress to use the same private Redis service. Give Egress the LiveKit URL and API credentials. Apply the database migration and restart Devloom with the recording environment variables.
4. Join a call from two workspace accounts, start recording, and verify the indicator on both. Share a screen and speak from both accounts, then stop the recording. When the video appears in **Recordings**, verify playback, seeking, downloading, and deletion from the owner account.

## Live transcripts

In a call, open **Transcript**. The meeting host or workspace owner can select **Start transcript**. Participants see the transcription indicator, and recognized English speech appears in the panel with the speaker’s name. Lines received during the call stay available while the panel is closed and clear when you leave the meeting.

Transcription uses the participants’ published microphones and runs on the Devloom server with an offline Vosk model. The worker sends transcript text to participants in the same LiveKit room, and Devloom keeps it in the open meeting view.

For local development, generate a secret with `openssl rand -hex 32`, save it as `TRANSCRIPTION_SECRET` in your private `.env`, and start the worker alongside Devloom with this command.

```sh
docker compose -f compose.yaml -f compose.transcriptions.yaml up -d --build
```

When using the recording overlays, keep them in the Compose command and add `-f compose.transcriptions.yaml` before `up`. If your `.env` sets `COMPOSE_FILE`, you can append the transcript overlay to that list. The first worker build downloads the English speech recognition model.

For a shared deployment, build the image from `docker/transcription`, set the worker’s `LIVEKIT_URL` to its LiveKit WebSocket address, and give the worker and Devloom the same private `TRANSCRIPTION_SECRET`. Set Devloom’s `TRANSCRIPTION_URL` to the worker’s private HTTP(S) origin on port 8095. Keep the worker’s control port reachable only from Devloom.
