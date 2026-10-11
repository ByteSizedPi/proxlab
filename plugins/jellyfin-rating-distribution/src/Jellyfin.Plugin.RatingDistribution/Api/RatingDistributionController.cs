using System.Reflection;
using Jellyfin.Plugin.RatingDistribution.Services;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Library;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;

namespace Jellyfin.Plugin.RatingDistribution.Api;

[ApiController]
[Route("RatingDistribution")]
public class RatingDistributionController : ControllerBase
{
    // The claim name Jellyfin's auth handler puts the user ID under.
    private const string UserIdClaim = "Jellyfin-UserId";

    private readonly ILibraryManager _libraryManager;
    private readonly IUserManager _userManager;
    private readonly DistributionService _distributions;

    public RatingDistributionController(ILibraryManager libraryManager, IUserManager userManager, DistributionService distributions)
    {
        _libraryManager = libraryManager;
        _userManager = userManager;
        _distributions = distributions;
    }

    /// <summary>
    /// Gets the Trakt rating distribution for a library item.
    /// </summary>
    [HttpGet("Items/{itemId}")]
    [Authorize]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(StatusCodes.Status404NotFound)]
    public async Task<ActionResult<DistributionDto>> GetItemDistribution([FromRoute] Guid itemId, CancellationToken cancellationToken)
    {
        BaseItem? item = _libraryManager.GetItemById(itemId);
        if (item == null)
        {
            return NotFound();
        }

        // Do not reveal items the caller cannot see.
        if (Guid.TryParse(User.FindFirst(UserIdClaim)?.Value, out Guid userId))
        {
            var user = _userManager.GetUserById(userId);
            if (user == null || !item.IsVisible(user))
            {
                return NotFound();
            }
        }

        return await _distributions.GetAsync(item, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Serves the client script that the injected script tag loads.
    /// </summary>
    [HttpGet("script")]
    [AllowAnonymous]
    [Produces("application/javascript")]
    public ActionResult GetScript()
    {
        Assembly assembly = GetType().Assembly;
        Stream? stream = assembly.GetManifestResourceStream(typeof(Plugin).Namespace + ".Web.rating-distribution.js");
        if (stream == null)
        {
            return NotFound();
        }

        Response.Headers.CacheControl = "public, max-age=3600";
        return File(stream, "application/javascript; charset=utf-8");
    }
}
