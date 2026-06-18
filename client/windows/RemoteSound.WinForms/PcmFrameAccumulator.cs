using System.Runtime.InteropServices;

namespace RemoteSound.WinForms;

internal sealed class PcmFrameAccumulator
{
    private readonly int _frameBytes;
    private readonly List<byte> _pending = new(16 * 3840);

    public PcmFrameAccumulator(int frameBytes)
    {
        if (frameBytes <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(frameBytes));
        }

        _frameBytes = frameBytes;
    }

    public IEnumerable<byte[]> Push(byte[] pcmBytes)
    {
        ArgumentNullException.ThrowIfNull(pcmBytes);

        if (pcmBytes.Length == 0)
        {
            yield break;
        }

        _pending.AddRange(pcmBytes);

        while (_pending.Count >= _frameBytes)
        {
            var frame = new byte[_frameBytes];
            CollectionsMarshal.AsSpan(_pending).Slice(0, _frameBytes).CopyTo(frame);
            _pending.RemoveRange(0, _frameBytes);
            yield return frame;
        }
    }

    public void Clear()
    {
        _pending.Clear();
    }
}
