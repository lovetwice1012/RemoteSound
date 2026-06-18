using System.Text.Json.Serialization;

namespace RemoteSound.WinForms;

internal sealed class ClientHello
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = "hello";

    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("clientID")]
    public string ClientId { get; set; } = string.Empty;

    [JsonPropertyName("sampleRate")]
    public double SampleRate { get; set; } = 48_000;

    [JsonPropertyName("channels")]
    public int Channels { get; set; } = 2;

    [JsonPropertyName("codec")]
    public string Codec { get; set; } = "pcm_s16le";

    [JsonPropertyName("frameSamples")]
    public int FrameSamples { get; set; } = 960;
}

internal sealed class ServerEvent
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = string.Empty;

    [JsonPropertyName("message")]
    public string Message { get; set; } = string.Empty;

    [JsonPropertyName("sourceID")]
    public string? SourceId { get; set; }
}
