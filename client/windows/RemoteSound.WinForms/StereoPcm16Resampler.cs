using System.Buffers.Binary;
using System.Runtime.InteropServices;
using NAudio.Wave;

namespace RemoteSound.WinForms;

internal sealed class StereoPcm16Resampler
{
    private static readonly Guid PcmSubFormat = new("00000001-0000-0010-8000-00AA00389B71");
    private static readonly Guid IeeeFloatSubFormat = new("00000003-0000-0010-8000-00AA00389B71");

    private readonly int _targetSampleRate;
    private readonly List<StereoSample> _buffer = new(8192);
    private double _readPosition;
    private int _lastSourceRate;
    private int _lastSourceChannels;
    private int _lastBitsPerSample;
    private WaveFormatEncoding _lastEncoding;

    public StereoPcm16Resampler(int targetSampleRate)
    {
        if (targetSampleRate <= 0)
        {
            throw new ArgumentOutOfRangeException(nameof(targetSampleRate));
        }

        _targetSampleRate = targetSampleRate;
    }

    public byte[] Convert(ReadOnlySpan<byte> input, WaveFormat sourceFormat, float gain, out float peak)
    {
        if (sourceFormat.SampleRate <= 0 || sourceFormat.Channels <= 0 || sourceFormat.BlockAlign <= 0)
        {
            peak = 0;
            return [];
        }

        var encoding = GetEffectiveEncoding(sourceFormat);
        if (HasFormatChanged(sourceFormat, encoding))
        {
            Reset(sourceFormat, encoding);
        }

        AppendDecodedInput(input, sourceFormat, encoding);
        return DrainResampled(gain, out peak);
    }

    public void Reset()
    {
        _buffer.Clear();
        _readPosition = 0;
        _lastSourceRate = 0;
        _lastSourceChannels = 0;
        _lastBitsPerSample = 0;
        _lastEncoding = 0;
    }

    private bool HasFormatChanged(WaveFormat format, WaveFormatEncoding effectiveEncoding)
    {
        return _lastSourceRate != format.SampleRate
            || _lastSourceChannels != format.Channels
            || _lastBitsPerSample != format.BitsPerSample
            || _lastEncoding != effectiveEncoding;
    }

    private void Reset(WaveFormat format, WaveFormatEncoding effectiveEncoding)
    {
        _buffer.Clear();
        _readPosition = 0;
        _lastSourceRate = format.SampleRate;
        _lastSourceChannels = format.Channels;
        _lastBitsPerSample = format.BitsPerSample;
        _lastEncoding = effectiveEncoding;
    }

    private static WaveFormatEncoding GetEffectiveEncoding(WaveFormat format)
    {
        if (format is WaveFormatExtensible extensible)
        {
            if (extensible.SubFormat == IeeeFloatSubFormat)
            {
                return WaveFormatEncoding.IeeeFloat;
            }

            if (extensible.SubFormat == PcmSubFormat)
            {
                return WaveFormatEncoding.Pcm;
            }
        }

        return format.Encoding == WaveFormatEncoding.Extensible && format.BitsPerSample == 32
            ? WaveFormatEncoding.IeeeFloat
            : format.Encoding;
    }

    private void AppendDecodedInput(ReadOnlySpan<byte> input, WaveFormat format, WaveFormatEncoding encoding)
    {
        var sourceChannels = format.Channels;
        var blockAlign = format.BlockAlign;
        var bytesPerSample = blockAlign / sourceChannels;
        if (bytesPerSample <= 0 || input.Length < blockAlign)
        {
            return;
        }

        var frameCount = input.Length / blockAlign;
        var destinationStart = _buffer.Count;
        for (var i = 0; i < frameCount; i++)
        {
            var frameOffset = i * blockAlign;
            var left = DecodeSample(input.Slice(frameOffset, bytesPerSample), encoding, format.BitsPerSample);
            var right = sourceChannels >= 2
                ? DecodeSample(input.Slice(frameOffset + bytesPerSample, bytesPerSample), encoding, format.BitsPerSample)
                : left;

            _buffer.Add(new StereoSample(left, right));
        }

        if (_buffer.Count - destinationStart > 0 && _buffer.Count > 96_000)
        {
            var safeRemove = Math.Min(_buffer.Count - 4_096, Math.Max(0, (int)_readPosition - 1));
            if (safeRemove > 0)
            {
                _buffer.RemoveRange(0, safeRemove);
                _readPosition = Math.Max(0, _readPosition - safeRemove);
            }
        }
    }

    private byte[] DrainResampled(float gain, out float peak)
    {
        peak = 0;
        if (_buffer.Count < 2 || _lastSourceRate <= 0)
        {
            return [];
        }

        var sourceToTargetStep = (double)_lastSourceRate / _targetSampleRate;
        var estimatedOutputFrames = Math.Max(0, (int)((_buffer.Count - 1 - _readPosition) / sourceToTargetStep));
        if (estimatedOutputFrames <= 0)
        {
            return [];
        }

        var output = new byte[estimatedOutputFrames * RemoteSoundWebSocketClient.TargetChannels * sizeof(short)];
        var offset = 0;

        while (_readPosition + 1 < _buffer.Count && offset + 4 <= output.Length)
        {
            var index = (int)_readPosition;
            var fraction = (float)(_readPosition - index);
            var a = _buffer[index];
            var b = _buffer[index + 1];

            var left = Lerp(a.Left, b.Left, fraction) * gain;
            var right = Lerp(a.Right, b.Right, fraction) * gain;
            peak = Math.Max(peak, Math.Max(Math.Abs(left), Math.Abs(right)));

            BinaryPrimitives.WriteInt16LittleEndian(output.AsSpan(offset, 2), ToInt16(left));
            BinaryPrimitives.WriteInt16LittleEndian(output.AsSpan(offset + 2, 2), ToInt16(right));
            offset += 4;

            _readPosition += sourceToTargetStep;
        }

        if (offset != output.Length)
        {
            Array.Resize(ref output, offset);
        }

        var consumed = Math.Max(0, (int)_readPosition - 1);
        if (consumed > 0)
        {
            _buffer.RemoveRange(0, consumed);
            _readPosition -= consumed;
        }

        return output;
    }

    private static float DecodeSample(ReadOnlySpan<byte> sampleBytes, WaveFormatEncoding encoding, int bitsPerSample)
    {
        try
        {
            if (encoding == WaveFormatEncoding.IeeeFloat && bitsPerSample == 32 && sampleBytes.Length >= 4)
            {
                return Math.Clamp(MemoryMarshal.Read<float>(sampleBytes), -1f, 1f);
            }

            if (encoding == WaveFormatEncoding.Pcm)
            {
                return bitsPerSample switch
                {
                    8 when sampleBytes.Length >= 1 => (sampleBytes[0] - 128) / 128f,
                    16 when sampleBytes.Length >= 2 => BinaryPrimitives.ReadInt16LittleEndian(sampleBytes.Slice(0, 2)) / 32768f,
                    24 when sampleBytes.Length >= 3 => ReadInt24LittleEndian(sampleBytes.Slice(0, 3)) / 8_388_608f,
                    32 when sampleBytes.Length >= 4 => BinaryPrimitives.ReadInt32LittleEndian(sampleBytes.Slice(0, 4)) / 2_147_483_648f,
                    _ => 0f,
                };
            }
        }
        catch
        {
            return 0f;
        }

        return 0f;
    }

    private static int ReadInt24LittleEndian(ReadOnlySpan<byte> bytes)
    {
        var value = bytes[0] | (bytes[1] << 8) | (bytes[2] << 16);
        if ((value & 0x0080_0000) != 0)
        {
            value |= unchecked((int)0xFF00_0000);
        }

        return value;
    }

    private static short ToInt16(float value)
    {
        value = Math.Clamp(value, -1f, 1f);
        return (short)Math.Round(value >= 0 ? value * short.MaxValue : value * 32768f);
    }

    private static float Lerp(float a, float b, float t)
    {
        return a + ((b - a) * t);
    }

    private readonly record struct StereoSample(float Left, float Right);
}
