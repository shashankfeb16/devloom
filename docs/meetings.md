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
