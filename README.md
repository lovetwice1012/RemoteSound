# RemoteSound

RemoteSound is an iOS mixer app that connects to a LAN WebSocket audio source, mixes the received stream into the speaker output, and lets you change the source's enable state, volume, and EQ in real time.

## What is included

- An iOS app scaffold driven by [`project.yml`](/C:/Users/yussy/Documents/RemoteSound/project.yml) with SwiftUI, `AVAudioEngine`, and a WebSocket receiving client.
- A per-source audio chain: `AVAudioPlayerNode -> AVAudioUnitEQ -> AVAudioMixerNode -> main mixer`.
- A lightweight per-source jitter buffer so short Wi-Fi timing swings do not immediately underrun playback.
- Runtime controls for enable or mute, gain, and a fixed three-band EQ per connected source.
- A Windows speaker loopback server in [`client/windows/RemoteSound.WinForms`](/C:/Users/yussy/Documents/RemoteSound/client/windows/RemoteSound.WinForms) that accepts the iPhone connection and streams speaker audio.
- Legacy Python and browser clients are still present, but they target the previous iPhone-as-server transport.

## Protocol

RemoteSound currently expects:

- WebSocket transport on `ws://<windows-pc-ip>:8765/`
- The Windows source sends one UTF-8 JSON `hello` message first
- Include a stable `clientID` if you want the iOS app to restore that source's settings after reconnecting
- The Windows source then sends audio frames as binary `pcm_s16le`
- 48 kHz
- Stereo
- 960 samples per frame

Example hello payload:

```json
{
  "type": "hello",
  "name": "Studio Laptop",
  "clientID": "47c5cefe-93e0-4b20-b95c-7c29895fd94b",
  "sampleRate": 48000,
  "channels": 2,
  "codec": "pcm_s16le",
  "frameSamples": 960
}
```

## iOS setup

1. Install Xcode 16+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).
2. From the repo root, run `xcodegen generate`.
3. Open the generated `RemoteSound.xcodeproj`.
4. Set your team and bundle identifier in [`project.yml`](/C:/Users/yussy/Documents/RemoteSound/project.yml) if needed.
5. Build to a physical iPhone or iPad on the same local network as the Windows audio server.
6. Allow Local Network access when prompted.
7. Keep the app's audio session active so playback can continue in the background.

The app already declares `UIBackgroundModes = audio` and configures `AVAudioSession` for playback.

## Windows speaker server setup

1. Build and run [`client/windows/RemoteSound.WinForms`](/C:/Users/yussy/Documents/RemoteSound/client/windows/RemoteSound.WinForms).
2. Choose the speaker device and listen port. The default port is `8765`.
3. Click `Start`.
4. The Windows app advertises `_remoteaudio._tcp` on the local network. The iOS app auto-connects when discovery is enabled.
5. If discovery is blocked by the network, copy one of the logged `ws://<pc-ip>:8765/` URLs into the iOS app and tap `Connect`.

The Windows app captures speaker loopback audio with WASAPI, resamples to 48 kHz stereo PCM16, and streams frames to the connected iPhone.

## Legacy Python client setup

1. Install Python 3.11+.
2. Create a virtual environment if you want one.
3. Run `pip install -r client/python/requirements.txt`.
4. Start streaming:

```bash
python client/python/stream_client.py --host 192.168.1.24 --name "Office Laptop"
```

Optional flags:

- `--port 8765`
- `--client-id my-stable-room-mic`
- `--device "<input device name>"`
- `--gain 1.25`
- `--list-devices`

The Python client stores a stable ID in `~/.remotesound-client-id` unless you override it with `--client-id`.

## Legacy Python tone client setup

Use the tone client when you want deterministic, repeatable mixer tests without relying on microphone capture.

Example: open three simultaneous tone sources with different pitches:

```bash
python client/python/tone_client.py --host 192.168.1.24 --count 3 --base-frequency 220 --frequency-step 110
```

Useful flags:

- `--duration 30`
- `--gain 0.2`
- `--name-prefix "Rack Tone"`
- `--client-id-prefix rack-tone`
- `--waveform square`

This is the easiest way to verify that:

- multiple WS sources appear simultaneously
- per-source mute and volume work independently
- EQ changes audibly affect only the selected source
- reconnecting the same synthetic source restores its saved settings

The browser client can do a lighter-weight version of the same test by setting `Source Mode` to `Synthetic Tone`, choosing a different frequency on each device or browser tab, and optionally switching the waveform for stronger EQ contrast. Each tab now gets its own default `clientID`, and you can also override it manually from the page.

## Legacy browser client setup

1. Use a modern browser with `getUserMedia`, `getDisplayMedia`, and `AudioWorklet` support. Chrome or Edge is recommended for speaker/tab-audio capture.
2. Serve [`client/web`](/C:/Users/yussy/Documents/RemoteSound/client/web/index.html) from `localhost` or another secure origin.
3. Open the page, enter the iOS device `ws://` URL shown by RemoteSound, then choose `Microphone`, `Speaker / Tab Audio`, or `Synthetic Tone`.
4. If you choose `Microphone`, allow microphone access. If you choose `Speaker / Tab Audio`, select a tab/window/screen in the browser picker and enable audio sharing. If you choose `Synthetic Tone`, set the test frequency and waveform you want to hear.
5. Use the `Client ID` field if you want a tab to deliberately reconnect as the same saved source, or click `New` to force a fresh source identity.

Example local server:

```bash
python -m http.server 8080 --directory client/web
```

Then open [http://localhost:8080](http://localhost:8080).

## Runtime behavior

- The connected Windows source appears in the SwiftUI list after the iPhone receives the source hello message.
- Volume changes apply on the source mixer node immediately.
- EQ changes update a dedicated `AVAudioUnitEQ` for that source.
- Disabling a source mutes it without dropping the WebSocket connection.
- Source playback waits for a few buffers before starting so multiple clients survive mild LAN jitter better.
- Per-source mute, gain, and EQ settings are restored when a client reconnects with the same `clientID`.
- If the same `clientID` reconnects, RemoteSound promotes the newest connection and retires the older one.
- The detail view shows queued buffers, dropped frames, received frame count, and the last frame timestamp for each live source.
- The iOS app automatically reconnects to the configured Windows source if the WebSocket drops while the app is supposed to stay connected.
- Operators can reset a source's saved mix settings or disconnect that source directly from the detail pane.
- The app observes audio-session interruptions and route changes, then tries to reactivate playback when the app becomes active again.

## Suggested verification flow

1. Start the Windows speaker server.
2. Launch the iOS app on a physical device and leave `Auto-connect discovered source` enabled.
3. Confirm the Windows source appears in the list.
4. Play audio on Windows and verify it plays through the iPhone.
5. Send the iOS app to the Home screen and verify playback continues.
6. Return to the app and verify the source is still connected.

## Important iOS constraints

- Background audio playback is supported by the current configuration.
- iOS now acts as an outbound WebSocket client instead of a LAN server, which better matches iOS background audio behavior.
- Discovery uses Bonjour/mDNS service type `_remoteaudio._tcp`. Some guest Wi-Fi networks block multicast discovery; manual `ws://` entry remains available for those networks.
- The current implementation intentionally keeps the streaming format fixed at 48 kHz stereo PCM16 to keep the mixer simple and predictable.

## Next upgrades I recommend

- Add adaptive drift correction instead of the current fixed lead-buffer approach if clients will connect over unstable Wi-Fi.
- Add per-source latency meters and clipping indicators.
- Persist per-source EQ presets.
- Add a visible discovered-source list if multiple Windows senders are expected on the same LAN.
