# NVENC Usage Guide (Electron v36.9.5-qp20)

This note answers the "now what?" question once the custom Electron bits are installed. It collects the practical knobs for driving NVIDIA's hardware encoder through Chromium surfaces and shows how to verify that the NVENC path is live.

---

## 1. Prerequisites

- Run on a machine with an NVENC-capable GPU (Kepler or newer) and current NVIDIA drivers.
- Ship `nvEncodeAPI64.dll` alongside the Windows release (`out\Release-win\nvEncodeAPI64.dll`); **do not** remove it from the final zip (see `AGENTS.md:73-76`).
- Keep Electron hardware acceleration enabled. Every NVENC workflow relies on the GPU process; calling `app.disableHardwareAcceleration()` forces a software encoder.
- Linux builds include the FFmpeg NVENC encoder, but Chromium still prefers VAAPI/CPU paths. Treat NVENC as **Windows-only** inside Electron unless you are invoking FFmpeg directly.
- Our QP-clamp patches leave plenty of bitrate headroom, so configure realistic bitrates (≥ 8 Mbps for 1080p60) to avoid triggering fallback heuristics.

Validation tips:
- Use `chrome://media-internals` (MediaRecorder/WebCodecs) or `chrome://webrtc-internals` (WebRTC) to confirm the encoder implementation is HW backed.
- If a path keeps falling back to software, collect GPU info with `chrome://gpu` and double-check driver + resolve/bitrate combos.

---

## 2. MediaRecorder

Chromium binds MediaRecorder to the `VideoEncodeAcceleratorAdapter`, which prefers hardware when the OS exposes it (`third_party/blink/renderer/modules/mediarecorder/video_track_recorder.cc:300-319`).

1. **Request H.264 or HEVC** – e.g.:
   ```js
   const mimeType = 'video/mp4;codecs="avc1.640028"';
   if (!MediaRecorder.isTypeSupported(mimeType)) throw new Error('H.264 not available');
   const recorder = new MediaRecorder(stream, {
     mimeType,
     videoBitsPerSecond: 20_000_000,
   });
   ```
   HEVC works similarly with `video/mp4;codecs="hvc1.1.6.L123.B0"`, assuming the GPU advertises the profile.

2. Monitor `chrome://media-internals`:
   - Look at the recorder's entry. `VideoEncoder` should report `GpuVideoAccelerator` / `MediaFoundationVideoEncodeAccelerator` and `Implementation: Hardware`.
   - Delivered frames should stay near real time. A sudden jump in `Dropped Frames` points at fallback or driver throttling.

3. Common fallback causes:
   - Extremely low bitrates (< 2 Mbps) or odd resolutions force software.
   - The GPU driver hides HEVC when the machine lacks the paid license. Stick to H.264 in that case.

---

## 3. WebCodecs `VideoEncoder`

WebCodecs routes through the same accelerator layer when `hardwareAcceleration` requests it (`third_party/blink/renderer/modules/webcodecs/video_encoder.cc:655-673`).

```js
const config = {
  codec: 'avc1.640028',             // or 'hvc1.1.6.L123.B0', 'av01.0.12M.10.0.110.09' if NVENC AV1 is supported
  width,
  height,
  bitrate: 15_000_000,
  framerate: 60,
  hardwareAcceleration: 'require-hardware',
};

const {supported, config: resolved} = await VideoEncoder.isConfigSupported(config);
if (!supported) throw new Error(resolved.notSupportedErrorMessage);

const encoder = new VideoEncoder({
  output: chunk => {/* mux or transmit chunk */},
  error: e => console.error(e),
});
encoder.configure(resolved);
```

While encoding, inspect:
- `encoder.encodeQueueSize` – should stay low when hardware keeps up.
- `chunk.metadata.encoderImplementation` – recent Chromium builds mark hardware instances as `MediaFoundationVideoEncoder`.
- `chrome://media-internals` – same cues as MediaRecorder.

If `isConfigSupported` returns unsupported, the driver likely does not expose that codec/profile pair. Drop to `hardwareAcceleration: 'prefer-hardware'` and allow fallback, or switch to a supported codec.

---

## 4. WebRTC / RTCPeerConnection

WebRTC uses the Chromium encoder factory to enumerate GPU-backed profiles (`third_party/blink/renderer/platform/peerconnection/rtc_video_encoder_factory.cc:282-349`). To steer toward NVENC:

1. Prefer H.264 in SDP:
   ```js
   const pc = new RTCPeerConnection();
   const sender = pc.addTrack(stream.getVideoTracks()[0], stream);
   const h264Caps = RTCRtpSender.getCapabilities('video').codecs
       .filter(codec => codec.mimeType === 'video/H264');
   sender.setCodecPreferences(h264Caps);
   ```
   HEVC works if both sides advertise it; AV1 is still experimental in NVENC.

2. Optionally raise the bitrate using sender parameters:
   ```js
   const params = sender.getParameters();
   params.encodings = [{maxBitrate: 20_000_000}];
   await sender.setParameters(params);
   ```

3. During a live call, open `chrome://webrtc-internals`:
   - Find the peer connection and look for `videoEncoderImplementationName` or `EncoderImplementation`. Expect `Hardware`/`MediaFoundationVideoEncoder` with vendor `NVIDIA`.
   - Inspect `qpSum` / `framesEncoded` to see the patched QP range (should bottom out near 0 when bitrate is high).

If you still see software encoders:
- Ensure the captured frame size is aligned (NVENC dislikes some uncommon resolutions).
- Confirm bandwidth/bitrate is not set below ~3 Mbps for 1080p.
- Check that no SDP munging reorders VP8/VP9 ahead of H.264.

---

## 5. Troubleshooting Checklist

| Symptom | Likely Cause | Fix |
| --- | --- | --- |
| `MediaRecorder` reports software encoder | GPU driver missing NVENC profile, resolution unsupported, or bitrate too low | Update drivers, adjust resolution/bitrate, confirm hardware acceleration is enabled |
| `VideoEncoder.isConfigSupported()` fails | Codec/profile not exposed by NVENC | Switch to H.264 baseline/high or HEVC main, or drop to `prefer-hardware` |
| `chrome://webrtc-internals` shows software | Codec preferences include VP8/VP9, or network constraints too aggressive | Force H.264 preferences, increase `maxBitrate`, verify remote SDP honors the selection |
| Runtime error loading NVENC DLL | `nvEncodeAPI64.dll` missing from release zip | Copy the DLL from `%WINDIR%\System32` into `out\Release-win` before packaging |
| High QP despite high bitrate | Bitrate cap too low or stream constrained by resolution/framerate | Increase `videoBitsPerSecond` / `bitrate`, verify patch is applied (`media/gpu/windows/mf_video_encoder_util.h:86-112`) |

For deeper investigation, capture Chromium logs with `--enable-logging --v=1` to surface encoder selection messages.

---

## 6. References

- FFmpeg NVENC enablement (`patches/ffmpeg/enable-nvenc.patch:1`).
- QP clamp adjustments (`patches/qp-cap/chromium-max-qp.patch:1`, `patches/qp-cap/webrtc-max-qp.patch:1`).
- MediaRecorder hardware encoder selection (`third_party/blink/renderer/modules/mediarecorder/video_track_recorder.cc:300-319`).
- WebCodecs hardware preference parsing (`third_party/blink/renderer/modules/webcodecs/video_encoder.cc:655-673`).
- WebRTC GPU encoder enumeration (`third_party/blink/renderer/platform/peerconnection/rtc_video_encoder_factory.cc:282-349`).
