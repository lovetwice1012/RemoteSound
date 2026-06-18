using System.Buffers.Binary;
using System.Net;
using System.Net.Sockets;
using System.Text;

namespace RemoteSound.WinForms;

internal sealed class RemoteAudioMdnsAdvertiser : IDisposable
{
    private static readonly IPAddress MulticastAddress = IPAddress.Parse("224.0.0.251");
    private const int MdnsPort = 5353;
    private const string ServiceType = "_remoteaudio._tcp.local";

    private readonly object _gate = new();
    private UdpClient? _udp;
    private CancellationTokenSource? _cts;
    private Task? _listenTask;
    private string _instanceName = "RemoteSound";
    private int _servicePort;
    private bool _isDisposed;

    public event Action<string>? Log;

    public void Start(string instanceName, int servicePort)
    {
        ThrowIfDisposed();
        Stop();

        _instanceName = SanitizeLabel(instanceName);
        _servicePort = servicePort;
        _cts = new CancellationTokenSource();

        var udp = new UdpClient(AddressFamily.InterNetwork);
        udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        udp.Client.Bind(new IPEndPoint(IPAddress.Any, MdnsPort));
        udp.JoinMulticastGroup(MulticastAddress);
        udp.MulticastLoopback = true;
        _udp = udp;

        _listenTask = Task.Run(() => ListenAsync(udp, _cts.Token));
        Log?.Invoke($"Advertising Bonjour service {_instanceName}._remoteaudio._tcp.local.");
        SendAnnouncement();
    }

    public void Stop()
    {
        lock (_gate)
        {
            try
            {
                _cts?.Cancel();
                _udp?.DropMulticastGroup(MulticastAddress);
            }
            catch
            {
            }

            _udp?.Dispose();
            _udp = null;
            _cts?.Dispose();
            _cts = null;
            _listenTask = null;
        }
    }

    private async Task ListenAsync(UdpClient udp, CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(20));
        var receiveTask = ReceiveLoopAsync(udp, cancellationToken);

        try
        {
            while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
            {
                SendAnnouncement();
            }
        }
        catch (OperationCanceledException)
        {
        }

        await receiveTask.ConfigureAwait(false);
    }

    private async Task ReceiveLoopAsync(UdpClient udp, CancellationToken cancellationToken)
    {
        try
        {
            while (!cancellationToken.IsCancellationRequested)
            {
                var result = await udp.ReceiveAsync(cancellationToken).ConfigureAwait(false);
                if (QueryMentionsService(result.Buffer))
                {
                    SendAnnouncement();
                }
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
            Log?.Invoke("Bonjour advertiser failed: " + ex.Message);
        }
    }

    private void SendAnnouncement()
    {
        UdpClient? udp;
        lock (_gate)
        {
            udp = _udp;
        }

        if (udp is null || _servicePort <= 0)
        {
            return;
        }

        var packet = BuildResponsePacket(_instanceName, _servicePort);
        try
        {
            udp.Send(packet, packet.Length, new IPEndPoint(MulticastAddress, MdnsPort));
        }
        catch (Exception ex)
        {
            Log?.Invoke("Bonjour announcement failed: " + ex.Message);
        }
    }

    private static byte[] BuildResponsePacket(string instanceName, int servicePort)
    {
        using var stream = new MemoryStream();
        Span<byte> header = stackalloc byte[12];
        BinaryPrimitives.WriteUInt16BigEndian(header[2..], 0x8400);
        BinaryPrimitives.WriteUInt16BigEndian(header[6..], 4);
        stream.Write(header);

        var instanceFullName = $"{instanceName}.{ServiceType}";
        var hostName = $"{SanitizeLabel(Environment.MachineName)}.local";
        var address = GetPrimaryIPv4Address();

        WritePtrRecord(stream, ServiceType, instanceFullName);
        WriteSrvRecord(stream, instanceFullName, hostName, servicePort);
        WriteTxtRecord(stream, instanceFullName);
        WriteARecord(stream, hostName, address);

        return stream.ToArray();
    }

    private static void WritePtrRecord(Stream stream, string name, string target)
    {
        WriteName(stream, name);
        WriteUInt16(stream, 12);
        WriteUInt16(stream, 1);
        WriteUInt32(stream, 120);
        using var data = new MemoryStream();
        WriteName(data, target);
        WriteUInt16(stream, (ushort)data.Length);
        data.WriteTo(stream);
    }

    private static void WriteSrvRecord(Stream stream, string name, string hostName, int port)
    {
        WriteName(stream, name);
        WriteUInt16(stream, 33);
        WriteUInt16(stream, 1);
        WriteUInt32(stream, 120);
        using var data = new MemoryStream();
        WriteUInt16(data, 0);
        WriteUInt16(data, 0);
        WriteUInt16(data, (ushort)port);
        WriteName(data, hostName);
        WriteUInt16(stream, (ushort)data.Length);
        data.WriteTo(stream);
    }

    private static void WriteTxtRecord(Stream stream, string name)
    {
        WriteName(stream, name);
        WriteUInt16(stream, 16);
        WriteUInt16(stream, 1);
        WriteUInt32(stream, 120);
        var txt = Encoding.UTF8.GetBytes("path=/");
        WriteUInt16(stream, (ushort)(txt.Length + 1));
        stream.WriteByte((byte)txt.Length);
        stream.Write(txt);
    }

    private static void WriteARecord(Stream stream, string hostName, IPAddress address)
    {
        WriteName(stream, hostName);
        WriteUInt16(stream, 1);
        WriteUInt16(stream, 1);
        WriteUInt32(stream, 120);
        WriteUInt16(stream, 4);
        stream.Write(address.GetAddressBytes());
    }

    private static void WriteName(Stream stream, string name)
    {
        foreach (var label in name.TrimEnd('.').Split('.'))
        {
            var bytes = Encoding.UTF8.GetBytes(label);
            stream.WriteByte((byte)Math.Min(bytes.Length, 63));
            stream.Write(bytes, 0, Math.Min(bytes.Length, 63));
        }
        stream.WriteByte(0);
    }

    private static void WriteUInt16(Stream stream, int value)
    {
        Span<byte> buffer = stackalloc byte[2];
        BinaryPrimitives.WriteUInt16BigEndian(buffer, (ushort)value);
        stream.Write(buffer);
    }

    private static void WriteUInt32(Stream stream, uint value)
    {
        Span<byte> buffer = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(buffer, value);
        stream.Write(buffer);
    }

    private static bool QueryMentionsService(byte[] packet)
    {
        var text = Encoding.UTF8.GetString(packet);
        return text.Contains("_remoteaudio", StringComparison.OrdinalIgnoreCase)
            || text.Contains("_services", StringComparison.OrdinalIgnoreCase);
    }

    private static IPAddress GetPrimaryIPv4Address()
    {
        return Dns.GetHostAddresses(Dns.GetHostName())
            .FirstOrDefault(address => address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(address))
            ?? IPAddress.Loopback;
    }

    private static string SanitizeLabel(string value)
    {
        var label = new string(value.Where(ch => char.IsLetterOrDigit(ch) || ch == '-').ToArray());
        return string.IsNullOrWhiteSpace(label) ? "RemoteSound" : label;
    }

    private void ThrowIfDisposed()
    {
        if (_isDisposed)
        {
            throw new ObjectDisposedException(nameof(RemoteAudioMdnsAdvertiser));
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
