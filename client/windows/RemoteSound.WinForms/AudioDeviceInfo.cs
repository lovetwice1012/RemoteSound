namespace RemoteSound.WinForms;

internal sealed class AudioDeviceInfo
{
    public required string Id { get; init; }
    public required string Name { get; init; }
    public bool IsDefault { get; init; }

    public override string ToString()
    {
        return IsDefault ? $"{Name}  (Default)" : Name;
    }
}
