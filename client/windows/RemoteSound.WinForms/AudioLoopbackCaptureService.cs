using NAudio.CoreAudioApi;
using NAudio.Wave;

namespace RemoteSound.WinForms;

internal sealed class AudioLoopbackCaptureService : IDisposable
{
    private readonly object _gate = new();
    private readonly StereoPcm16Resampler _resampler = new(RemoteSoundWebSocketClient.TargetSampleRate);
    private readonly PcmFrameAccumulator _accumulator = new(RemoteSoundWebSocketClient.FrameBytes);
    private WasapiLoopbackCapture? _capture;
    private float _gain = 1f;
    private bool _isDisposed;

    public event Action<byte[]>? FrameReady;
    public event Action<float>? LevelChanged;
    public event Action<string>? Log;

    public bool IsRunning => _capture is not null;

    public float Gain
    {
        get
        {
            lock (_gate)
            {
                return _gain;
            }
        }
        set
        {
            lock (_gate)
            {
                _gain = Math.Clamp(value, 0f, 3f);
            }
        }
    }

    public void Start(string? renderDeviceId, float gain)
    {
        ThrowIfDisposed();
        Stop();

        Gain = gain;
        _resampler.Reset();
        _accumulator.Clear();

        var device = ResolveRenderDevice(renderDeviceId);
        var capture = new WasapiLoopbackCapture(device);
        capture.DataAvailable += OnDataAvailable;
        capture.RecordingStopped += OnRecordingStopped;
        capture.StartRecording();
        _capture = capture;

        Log?.Invoke($"Capturing speaker output: {device.FriendlyName}");
        Log?.Invoke($"Source format: {capture.WaveFormat.SampleRate} Hz, {capture.WaveFormat.Channels} ch, {capture.WaveFormat.BitsPerSample} bit, {capture.WaveFormat.Encoding}");
    }

    public void Stop()
    {
        WasapiLoopbackCapture? capture;
        lock (_gate)
        {
            capture = _capture;
            _capture = null;
        }

        if (capture is null)
        {
            return;
        }

        try
        {
            capture.DataAvailable -= OnDataAvailable;
            capture.RecordingStopped -= OnRecordingStopped;
            capture.StopRecording();
        }
        catch
        {
        }
        finally
        {
            capture.Dispose();
        }

        _accumulator.Clear();
        _resampler.Reset();
        Log?.Invoke("Speaker capture stopped.");
    }

    public static List<AudioDeviceInfo> GetRenderDevices()
    {
        using var enumerator = new MMDeviceEnumerator();
        var defaultId = string.Empty;
        try
        {
            defaultId = enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia).ID;
        }
        catch
        {
        }

        return enumerator
            .EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active)
            .Select(device => new AudioDeviceInfo
            {
                Id = device.ID,
                Name = device.FriendlyName,
                IsDefault = string.Equals(device.ID, defaultId, StringComparison.OrdinalIgnoreCase),
            })
            .OrderByDescending(x => x.IsDefault)
            .ThenBy(x => x.Name, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    private static MMDevice ResolveRenderDevice(string? renderDeviceId)
    {
        var enumerator = new MMDeviceEnumerator();
        if (!string.IsNullOrWhiteSpace(renderDeviceId))
        {
            try
            {
                return enumerator.GetDevice(renderDeviceId);
            }
            catch
            {
                enumerator.Dispose();
                enumerator = new MMDeviceEnumerator();
            }
        }

        return enumerator.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
    }

    private void OnDataAvailable(object? sender, WaveInEventArgs e)
    {
        try
        {
            WasapiLoopbackCapture? capture;
            float gain;
            lock (_gate)
            {
                capture = _capture;
                gain = _gain;
            }

            if (capture is null || e.BytesRecorded <= 0)
            {
                return;
            }

            var pcmBytes = _resampler.Convert(e.Buffer.AsSpan(0, e.BytesRecorded), capture.WaveFormat, gain, out var peak);
            if (pcmBytes.Length == 0)
            {
                return;
            }

            LevelChanged?.Invoke(Math.Clamp(peak, 0f, 1f));
            foreach (var frame in _accumulator.Push(pcmBytes))
            {
                FrameReady?.Invoke(frame);
            }
        }
        catch (Exception ex)
        {
            Log?.Invoke("Capture conversion failed: " + ex.Message);
        }
    }

    private void OnRecordingStopped(object? sender, StoppedEventArgs e)
    {
        if (e.Exception is not null)
        {
            Log?.Invoke("Capture stopped with error: " + e.Exception.Message);
        }
    }

    private void ThrowIfDisposed()
    {
        if (_isDisposed)
        {
            throw new ObjectDisposedException(nameof(AudioLoopbackCaptureService));
        }
    }

    public void Dispose()
    {
        if (_isDisposed)
        {
            return;
        }

        _isDisposed = true;
        Stop();
    }
}
