using System.Collections.Concurrent;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.RatingDistribution.Services;

public sealed class CacheEntry
{
    /// <summary>
    /// Gets or sets the vote counts for ratings 1 to 10 (index 0 is rating 1). Null when Trakt has no entry.
    /// </summary>
    public int[]? Counts { get; set; }

    public int Votes { get; set; }

    public double TraktRating { get; set; }

    public DateTime FetchedAt { get; set; }
}

/// <summary>
/// Keeps Trakt results in one JSON file in the plugin data folder, keyed by Trakt API path.
/// </summary>
public sealed class RatingCache
{
    private static readonly JsonSerializerOptions s_jsonOptions = new() { WriteIndented = false };

    private readonly ILogger<RatingCache> _logger;
    private readonly SemaphoreSlim _saveLock = new(1, 1);
    private readonly Lazy<ConcurrentDictionary<string, CacheEntry>> _entries;

    public RatingCache(ILogger<RatingCache> logger)
    {
        _logger = logger;
        _entries = new Lazy<ConcurrentDictionary<string, CacheEntry>>(Load);
    }

    private static string FilePath
        => Path.Combine(Plugin.Instance?.DataFolderPath ?? Path.GetTempPath(), "trakt-cache.json");

    public bool TryGet(string key, out CacheEntry? entry) => _entries.Value.TryGetValue(key, out entry);

    public async Task SetAsync(string key, CacheEntry entry)
    {
        _entries.Value[key] = entry;
        await _saveLock.WaitAsync().ConfigureAwait(false);
        try
        {
            string path = FilePath;
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            string tmp = path + ".tmp";
            await File.WriteAllTextAsync(tmp, JsonSerializer.Serialize(_entries.Value, s_jsonOptions)).ConfigureAwait(false);
            File.Move(tmp, path, overwrite: true);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Rating Distribution: could not write {Path}", FilePath);
        }
        finally
        {
            _saveLock.Release();
        }
    }

    private ConcurrentDictionary<string, CacheEntry> Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                Dictionary<string, CacheEntry>? data = JsonSerializer.Deserialize<Dictionary<string, CacheEntry>>(File.ReadAllText(FilePath));
                if (data != null)
                {
                    return new ConcurrentDictionary<string, CacheEntry>(data);
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Rating Distribution: could not read {Path}, starting with an empty cache", FilePath);
        }

        return new ConcurrentDictionary<string, CacheEntry>();
    }
}
