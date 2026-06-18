class PcmCaptureProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.frameSamples = options.processorOptions.frameSamples ?? 960;
    this.channels = options.processorOptions.channels ?? 2;
    this.gain = 1;
    this.pending = new Float32Array(this.frameSamples * this.channels);
    this.pendingFrames = 0;

    this.port.onmessage = ({ data }) => {
      if (data.type === "gain") {
        this.gain = Number(data.value) || 1;
      }
    };
  }

  process(inputs) {
    const input = inputs[0];
    if (!input || input.length === 0) {
      return true;
    }

    const left = input[0];
    const right = input[1] ?? left;
    if (!left) {
      return true;
    }

    let peak = 0;
    for (let index = 0; index < left.length; index += 1) {
      const leftSample = Math.max(-1, Math.min(1, left[index] * this.gain));
      const rightSample = Math.max(-1, Math.min(1, right[index] * this.gain));
      peak = Math.max(peak, Math.abs(leftSample), Math.abs(rightSample));

      const pendingOffset = this.pendingFrames * this.channels;
      this.pending[pendingOffset] = leftSample;
      this.pending[pendingOffset + 1] = rightSample;
      this.pendingFrames += 1;

      if (this.pendingFrames === this.frameSamples) {
        const payload = new Int16Array(this.frameSamples * this.channels);
        for (let frame = 0; frame < this.frameSamples; frame += 1) {
          const frameOffset = frame * this.channels;
          payload[frameOffset] = Math.max(-32768, Math.min(32767, Math.round(this.pending[frameOffset] * 32767)));
          payload[frameOffset + 1] = Math.max(-32768, Math.min(32767, Math.round(this.pending[frameOffset + 1] * 32767)));
        }

        this.port.postMessage({ type: "audio", payload: payload.buffer }, [payload.buffer]);
        this.pendingFrames = 0;
      }
    }

    this.port.postMessage({ type: "level", value: peak });
    return true;
  }
}

registerProcessor("pcm-capture-processor", PcmCaptureProcessor);
