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
let microphoneStream;
let displayStream;
let sourceNode;
let workletNode;
let websocket;
let oscillatorNode;
let activeMode;

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

function defaultSourceName(mode) {
  switch (mode) {
    case "speaker":
      return "Browser Speaker";
    case "tone":
      return "Browser Tone";
    case "microphone":
    default:
      return "Browser Client";
  }
}

function stopStream(stream) {
  if (!stream) {
    return;
  }

  for (const track of stream.getTracks()) {
    track.stop();
  }
}

function cleanupSource() {
  if (sourceNode) {
    sourceNode.disconnect();
    sourceNode = undefined;
  }

  if (oscillatorNode) {
    oscillatorNode.stop();
    oscillatorNode.disconnect();
    oscillatorNode = undefined;
  }

  stopStream(microphoneStream);
  microphoneStream = undefined;

  stopStream(displayStream);
  displayStream = undefined;

  activeMode = undefined;
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
      channelCountMode: "explicit",
      channelInterpretation: "speakers",
    });

    workletNode.port.onmessage = ({ data }) => {
      if (data.type === "level") {
        levelMeter.value = data.value;
        return;
      }

      if (!websocket || websocket.readyState !== WebSocket.OPEN) {
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

async function createMicrophoneStream() {
  return navigator.mediaDevices.getUserMedia({
    audio: {
      channelCount: CHANNELS,
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false,
      sampleRate: SAMPLE_RATE,
    },
  });
}

async function createSpeakerCaptureStream() {
  if (!navigator.mediaDevices?.getDisplayMedia) {
    throw new Error("This browser does not support speaker/tab audio capture with getDisplayMedia(). Use Chrome or Edge on a secure origin such as localhost.");
  }

  const stream = await navigator.mediaDevices.getDisplayMedia({
    video: true,
    audio: {
      channelCount: CHANNELS,
      echoCancellation: false,
      noiseSuppression: false,
      autoGainControl: false,
      sampleRate: SAMPLE_RATE,
    },
  });

  if (stream.getAudioTracks().length === 0) {
    stopStream(stream);
    throw new Error("No speaker audio track was shared. Select a tab/window/screen and enable Share audio in the browser picker.");
  }

  for (const track of stream.getTracks()) {
    track.addEventListener("ended", () => {
      if (displayStream === stream) {
        log("Speaker/tab audio capture ended.");
        disconnect();
      }
    });
  }

  return stream;
}

async function ensureSelectedSource() {
  const mode = modeInput.value;
  if (activeMode === mode && sourceNode) {
    return;
  }

  cleanupSource();

  if (mode === "microphone") {
    microphoneStream = await createMicrophoneStream();
    sourceNode = audioContext.createMediaStreamSource(microphoneStream);
    sourceNode.connect(workletNode);
    activeMode = mode;
    log("Using microphone input.");
    return;
  }

  if (mode === "speaker") {
    displayStream = await createSpeakerCaptureStream();
    sourceNode = audioContext.createMediaStreamSource(displayStream);
    sourceNode.connect(workletNode);
    activeMode = mode;
    log("Using speaker/tab audio capture.");
    return;
  }

  oscillatorNode = new OscillatorNode(audioContext, {
    type: waveformInput.value,
    frequency: Number.parseFloat(frequencyInput.value) || 440,
  });
  sourceNode = oscillatorNode;
  sourceNode.connect(workletNode);
  oscillatorNode.start();
  activeMode = mode;
  log("Using synthetic tone.");
}

async function connect() {
  await ensureAudioPipeline();

  websocket = new WebSocket(urlInput.value);
  websocket.binaryType = "arraybuffer";

  websocket.addEventListener("open", () => {
    const mode = modeInput.value;
    const hello = {
      type: "hello",
      name: nameInput.value || defaultSourceName(mode),
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
    cleanupSource();
  });

  websocket.addEventListener("error", () => {
    log("WebSocket error.");
  });
}

async function disconnect() {
  if (websocket && websocket.readyState <= WebSocket.OPEN) {
    websocket.close();
    return;
  }

  cleanupSource();
  setConnectedState(false);
  levelMeter.value = 0;
}

connectButton.addEventListener("click", async () => {
  try {
    await connect();
  } catch (error) {
    cleanupSource();
    setConnectedState(false);
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
  const defaultName = defaultSourceName(modeInput.value);
  if (!nameInput.value || ["Browser Client", "Browser Speaker", "Browser Tone"].includes(nameInput.value)) {
    nameInput.value = defaultName;
  }

  if (!audioContext || !workletNode) {
    return;
  }

  try {
    await ensureSelectedSource();
  } catch (error) {
    log(`Failed to switch source: ${error.message}`);
  }
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
