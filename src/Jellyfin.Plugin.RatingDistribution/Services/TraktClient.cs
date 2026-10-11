using System.Net;
using System.Net.Http.Json;
using System.Text.Json.Serialization;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.RatingDistribution.Services;

public sealed class TraktRatings
{
    [JsonPropertyName("rating")]
    public double Rating { get; set; }

    [JsonPropertyName("votes")]
    public int Votes { get; set; }

    [JsonPropertyName("distribution")]
    public Dictionary<string, int> Distribution { get; set; } = new();
}

public sealed class TraktSearchResult
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = string.Empty;

    [JsonPropertyName("movie")]
    public TraktMedia? Movie { get; set; }

    [JsonPropertyName("show")]
    public TraktMedia? Show { get; set; }
}

public sealed class TraktMedia
{
    [JsonPropertyName("ids")]
    public TraktIds Ids { get; set; } = new();
}

public sealed class TraktIds
{
    [JsonPropertyName("trakt")]
    public int Trakt { get; set; }

    [JsonPropertyName("slug")]
    public string? Slug { get; set; }
}

/// <summary>
/// Minimal Trakt API v2 client. Reads only public endpoints, so a client ID is enough (no OAuth).
/// </summary>
public sealed class TraktClient
{
    private const string BaseUrl = "https://api.trakt.tv";

    private readonly IHttpClientFactory _httpClientFactory;
    private readonly ILogger<TraktClient> _logger;

    public TraktClient(IHttpClientFactory httpClientFactory, ILogger<TraktClient> logger)
    {
        _httpClientFactory = httpClientFactory;
        _logger = logger;
    }

    public static string? ClientId
    {
        get
        {
            string? configured = Plugin.Instance?.Configuration.TraktClientId;
            if (!string.IsNullOrWhiteSpace(configured))
            {
                return configured.Trim();
            }

            string? env = Environment.GetEnvironmentVariable("TRAKT_CLIENT_ID");
            return string.IsNullOrWhiteSpace(env) ? null : env.Trim();
        }
    }

    /// <summary>
    /// Gets the ratings at <paramref name="path"/>, or null if Trakt returns 404.
    /// </summary>
    public Task<TraktRatings?> GetRatingsAsync(string path, CancellationToken cancellationToken)
        => GetAsync<TraktRatings>(path, cancellationToken);

    /// <summary>
    /// Resolves a TMDB or TVDB ID to a Trakt ID. <paramref name="idType"/> is "tmdb" or "tvdb", <paramref name="mediaType"/> is "movie" or "show".
    /// </summary>
    public async Task<int?> LookupTraktIdAsync(string idType, string id, string mediaType, CancellationToken cancellationToken)
    {
        List<TraktSearchResult>? results = await GetAsync<List<TraktSearchResult>>(
            $"/search/{idType}/{Uri.EscapeDataString(id)}?type={mediaType}", cancellationToken).ConfigureAwait(false);
        TraktSearchResult? hit = results?.FirstOrDefault(r => r.Type == mediaType);
        int? traktId = mediaType == "movie" ? hit?.Movie?.Ids.Trakt : hit?.Show?.Ids.Trakt;
        return traktId is > 0 ? traktId : null;
    }

    private async Task<T?> GetAsync<T>(string path, CancellationToken cancellationToken)
        where T : class
    {
        string clientId = ClientId ?? throw new InvalidOperationException("No Trakt client ID is configured.");

        using HttpRequestMessage request = new HttpRequestMessage(HttpMethod.Get, BaseUrl + path);
        request.Headers.Add("trakt-api-version", "2");
        request.Headers.Add("trakt-api-key", clientId);
        request.Headers.UserAgent.ParseAdd("Jellyfin-RatingDistribution/" + (Plugin.Instance?.ScriptVersion ?? "0"));

        HttpClient client = _httpClientFactory.CreateClient();
        using HttpResponseMessage response = await client.SendAsync(request, cancellationToken).ConfigureAwait(false);
        if (response.StatusCode == HttpStatusCode.NotFound)
        {
            return null;
        }

        if (!response.IsSuccessStatusCode)
        {
            _logger.LogWarning("Trakt returned {Status} for {Path}", (int)response.StatusCode, path);
            response.EnsureSuccessStatusCode();
        }

        return await response.Content.ReadFromJsonAsync<T>(cancellationToken).ConfigureAwait(false);
    }
}
