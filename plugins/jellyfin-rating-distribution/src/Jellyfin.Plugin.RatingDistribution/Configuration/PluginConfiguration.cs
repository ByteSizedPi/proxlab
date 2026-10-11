using MediaBrowser.Model.Plugins;

namespace Jellyfin.Plugin.RatingDistribution.Configuration;

public class PluginConfiguration : BasePluginConfiguration
{
    /// <summary>
    /// Gets or sets the Trakt client ID. If empty, the plugin reads the TRAKT_CLIENT_ID environment variable.
    /// </summary>
    public string TraktClientId { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the vote count below which the panel shows no chart.
    /// </summary>
    public int MinVotes { get; set; } = 30;

    /// <summary>
    /// Gets or sets the cache lifetime in days for items released in the last 180 days.
    /// </summary>
    public int RecentCacheDays { get; set; } = 7;

    /// <summary>
    /// Gets or sets the cache lifetime in days for older items.
    /// </summary>
    public int OlderCacheDays { get; set; } = 30;
}
