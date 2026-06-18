import argparse
import asyncio
import json
import queue
import socket
import sys
from pathlib import Path
from typing import Optional
from uuid import uuid4

import sounddevice as sd
import websockets

SAMPLE_RATE = 48_000
CHANNELS = 2
FRAME_SAMPLES = 960


def default_client_name() -> str:
    return f"{socket.gethostname()} ({sys.platform})"


def default_client_id() -> str:
    storage_path = Path.home() / ".remotesound-client-id"
    if storage_path.exists():
        value = storage_path.read_text(encoding="utf-8").strip()
        if value:
            return value

    value = str(uuid4())
    storage_path.write_text(value, encoding="utf-8")
    return value


async def sender(ws, audio_queue: "asyncio.Queue[bytes]") -> None:
    while True:
        payload = await audio_queue.get()
        await ws.send(payload)


async def receiver(ws) -> None:
    async for message in ws:
        if isinstance(message, bytes):
            continue

        try:
            event = json.loads(message)
        except json.JSONDecodeError:
            print(f"[server] {message}")
            continue

        event_type = event.get("type", "event")
        detail = event.get("message", "")
        print(f"[{event_type}] {detail}")


async def stream_microphone(uri: str, client_name: str, client_id: str, device_name: Optional[str], gain: float) -> None:
    loop = asyncio.get_running_loop()
    audio_queue: "asyncio.Queue[bytes]" = asyncio.Queue(maxsize=24)
    callback_errors: "queue.Queue[str]" = queue.Queue()

    def push_audio(indata, frames, time_info, status) -> None:
        del time_info

        if status:
            callback_errors.put(str(status))

        if frames == 0:
            return

        if indata.ndim != 2 or indata.shape[1] < CHANNELS:
            callback_errors.put(f"expected {CHANNELS} input channels, got shape={indata.shape}")
            return

        scaled = (indata[:, :CHANNELS] * gain).clip(-1.0, 1.0)
        pcm = (scaled * 32767.0).astype("<i2", copy=False).tobytes()

        def enqueue() -> None:
            if audio_queue.full():
                try:
                    audio_queue.get_nowait()
                except asyncio.QueueEmpty:
                    pass

            audio_queue.put_nowait(pcm)

        loop.call_soon_threadsafe(enqueue)

    async with websockets.connect(uri, max_size=65_536) as ws:
        hello = {
            "type": "hello",
            "name": client_name,
            "clientID": client_id,
            "sampleRate": SAMPLE_RATE,
            "channels": CHANNELS,
            "codec": "pcm_s16le",
            "frameSamples": FRAME_SAMPLES,
        }
        await ws.send(json.dumps(hello))

        stream = sd.InputStream(
            samplerate=SAMPLE_RATE,
            blocksize=FRAME_SAMPLES,
            channels=CHANNELS,
            dtype="float32",
            device=device_name,
            callback=push_audio,
        )

        print(f"Streaming microphone to {uri} as {client_name}")
        if device_name:
            print(f"Input device: {device_name}")

        with stream:
            await asyncio.gather(sender(ws, audio_queue), receiver(ws))

        while not callback_errors.empty():
            print(f"[audio] {callback_errors.get()}")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Stream microphone audio to RemoteSound over WebSocket.")
    parser.add_argument("--host", required=True, help="RemoteSound iOS device IP address")
    parser.add_argument("--port", type=int, default=8765, help="RemoteSound WebSocket port")
    parser.add_argument("--name", default=default_client_name(), help="Display name shown inside RemoteSound")
    parser.add_argument("--client-id", default=default_client_id(), help="Stable client identifier used by RemoteSound to restore settings")
    parser.add_argument("--device", default=None, help="Optional sounddevice input device name")
    parser.add_argument("--gain", type=float, default=1.0, help="Client-side microphone gain")
    parser.add_argument("--list-devices", action="store_true", help="Print available input devices and exit")
    return parser.parse_args()


def main() -> None:
    args = parse_args()

    if args.list_devices:
        print(sd.query_devices())
        return

    uri = f"ws://{args.host}:{args.port}"

    try:
        asyncio.run(stream_microphone(uri, args.name, args.client_id, args.device, args.gain))
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
