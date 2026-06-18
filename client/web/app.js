const SAMPLE_RATE = 48_000;
const FRAME_SAMPLES = 960;
const CHANNELS = 2;

const urlInput = document.querySelector("#url");
const modeInput = document.querySelector("#mode");
const nameInput = document.querySelector("#name");
const clientIdInput = document.querySelector("#clientId");
const newClientIdButton = document.querySelector("#newClientId");
const gainInput = document.querySelector("#gain");
const frequencyInput = document.querySelector("#frequency");
const waveformInput = document.querySelector("#waveform");
const connectButton = document.querySelector("#connect");
const disconnectButton = document.querySelector("#disconnect");
const levelMeter = document.querySelector("#level");
const logElement = document.querySelector("#log");

let audioContext;
let mediaStream;
let sourceNode;
let workletNode;
let websocket;
let oscillatorNode;
const clientIdKey = "remotesound-client-id";

function log(message) {
  const timestamp = new Date().toLocaleTimeString();
  logElement.textContent = `[${timestamp}] ${message}\n${logElement.textContent}`.trim();
}

function setConnectedState(isConnected) {
  connectButton.disabled = isConnected;
  disconnectButton.disabled = !isConnected;
}

function getStableClientId() {
  const existing = window.sessionStorage.getItem(clientIdKey);
  if (existing) {
    return existing;
  }

  const generated = crypto.randomUUID();
  window.sessionStorage.setItem(clientIdKey, generated);
  return generated;
}

function setStableClientId(value) {
  window.sessionStorage.setItem(clientIdKey, value);
  clientIdInput.value = value;
}

async function ensureAudioPipeline() {
  if (!audioContext) {
    audioContext = new AudioContext({ sampleRate: SAMPLE_RATE, latencyHint: "interactive" });
    await audioContext.audioWorklet.addModule("./pcm-processor.js");
  }

  if (audioContext.state === "suspended") {
    await audioContext.resume();
  }

  if (!workletNode) {
    workletNode = new AudioWorkletNode(audioContext, "pcm-capture-processor", {
      processorOptions: { frameSamples: FRAME_SAMPLES, channels: CHANNELS },
      numberOfInputs: 1,
      numberOfOutputs: 0,
      channelCount: CHANNELS,
    });

    workletNode.port.onmessage = ({ data }) => {
      if (!websocket || websocket.readyState !== WebSocket.OPEN) {
        return;
      }

      if (data.type === "level") {
        levelMeter.value = data.value;
        return;
      }

      if (data.type === "audio") {
        websocket.send(data.payload);
      }
    };
  }

  await ensureSelectedSource();

  workletNode.port.postMessage({
    type: "gain",
    value: Number.parseFloat(gainInput.value) || 1,
  });
}

async function ensureSelectedSource() {
  const mode = modeInput.value;

  if (sourceNode) {
    sourceNode.disconnect();
    sourceNode = undefined;
  }

  if (oscillatorNode) {
    oscillatorNode.stop();
    oscillatorNode.disconnect();
    oscillatorNode = undefined;
  }

  if (mode === "microphone") {
    if (!mediaStream) {
      mediaStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          channelCount: CHANNELS,
          echoCancellation: false,
          noiseSuppression: false,
          autoGainControl: false,
          sampleRate: SAMPLE_RATE,
        },
      });
    }

    sourceNode = audioContext.createMediaStreamSource(mediaStream);
    sourceNode.connect(workletNode);
    return;
  }

  oscillatorNode = new OscillatorNode(audioContext, {
    type: waveformInput.value,
    frequency: Number.parseFloat(frequencyInput.value) || 440,
  });
  sourceNode = oscillatorNode;
  sourceNode.connect(workletNode);
  oscillatorNode.start();
}

async function connect() {
  await ensureAudioPipeline();

  websocket = new WebSocket(urlInput.value);
  websocket.binaryType = "arraybuffer";

  websocket.addEventListener("open", () => {
    const hello = {
      type: "hello",
      name: nameInput.value || (modeInput.value === "tone" ? "Browser Tone" : "Browser Client"),
      clientID: clientIdInput.value || getStableClientId(),
      sampleRate: SAMPLE_RATE,
      channels: CHANNELS,
      codec: "pcm_s16le",
      frameSamples: FRAME_SAMPLES,
    };

    websocket.send(JSON.stringify(hello));
    setConnectedState(true);
    log(`Connected to ${urlInput.value}`);
  });

  websocket.addEventListener("message", (event) => {
    if (typeof event.data !== "string") {
      return;
    }

    try {
      const payload = JSON.parse(event.data);
      log(`[${payload.type}] ${payload.message}`);
    } catch {
      log(event.data);
    }
  });

  websocket.addEventListener("close", () => {
    setConnectedState(false);
    levelMeter.value = 0;
    log("Disconnected.");
    websocket = undefined;
  });

  websocket.addEventListener("error", () => {
    log("WebSocket error.");
  });
}

async function disconnect() {
  if (websocket && websocket.readyState <= WebSocket.OPEN) {
    websocket.close();
  }
}

connectButton.addEventListener("click", async () => {
  try {
    await connect();
  } catch (error) {
    log(`Failed to start: ${error.message}`);
  }
});

disconnectButton.addEventListener("click", async () => {
  await disconnect();
});

gainInput.addEventListener("input", () => {
  if (!workletNode) {
    return;
  }

  workletNode.port.postMessage({
    type: "gain",
    value: Number.parseFloat(gainInput.value) || 1,
  });
});

frequencyInput.addEventListener("input", () => {
  if (!oscillatorNode) {
    return;
  }

  oscillatorNode.frequency.value = Number.parseFloat(frequencyInput.value) || 440;
});

modeInput.addEventListener("input", async () => {
  if (!audioContext) {
    return;
  }

  await ensureSelectedSource();
});

waveformInput.addEventListener("input", async () => {
  if (!audioContext || modeInput.value !== "tone") {
    return;
  }

  await ensureSelectedSource();
});

clientIdInput.addEventListener("change", () => {
  const nextValue = clientIdInput.value.trim() || crypto.randomUUID();
  setStableClientId(nextValue);
  log(`Client ID set to ${nextValue}`);
});

newClientIdButton.addEventListener("click", () => {
  const nextValue = crypto.randomUUID();
  setStableClientId(nextValue);
  log(`Generated new client ID ${nextValue}`);
});

setStableClientId(getStableClientId());

window.addEventListener("beforeunload", () => {
  disconnect();
});
