using System.Net;
using System.Net.Sockets;
using System.Net.WebSockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace RemoteSound.WinForms;

internal sealed class RemoteSoundWebSocketAudioServer : IAsyncDisposable
{
    public const int TargetSampleRate = 48_000;
    public const int TargetChannels = 2;
    public const int FrameSamples = 960;
    public const int FrameBytes = FrameSamples * TargetChannels * sizeof(short);

    private const string WebSocketGuid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11";
    private readonly JsonSerializerOptions _jsonOptions = new(JsonSerializerDefaults.Web);
    private readonly SemaphoreSlim _stateLock = new(1, 1);
    private TcpListener? _listener;
    private CancellationTokenSource? _lifetimeCts;
    private Channel<byte[]>? _audioQueue;
    private Task? _acceptLoopTask;
    private WebSocket? _socket;
    private RemoteAudioMdnsAdvertiser? _advertiser;

    public bool IsRunning => _listener is not null;
    public bool IsClientConnected => _socket?.State == WebSocketState.Open;
    public event Action<string>? Log;
    public event Action? ClientConnected;
    public event Action? ClientDisconnected;

    public async Task StartAsync(int port, string sourceName, string clientId, CancellationToken cancellationToken)
    {
        await _stateLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (IsRunning)
            {
                return;
            }

            await DisposeCurrentServerAsync().ConfigureAwait(false);

            _lifetimeCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _audioQueue = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(24)
            {
                SingleReader = false,
                SingleWriter = false,
                FullMode = BoundedChannelFullMode.DropOldest,
            });

            var listener = new TcpListener(IPAddress.Any, port);
            listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            listener.Start();
            _listener = listener;

            Log?.Invoke($"Listening for RemoteSound receivers on port {port}.");
            foreach (var url in GetListenUrls(port))
            {
                Log?.Invoke("iPhone URL: " + url);
            }

            StartAdvertiser(sourceName, port);
            _acceptLoopTask = Task.Run(() => AcceptLoopAsync(listener, sourceName, clientId, _lifetimeCts.Token));
        }
        catch
        {
            await DisposeCurrentServerAsync().ConfigureAwait(false);
            throw;
        }
        finally
        {
            _stateLock.Release();
        }
    }

    public bool TryQueueAudioFrame(byte[] frame)
    {
        if (frame.Length != FrameBytes)
        {
            Log?.Invoke($"Dropped invalid frame: {frame.Length} bytes.");
            return false;
        }

        var queue = _audioQueue;
        if (queue is null || !IsClientConnected)
        {
            return false;
        }

        return queue.Writer.TryWrite(frame);
    }

    public async Task StopAsync()
    {
        await _stateLock.WaitAsync().ConfigureAwait(false);
        try
        {
            await DisposeCurrentServerAsync().ConfigureAwait(false);
        }
        finally
        {
            _stateLock.Release();
        }
    }

    private async Task AcceptLoopAsync(TcpListener listener, string sourceName, string clientId, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var tcpClient = await listener.AcceptTcpClientAsync(cancellationToken).ConfigureAwait(false);
                _ = Task.Run(() => HandleTcpClientAsync(tcpClient, sourceName, clientId, cancellationToken), cancellationToken);
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
            Log?.Invoke("Accept loop failed: " + ex.Message);
        }
    }

    private async Task HandleTcpClientAsync(TcpClient tcpClient, string sourceName, string clientId, CancellationToken cancellationToken)
    {
        using var _ = tcpClient;
        WebSocket? socket = null;

        try
        {
            tcpClient.NoDelay = true;
            var stream = tcpClient.GetStream();
            var headers = await ReadHttpHeadersAsync(stream, cancellationToken).ConfigureAwait(false);
            var webSocketKey = GetHeaderValue(headers, "Sec-WebSocket-Key");
            if (string.IsNullOrWhiteSpace(webSocketKey))
            {
                return;
            }

            await WriteWebSocketHandshakeAsync(stream, webSocketKey, cancellationToken).ConfigureAwait(false);
            socket = WebSocket.CreateFromStream(stream, isServer: true, subProtocol: null, keepAliveInterval: TimeSpan.FromSeconds(10));

            await ReplaceActiveSocketAsync(socket).ConfigureAwait(false);
            ClientConnected?.Invoke();
            Log?.Invoke("iPhone receiver connected.");

            await SendHelloAsync(socket, sourceName, clientId, cancellationToken).ConfigureAwait(false);

            var sendTask = SendLoopAsync(socket, cancellationToken);
            var receiveTask = ReceiveLoopAsync(socket, cancellationToken);
            await Task.WhenAny(sendTask, receiveTask).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }
        catch (WebSocketException ex)
        {
            Log?.Invoke("WebSocket client disconnected: " + ex.Message);
        }
        catch (Exception ex)
        {
            Log?.Invoke("Receiver connection failed: " + ex.Message);
        }
        finally
        {
            if (socket is not null)
            {
                await ClearActiveSocketAsync(socket).ConfigureAwait(false);
            }
            ClientDisconnected?.Invoke();
        }
    }

    private async Task ReplaceActiveSocketAsync(WebSocket socket)
    {
        var previous = Interlocked.Exchange(ref _socket, socket);
        if (previous is null)
        {
            return;
        }

        try
        {
            if (previous.State == WebSocketState.Open || previous.State == WebSocketState.CloseReceived)
            {
                using var closeCts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                await previous.CloseAsync(WebSocketCloseStatus.NormalClosure, "New receiver connected", closeCts.Token).ConfigureAwait(false);
            }
        }
        catch
        {
        }
        finally
        {
            previous.Dispose();
        }
    }

    private Task ClearActiveSocketAsync(WebSocket socket)
    {
        if (ReferenceEquals(_socket, socket))
        {
            Interlocked.Exchange(ref _socket, null);
            socket.Dispose();
        }
        return Task.CompletedTask;
    }

    private async Task SendHelloAsync(WebSocket socket, string sourceName, string clientId, CancellationToken cancellationToken)
    {
        var hello = new ClientHello
        {
            Name = sourceName,
            ClientId = clientId,
            SampleRate = TargetSampleRate,
            Channels = TargetChannels,
            Codec = "pcm_s16le",
            FrameSamples = FrameSamples,
        };

        var helloJson = JsonSerializer.Serialize(hello, _jsonOptions);
        var helloBytes = Encoding.UTF8.GetBytes(helloJson);
        await socket.SendAsync(helloBytes, WebSocketMessageType.Text, true, cancellationToken).ConfigureAwait(false);
        Log?.Invoke("Source hello sent: 48 kHz stereo pcm_s16le.");
    }

    private async Task SendLoopAsync(WebSocket socket, CancellationToken cancellationToken)
    {
        var queue = _audioQueue;
        if (queue is null)
        {
            return;
        }

        try
        {
            await foreach (var frame in queue.Reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
            {
                if (socket.State != WebSocketState.Open)
                {
                    break;
                }

                await socket.SendAsync(frame, WebSocketMessageType.Binary, true, cancellationToken).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            Log?.Invoke("Audio send failed: " + ex.Message);
        }
    }

    private async Task ReceiveLoopAsync(WebSocket socket, CancellationToken cancellationToken)
    {
        var buffer = new byte[8192];
        try
        {
            while (socket.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
            {
                var result = await socket.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    Log?.Invoke("iPhone receiver closed the connection.");
                    return;
                }

                if (result.MessageType == WebSocketMessageType.Text && result.EndOfMessage)
                {
                    var message = Encoding.UTF8.GetString(buffer, 0, result.Count);
                    Log?.Invoke("Receiver: " + message);
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            Log?.Invoke("Receiver read failed: " + ex.Message);
        }
    }

    private static async Task<string> ReadHttpHeadersAsync(NetworkStream stream, CancellationToken cancellationToken)
    {
        var buffer = new byte[1024];
        using var memory = new MemoryStream();

        while (memory.Length < 16_384)
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

    private static string? GetHeaderValue(string headers, string name)
    {
        foreach (var line in headers.Split("\r\n", StringSplitOptions.RemoveEmptyEntries))
        {
            var separatorIndex = line.IndexOf(':');
            if (separatorIndex <= 0)
            {
                continue;
            }

            if (string.Equals(line[..separatorIndex].Trim(), name, StringComparison.OrdinalIgnoreCase))
            {
                return line[(separatorIndex + 1)..].Trim();
            }
        }

        return null;
    }

    private static async Task WriteWebSocketHandshakeAsync(NetworkStream stream, string webSocketKey, CancellationToken cancellationToken)
    {
        var acceptBytes = SHA1.HashData(Encoding.ASCII.GetBytes(webSocketKey.Trim() + WebSocketGuid));
        var accept = Convert.ToBase64String(acceptBytes);
        var response =
            "HTTP/1.1 101 Switching Protocols\r\n" +
            "Upgrade: websocket\r\n" +
            "Connection: Upgrade\r\n" +
            $"Sec-WebSocket-Accept: {accept}\r\n\r\n";

        var responseBytes = Encoding.ASCII.GetBytes(response);
        await stream.WriteAsync(responseBytes, cancellationToken).ConfigureAwait(false);
    }

    private static IEnumerable<string> GetListenUrls(int port)
    {
        yield return $"ws://localhost:{port}/";

        foreach (var address in Dns.GetHostAddresses(Dns.GetHostName()))
        {
            if (address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address))
            {
                yield return $"ws://{address}:{port}/";
            }
        }
    }

    private async Task DisposeCurrentServerAsync()
    {
        var listener = _listener;
        var lifetimeCts = _lifetimeCts;
        var audioQueue = _audioQueue;
        var socket = _socket;
        var advertiser = _advertiser;

        _listener = null;
        _lifetimeCts = null;
        _audioQueue = null;
        _socket = null;
        _advertiser = null;

        try
        {
            audioQueue?.Writer.TryComplete();
            lifetimeCts?.Cancel();
            listener?.Stop();
            advertiser?.Dispose();
        }
        catch
        {
        }

        if (socket is not null)
        {
            try
            {
                if (socket.State == WebSocketState.Open || socket.State == WebSocketState.CloseReceived)
                {
                    using var closeCts = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                    await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "RemoteSound server stopped", closeCts.Token).ConfigureAwait(false);
                }
            }
            catch
            {
            }

            socket.Dispose();
        }

        lifetimeCts?.Dispose();
    }

    private void StartAdvertiser(string sourceName, int port)
    {
        try
        {
            var advertiser = new RemoteAudioMdnsAdvertiser();
            advertiser.Log += message => Log?.Invoke(message);
            advertiser.Start(sourceName, port);
            _advertiser = advertiser;
        }
        catch (Exception ex)
        {
            Log?.Invoke("Bonjour advertisement unavailable: " + ex.Message);
        }
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        _stateLock.Dispose();
    }
}
