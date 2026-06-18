using System.Net;
using System.Net.Sockets;
using System.Text;
using NAudio.Wave;

namespace RemoteSound.WinForms;

internal sealed class RemoteSoundHlsServer : IDisposable
{
    private const int SampleRate = 48_000;
    private const int Channels = 2;
    private const int BitsPerSample = 16;
    private const int SegmentSeconds = 2;
    private const int SegmentBytes = SampleRate * Channels * (BitsPerSample / 8) * SegmentSeconds;
    private const int MaxSegments = 8;

    private readonly object _gate = new();
    private readonly List<byte> _pendingPcm = new(SegmentBytes * 2);
    private readonly Queue<HlsSegment> _segments = new();
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private Task? _serverTask;
    private int _nextSequence;
    private bool _isDisposed;

    public event Action<string>? Log;

    public bool IsRunning => _listener is not null;

    public void Start(int port)
    {
        ThrowIfDisposed();
        Stop();

        _cts = new CancellationTokenSource();
        var listener = new TcpListener(IPAddress.Any, port);
        listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        listener.Start();
        _listener = listener;
        _serverTask = Task.Run(() => AcceptLoopAsync(listener, _cts.Token));

        Log?.Invoke($"HLS stream listening on port {port}.");
        foreach (var url in GetListenUrls(port))
        {
            Log?.Invoke("Reliable iPhone URL: " + url);
        }
    }

    public void PushPcmFrame(byte[] frame)
    {
        if (frame.Length == 0)
        {
            return;
        }

        List<byte[]> readySegments = [];
        lock (_gate)
        {
            _pendingPcm.AddRange(frame);
            while (_pendingPcm.Count >= SegmentBytes)
            {
                var pcm = _pendingPcm.GetRange(0, SegmentBytes).ToArray();
                _pendingPcm.RemoveRange(0, SegmentBytes);
                readySegments.Add(pcm);
            }
        }

        foreach (var pcm in readySegments)
        {
            EncodeAndStoreSegment(pcm);
        }
    }

    public void Stop()
    {
        try
        {
            _cts?.Cancel();
            _listener?.Stop();
        }
        catch
        {
        }

        _listener = null;
        _cts?.Dispose();
        _cts = null;
        _serverTask = null;

        lock (_gate)
        {
            _pendingPcm.Clear();
            _segments.Clear();
            _nextSequence = 0;
        }
    }

    private void EncodeAndStoreSegment(byte[] pcm)
    {
        try
        {
            using var input = new MemoryStream(pcm);
            using var wave = new RawSourceWaveStream(input, new WaveFormat(SampleRate, BitsPerSample, Channels));
            using var output = new MemoryStream();
            MediaFoundationEncoder.EncodeToMp3(wave, output, 128_000);

            lock (_gate)
            {
                _segments.Enqueue(new HlsSegment(_nextSequence++, output.ToArray()));
                while (_segments.Count > MaxSegments)
                {
                    _segments.Dequeue();
                }
            }
        }
        catch (Exception ex)
        {
            Log?.Invoke("HLS segment encode failed: " + ex.Message);
        }
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var client = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
                _ = Task.Run(() => HandleClientAsync(client, cancellationToken), cancellationToken);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (ObjectDisposedException)
        {
        }
        catch (Exception ex)
        {
            Log?.Invoke("HLS server failed: " + ex.Message);
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken cancellationToken)
    {
        using var _ = client;
        try
        {
            var stream = client.GetStream();
            var request = await ReadRequestAsync(stream, cancellationToken).ConfigureAwait(false);
            var path = ParsePath(request);

            if (path.Equals("/stream.m3u8", StringComparison.OrdinalIgnoreCase) || path == "/")
            {
                await WriteResponseAsync(stream, "application/vnd.apple.mpegurl", Encoding.UTF8.GetBytes(BuildPlaylist()), cancellationToken).ConfigureAwait(false);
                return;
            }

            if (path.StartsWith("/segment-", StringComparison.OrdinalIgnoreCase) && path.EndsWith(".mp3", StringComparison.OrdinalIgnoreCase))
            {
                var sequenceText = path["/segment-".Length..^".mp3".Length];
                if (int.TryParse(sequenceText, out var sequence) && TryGetSegment(sequence, out var segment))
                {
                    await WriteResponseAsync(stream, "audio/mpeg", segment, cancellationToken).ConfigureAwait(false);
                    return;
                }
            }

            await WriteNotFoundAsync(stream, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
        }
    }

    private string BuildPlaylist()
    {
        HlsSegment[] segments;
        lock (_gate)
        {
            segments = _segments.ToArray();
        }

        var firstSequence = segments.FirstOrDefault()?.Sequence ?? Math.Max(0, _nextSequence - 1);
        var builder = new StringBuilder();
        builder.AppendLine("#EXTM3U");
        builder.AppendLine("#EXT-X-VERSION:3");
        builder.AppendLine("#EXT-X-TARGETDURATION:2");
        builder.AppendLine($"#EXT-X-MEDIA-SEQUENCE:{firstSequence}");
        builder.AppendLine("#EXT-X-ALLOW-CACHE:NO");

        foreach (var segment in segments)
        {
            builder.AppendLine("#EXTINF:2.000,");
            builder.AppendLine($"segment-{segment.Sequence}.mp3");
        }

        return builder.ToString();
    }

    private bool TryGetSegment(int sequence, out byte[] data)
    {
        lock (_gate)
        {
            var segment = _segments.FirstOrDefault(x => x.Sequence == sequence);
            if (segment is not null)
            {
                data = segment.Data;
                return true;
            }
        }

        data = [];
        return false;
    }

    private static async Task<string> ReadRequestAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        var buffer = new byte[2048];
        using var memory = new MemoryStream();
        while (memory.Length < 8192)
        {
            var read = await stream.ReadAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (read <= 0)
            {
                break;
            }

            memory.Write(buffer, 0, read);
            var text = Encoding.ASCII.GetString(memory.ToArray());
            if (text.Contains("\r\n\r\n", StringComparison.Ordinal))
            {
                return text;
            }
        }

        return string.Empty;
    }

    private static string ParsePath(string request)
    {
        var firstLine = request.Split("\r\n", StringSplitOptions.RemoveEmptyEntries).FirstOrDefault() ?? "";
        var parts = firstLine.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        return parts.Length >= 2 ? parts[1] : "/";
    }

    private static async Task WriteResponseAsync(NetworkStream stream, string contentType, byte[] body, CancellationToken cancellationToken)
    {
        var header =
            "HTTP/1.1 200 OK\r\n" +
            $"Content-Type: {contentType}\r\n" +
            $"Content-Length: {body.Length}\r\n" +
            "Cache-Control: no-cache, no-store, must-revalidate\r\n" +
            "Access-Control-Allow-Origin: *\r\n" +
            "Connection: close\r\n\r\n";
        var headerBytes = Encoding.ASCII.GetBytes(header);
        await stream.WriteAsync(headerBytes, cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(body, cancellationToken).ConfigureAwait(false);
    }

    private static async Task WriteNotFoundAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        var body = Encoding.UTF8.GetBytes("Not Found");
        var header =
            "HTTP/1.1 404 Not Found\r\n" +
            "Content-Type: text/plain\r\n" +
            $"Content-Length: {body.Length}\r\n" +
            "Connection: close\r\n\r\n";
        await stream.WriteAsync(Encoding.ASCII.GetBytes(header), cancellationToken).ConfigureAwait(false);
        await stream.WriteAsync(body, cancellationToken).ConfigureAwait(false);
    }

    private static IEnumerable<string> GetListenUrls(int port)
    {
        yield return $"http://localhost:{port}/stream.m3u8";
        foreach (var address in Dns.GetHostAddresses(Dns.GetHostName()))
        {
            if (address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address))
            {
                yield return $"http://{address}:{port}/stream.m3u8";
            }
        }
    }

    private void ThrowIfDisposed()
    {
        if (_isDisposed)
        {
            throw new ObjectDisposedException(nameof(RemoteSoundHlsServer));
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

    private sealed record HlsSegment(int Sequence, byte[] Data);
}
