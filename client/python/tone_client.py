import argparse
import asyncio
import contextlib
import json
import math
from typing import Optional

import numpy as np
import websockets

SAMPLE_RATE = 48_000
CHANNELS = 2
FRAME_SAMPLES = 960
FRAME_DURATION_SECONDS = FRAME_SAMPLES / SAMPLE_RATE
WAVEFORMS = ("sine", "square", "sawtooth", "triangle")


def make_client_id(prefix: str, index: int) -> str:
    return f"{prefix}-{index:02d}"


def make_client_name(prefix: str, index: int) -> str:
    return f"{prefix} {index}"


def make_waveform(phase: float, frequency: float, waveform: str) -> np.ndarray:
    time_axis = (np.arange(FRAME_SAMPLES, dtype=np.float32) + phase) / SAMPLE_RATE
    radians = 2.0 * math.pi * frequency * time_axis

    if waveform == "square":
        return np.where(np.sin(radians) >= 0, 1.0, -1.0).astype(np.float32, copy=False)

    if waveform == "sawtooth":
        fractional = np.mod(frequency * time_axis, 1.0)
        return ((fractional * 2.0) - 1.0).astype(np.float32, copy=False)

    if waveform == "triangle":
        fractional = np.mod(frequency * time_axis, 1.0)
        return (2.0 * np.abs((2.0 * fractional) - 1.0) - 1.0).astype(np.float32, copy=False)

    return np.sin(radians).astype(np.float32, copy=False)


def make_frame(phase: float, frequency: float, gain: float, waveform: str) -> tuple[bytes, float]:
    raw_waveform = make_waveform(phase, frequency, waveform) * gain
    pcm = np.clip(raw_waveform, -1.0, 1.0)
    stereo_pcm = np.column_stack((pcm, pcm)).astype(np.float32, copy=False)
    payload = (stereo_pcm * 32767.0).astype("<i2", copy=False).tobytes()
    next_phase = (phase + FRAME_SAMPLES) % SAMPLE_RATE
    return payload, next_phase


async def receiver(ws, label: str) -> None:
    async for message in ws:
        if isinstance(message, bytes):
            continue

        try:
            event = json.loads(message)
            print(f"[{label}] {event.get('type', 'event')}: {event.get('message', '')}")
        except json.JSONDecodeError:
            print(f"[{label}] {message}")


async def send_tone_stream(
    uri: str,
    name: str,
    client_id: str,
    frequency: float,
    gain: float,
    waveform: str,
    duration: Optional[float],
) -> None:
    async with websockets.connect(uri, max_size=65_536) as ws:
        hello = {
            "type": "hello",
            "name": name,
            "clientID": client_id,
            "sampleRate": SAMPLE_RATE,
            "channels": CHANNELS,
            "codec": "pcm_s16le",
            "frameSamples": FRAME_SAMPLES,
        }
        await ws.send(json.dumps(hello))

        print(f"[{name}] streaming {waveform} {frequency:.1f} Hz tone to {uri} as {client_id}")
        receiver_task = asyncio.create_task(receiver(ws, name))
        phase = 0.0
        start_time = asyncio.get_running_loop().time()

        try:
            while True:
                if duration is not None and (asyncio.get_running_loop().time() - start_time) >= duration:
                    break

                payload, phase = make_frame(phase, frequency, gain, waveform)
                await ws.send(payload)
                await asyncio.sleep(FRAME_DURATION_SECONDS)
        finally:
            receiver_task.cancel()
            with contextlib.suppress(asyncio.CancelledError):
                await receiver_task


async def run_many(uri: str, prefix: str, client_id_prefix: str, count: int, base_frequency: float, frequency_step: float, gain: float, waveform: str, duration: Optional[float]) -> None:
    tasks = []
    for index in range(1, count + 1):
        name = make_client_name(prefix, index)
        client_id = make_client_id(client_id_prefix, index)
        frequency = base_frequency + ((index - 1) * frequency_step)
        tasks.append(
            asyncio.create_task(
                send_tone_stream(
                    uri=uri,
                    name=name,
                    client_id=client_id,
                    frequency=frequency,
                    gain=gain,
                    waveform=waveform,
                    duration=duration,
                )
            )
        )

    try:
        await asyncio.gather(*tasks)
    finally:
        for task in tasks:
            task.cancel()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Generate deterministic tone sources for RemoteSound.")
    parser.add_argument("--host", required=True, help="RemoteSound iOS device IP address")
    parser.add_argument("--port", type=int, default=8765, help="RemoteSound WebSocket port")
    parser.add_argument("--count", type=int, default=1, help="How many simultaneous tone sources to open")
    parser.add_argument("--name-prefix", default="Tone Source", help="Display name prefix used inside RemoteSound")
    parser.add_argument("--client-id-prefix", default="tone-source", help="Stable clientID prefix used for reconnect-safe sources")
    parser.add_argument("--base-frequency", type=float, default=220.0, help="Frequency in Hz used by the first source")
    parser.add_argument("--frequency-step", type=float, default=110.0, help="Hz increment added for each additional source")
    parser.add_argument("--gain", type=float, default=0.3, help="Linear tone gain from 0.0 to 1.0")
    parser.add_argument("--waveform", choices=WAVEFORMS, default="sine", help="Waveform used by every synthetic source")
    parser.add_argument("--duration", type=float, default=None, help="Optional duration in seconds before stopping")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    uri = f"ws://{args.host}:{args.port}"

    try:
        asyncio.run(
            run_many(
                uri=uri,
                prefix=args.name_prefix,
                client_id_prefix=args.client_id_prefix,
                count=args.count,
                base_frequency=args.base_frequency,
                frequency_step=args.frequency_step,
                gain=args.gain,
                waveform=args.waveform,
                duration=args.duration,
            )
        )
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
