using Jellyfin.Plugin.RatingDistribution.Services;
using MediaBrowser.Controller;
using MediaBrowser.Controller.Plugins;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.DependencyInjection;

namespace Jellyfin.Plugin.RatingDistribution;

public class PluginServiceRegistrator : IPluginServiceRegistrator
{
    public void RegisterServices(IServiceCollection serviceCollection, IServerApplicationHost applicationHost)
    {
        // Jellyfin 12 has no script-injection hook. Middleware ahead of the static-file
        // handler adds our <script> tag to index.html. Jellyfin Enhanced 12.11 uses the same pattern.
        serviceCollection.AddSingleton<IStartupFilter, ScriptInjectionStartupFilter>();
        serviceCollection.AddSingleton<RatingCache>();
        serviceCollection.AddSingleton<TraktClient>();
        serviceCollection.AddSingleton<DistributionService>();
    }
}
