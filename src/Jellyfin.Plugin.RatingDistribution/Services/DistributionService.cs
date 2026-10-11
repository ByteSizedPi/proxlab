using System.Text.Json.Serialization;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Entities.Movies;
using MediaBrowser.Controller.Entities.TV;
using MediaBrowser.Model.Entities;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.RatingDistribution.Services;

public sealed class DistributionDto
{
    /// <summary>
    /// Gets or sets "trakt" when counts are present, otherwise "none".
    /// </summary>
    [JsonPropertyName("source")]
    public string Source { get; set; } = "none";

    /// <summary>
    /// Gets or sets why there is no distribution: unsupported, no-ids, not-configured, not-found or error.
    /// </summary>
    [JsonPropertyName("reason")]
    public string? Reason { get; set; }

    [JsonPropertyName("counts")]
    public int[]? Counts { get; set; }

    [JsonPropertyName("votes")]
    public int Votes { get; set; }

    [JsonPropertyName("traktRating")]
    public double? TraktRating { get; set; }

    [JsonPropertyName("traktUrl")]
    public string? TraktUrl { get; set; }

    [JsonPropertyName("minVotes")]
    public int MinVotes { get; set; }

    [JsonPropertyName("fetchedAt")]
    public DateTime? FetchedAt { get; set; }
}

/// <summary>
/// Maps a library item to its Trakt ratings endpoint, and serves the counts from the cache or from Trakt.
/// </summary>
public sealed class DistributionService
{
    private readonly TraktClient _trakt;
    private readonly RatingCache _cache;
    private readonly ILogger<DistributionService> _logger;

    public DistributionService(TraktClient trakt, RatingCache cache, ILogger<DistributionService> logger)
    {
        _trakt = trakt;
        _cache = cache;
        _logger = logger;
    }

    public async Task<DistributionDto> GetAsync(BaseItem item, CancellationToken cancellationToken)
    {
        var config = Plugin.Instance!.Configuration;
        DistributionDto dto = new() { MinVotes = config.MinVotes, TraktUrl = TraktUrl(item) };

        if (item is not (Movie or Series or Season or Episode))
        {
            dto.Reason = "unsupported";
            return dto;
        }

        string key = item.Id.ToString("N");
        if (_cache.TryGet(key, out CacheEntry? cached) && cached != null && !IsStale(item, cached))
        {
            return Fill(dto, cached);
        }

        if (TraktClient.ClientId == null)
        {
            dto.Reason = "not-configured";
            return cached != null ? Fill(dto, cached) : dto;
        }

        try
        {
            string? path = await ResolvePathAsync(item, cancellationToken).ConfigureAwait(false);
            if (path == null)
            {
                dto.Reason = "no-ids";
                return dto;
            }

            TraktRatings? ratings = await _trakt.GetRatingsAsync(path, cancellationToken).ConfigureAwait(false);
            CacheEntry entry = new() { FetchedAt = DateTime.UtcNow };
            int[] counts = Enumerable.Range(1, 10)
                .Select(k => ratings != null && ratings.Distribution.TryGetValue(k.ToString(System.Globalization.CultureInfo.InvariantCulture), out int n) ? n : 0)
                .ToArray();
            // No votes (or a response shape we do not know) counts as "not found", not as ten zeros.
            if (ratings != null && counts.Sum() > 0)
            {
                entry.Counts = counts;
                entry.Votes = ratings.Votes;
                entry.TraktRating = ratings.Rating;
            }

            await _cache.SetAsync(key, entry).ConfigureAwait(false);
            return Fill(dto, entry);
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            _logger.LogWarning(ex, "Rating Distribution: Trakt lookup failed for {Name} ({Id})", item.Name, item.Id);
            if (cached != null)
            {
                return Fill(dto, cached);
            }

            dto.Reason = "error";
            return dto;
        }
    }

    private static DistributionDto Fill(DistributionDto dto, CacheEntry entry)
    {
        dto.FetchedAt = entry.FetchedAt;
        if (entry.Counts == null)
        {
            dto.Reason ??= "not-found";
            return dto;
        }

        dto.Source = "trakt";
        dto.Reason = null;
        dto.Counts = entry.Counts;
        dto.Votes = entry.Votes;
        dto.TraktRating = entry.TraktRating;
        return dto;
    }

    private static bool IsStale(BaseItem item, CacheEntry entry)
    {
        var config = Plugin.Instance!.Configuration;
        if (entry.Counts != null && entry.Counts.Sum() == 0)
        {
            // Written by 0.1.0, which misread the nested season response as ten zeros.
            return true;
        }

        DateTime? released = item.PremiereDate;
        if (released == null && item.ProductionYear is int year)
        {
            released = new DateTime(year, 1, 1, 0, 0, 0, DateTimeKind.Utc);
        }

        bool recent = released == null || released.Value > DateTime.UtcNow.AddDays(-180);
        int days = recent ? config.RecentCacheDays : config.OlderCacheDays;
        if (entry.Counts == null)
        {
            // Retry missing entries at the shorter interval: Trakt adds new titles over time.
            days = Math.Min(days, config.RecentCacheDays);
        }

        return entry.FetchedAt < DateTime.UtcNow.AddDays(-Math.Max(1, days));
    }

    private async Task<string?> ResolvePathAsync(BaseItem item, CancellationToken cancellationToken)
    {
        switch (item)
        {
            case Movie movie:
            {
                string? id = await ResolveTraktIdAsync(movie, "movie", cancellationToken).ConfigureAwait(false);
                return id == null ? null : $"/movies/{id}/ratings";
            }

            case Series series:
            {
                string? id = await ResolveTraktIdAsync(series, "show", cancellationToken).ConfigureAwait(false);
                return id == null ? null : $"/shows/{id}/ratings";
            }

            case Season season when season.Series != null && season.IndexNumber is int seasonNumber:
            {
                string? id = await ResolveTraktIdAsync(season.Series, "show", cancellationToken).ConfigureAwait(false);
                return id == null ? null : $"/shows/{id}/seasons/{seasonNumber}/ratings";
            }

            case Episode episode when episode.Series != null && episode.ParentIndexNumber is int s && episode.IndexNumber is int e:
            {
                string? id = await ResolveTraktIdAsync(episode.Series, "show", cancellationToken).ConfigureAwait(false);
                return id == null ? null : $"/shows/{id}/seasons/{s}/episodes/{e}/ratings";
            }

            default:
                return null;
        }
    }

    // Trakt accepts an IMDb ID directly in /movies/:id and /shows/:id. TMDB and TVDB IDs need a search first.
    private async Task<string?> ResolveTraktIdAsync(BaseItem item, string mediaType, CancellationToken cancellationToken)
    {
        string? imdb = item.GetProviderId(MetadataProvider.Imdb);
        if (!string.IsNullOrWhiteSpace(imdb))
        {
            return imdb;
        }

        string? tmdb = item.GetProviderId(MetadataProvider.Tmdb);
        if (!string.IsNullOrWhiteSpace(tmdb))
        {
            int? traktId = await _trakt.LookupTraktIdAsync("tmdb", tmdb, mediaType, cancellationToken).ConfigureAwait(false);
            if (traktId != null)
            {
                return traktId.Value.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
        }

        string? tvdb = item.GetProviderId(MetadataProvider.Tvdb);
        if (mediaType == "show" && !string.IsNullOrWhiteSpace(tvdb))
        {
            int? traktId = await _trakt.LookupTraktIdAsync("tvdb", tvdb, mediaType, cancellationToken).ConfigureAwait(false);
            if (traktId != null)
            {
                return traktId.Value.ToString(System.Globalization.CultureInfo.InvariantCulture);
            }
        }

        return null;
    }

    private static string? TraktUrl(BaseItem item)
    {
        BaseItem? withIds = item switch
        {
            Season season => season.Series,
            _ => item
        };
        string? imdb = withIds?.GetProviderId(MetadataProvider.Imdb);
        if (string.IsNullOrWhiteSpace(imdb) && item is Episode episode)
        {
            imdb = episode.Series?.GetProviderId(MetadataProvider.Imdb);
        }

        return string.IsNullOrWhiteSpace(imdb) ? null : "https://trakt.tv/search/imdb/" + Uri.EscapeDataString(imdb);
    }
}
