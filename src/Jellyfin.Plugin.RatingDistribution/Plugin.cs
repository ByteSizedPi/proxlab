using Jellyfin.Plugin.RatingDistribution.Configuration;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Common.Plugins;
using MediaBrowser.Model.Plugins;
using MediaBrowser.Model.Serialization;

namespace Jellyfin.Plugin.RatingDistribution;

/// <summary>
/// Shows the Trakt audience-rating distribution on the item detail page.
/// </summary>
public class Plugin : BasePlugin<PluginConfiguration>, IHasWebPages
{
    public const string PluginGuid = "1ae1801e-6503-43d1-b063-3c1a3605b302";

    public Plugin(IApplicationPaths applicationPaths, IXmlSerializer xmlSerializer)
        : base(applicationPaths, xmlSerializer)
    {
        Instance = this;
    }

    public static Plugin? Instance { get; private set; }

    public override string Name => "Rating Distribution";

    public override Guid Id => Guid.Parse(PluginGuid);

    public override string Description => "Shows the Trakt audience-rating distribution on the item detail page.";

    /// <summary>
    /// Gets the version string used to bust the browser cache for the client script.
    /// </summary>
    public string ScriptVersion => Version.ToString();

    public IEnumerable<PluginPageInfo> GetPages()
    {
        return
        [
            new PluginPageInfo
            {
                Name = Name,
                EmbeddedResourcePath = GetType().Namespace + ".Configuration.configPage.html"
            }
        ];
    }
}
