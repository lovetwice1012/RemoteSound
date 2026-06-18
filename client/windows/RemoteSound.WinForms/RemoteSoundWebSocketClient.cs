using System.Net.WebSockets;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace RemoteSound.WinForms;

internal sealed class RemoteSoundWebSocketClient : IAsyncDisposable
{
    public const int TargetSampleRate = 48_000;
    public const int TargetChannels = 2;
    public const int FrameSamples = 960;
    public const int FrameBytes = FrameSamples * TargetChannels * sizeof(short);

    private readonly JsonSerializerOptions _jsonOptions = new(JsonSerializerDefaults.Web);
    private readonly SemaphoreSlim _stateLock = new(1, 1);
    private ClientWebSocket? _socket;
    private CancellationTokenSource? _lifetimeCts;
    private Channel<byte[]>? _audioQueue;
    private Task? _sendLoopTask;
    private Task? _receiveLoopTask;

    public bool IsConnected => _socket?.State == WebSocketState.Open;
    public event Action<string>? Log;
    public event Action? Disconnected;

    public async Task ConnectAsync(Uri serverUri, string sourceName, string clientId, CancellationToken cancellationToken)
    {
        await _stateLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (IsConnected)
            {
                return;
            }

            await DisposeCurrentConnectionAsync().ConfigureAwait(false);

            _lifetimeCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            _socket = new ClientWebSocket();
            _socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(10);

            Log?.Invoke($"Connecting to {serverUri} ...");
            await _socket.ConnectAsync(serverUri, cancellationToken).ConfigureAwait(false);

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
            await _socket.SendAsync(helloBytes, WebSocketMessageType.Text, true, cancellationToken).ConfigureAwait(false);
            Log?.Invoke("Handshake sent: 48 kHz stereo pcm_s16le.");

            await WaitForAcceptedAsync(_socket, cancellationToken).ConfigureAwait(false);

            _audioQueue = Channel.CreateBounded<byte[]>(new BoundedChannelOptions(24)
            {
                SingleReader = true,
                SingleWriter = false,
                FullMode = BoundedChannelFullMode.DropOldest,
            });

            _sendLoopTask = Task.Run(() => SendLoopAsync(_socket, _audioQueue.Reader, _lifetimeCts.Token));
            _receiveLoopTask = Task.Run(() => ReceiveLoopAsync(_socket, _lifetimeCts.Token));
            Log?.Invoke("RemoteSound server accepted the stream.");
        }
        catch
        {
            await DisposeCurrentConnectionAsync().ConfigureAwait(false);
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
        if (queue is null || !IsConnected)
        {
            return false;
        }

        return queue.Writer.TryWrite(frame);
    }

    public async Task DisconnectAsync()
    {
        await _stateLock.WaitAsync().ConfigureAwait(false);
        try
        {
            await DisposeCurrentConnectionAsync().ConfigureAwait(false);
        }
        finally
        {
            _stateLock.Release();
        }
    }

    private async Task WaitForAcceptedAsync(ClientWebSocket socket, CancellationToken cancellationToken)
    {
        using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeoutCts.CancelAfter(TimeSpan.FromSeconds(8));

        while (socket.State == WebSocketState.Open)
        {
            var (type, payload) = await ReceiveTextOrCloseAsync(socket, timeoutCts.Token).ConfigureAwait(false);
            if (type == WebSocketMessageType.Close)
            {
                throw new InvalidOperationException("Server closed the connection during handshake.");
            }

            ServerEvent? serverEvent = null;
            try
            {
                serverEvent = JsonSerializer.Deserialize<ServerEvent>(payload, _jsonOptions);
            }
            catch
            {
                Log?.Invoke("Server sent non-JSON text during handshake: " + payload);
            }

            if (serverEvent is null)
            {
                continue;
            }

            if (!string.IsNullOrWhiteSpace(serverEvent.Message))
            {
                Log?.Invoke($"Server: {serverEvent.Type} - {serverEvent.Message}");
            }

            if (string.Equals(serverEvent.Type, "accepted", StringComparison.OrdinalIgnoreCase))
            {
                return;
            }

            if (string.Equals(serverEvent.Type, "error", StringComparison.OrdinalIgnoreCase))
            {
                throw new InvalidOperationException(serverEvent.Message.Length == 0 ? "Server rejected the stream." : serverEvent.Message);
            }
        }

        throw new InvalidOperationException("WebSocket closed before the stream was accepted.");
    }

    private async Task SendLoopAsync(ClientWebSocket socket, ChannelReader<byte[]> reader, CancellationToken cancellationToken)
    {
        try
        {
            await foreach (var frame in reader.ReadAllAsync(cancellationToken).ConfigureAwait(false))
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
            Disconnected?.Invoke();
        }
    }

    private async Task ReceiveLoopAsync(ClientWebSocket socket, CancellationToken cancellationToken)
    {
        try
        {
            while (socket.State == WebSocketState.Open && !cancellationToken.IsCancellationRequested)
            {
                var (type, payload) = await ReceiveTextOrCloseAsync(socket, cancellationToken).ConfigureAwait(false);
                if (type == WebSocketMessageType.Close)
                {
                    Log?.Invoke("Server closed the connection.");
                    Disconnected?.Invoke();
                    return;
                }

                if (payload.Length > 0)
                {
                    Log?.Invoke("Server: " + payload);
                }
            }
        }
        catch (OperationCanceledException)
        {
        }
        catch (Exception ex)
        {
            Log?.Invoke("Server receive failed: " + ex.Message);
            Disconnected?.Invoke();
        }
    }

    private static async Task<(WebSocketMessageType Type, string Payload)> ReceiveTextOrCloseAsync(ClientWebSocket socket, CancellationToken cancellationToken)
    {
        var buffer = new byte[8192];
        using var memory = new MemoryStream();

        while (true)
        {
            var result = await socket.ReceiveAsync(buffer, cancellationToken).ConfigureAwait(false);
            if (result.MessageType == WebSocketMessageType.Close)
            {
                return (WebSocketMessageType.Close, string.Empty);
            }

            if (result.Count > 0)
            {
                memory.Write(buffer, 0, result.Count);
            }

            if (result.EndOfMessage)
            {
                return (result.MessageType, Encoding.UTF8.GetString(memory.ToArray()));
            }
        }
    }

    private async Task DisposeCurrentConnectionAsync()
    {
        var socket = _socket;
        var lifetimeCts = _lifetimeCts;
        var audioQueue = _audioQueue;

        _socket = null;
        _lifetimeCts = null;
        _audioQueue = null;

        try
        {
            audioQueue?.Writer.TryComplete();
        }
        catch
        {
        }

        try
        {
            lifetimeCts?.Cancel();
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
                    await socket.CloseAsync(WebSocketCloseStatus.NormalClosure, "RemoteSound client disconnect", closeCts.Token).ConfigureAwait(false);
                }
            }
            catch
            {
            }

            socket.Dispose();
        }

        lifetimeCts?.Dispose();
    }

    public async ValueTask DisposeAsync()
    {
        await DisconnectAsync().ConfigureAwait(false);
        _stateLock.Dispose();
    }
}
