using System.Text;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace Jellyfin.Plugin.RatingDistribution.Services;

/// <summary>
/// Adds the client script tag to jellyfin-web's index.html when the server sends it.
/// Nothing on disk changes. On any error the original page goes out unchanged.
/// </summary>
public class ScriptInjectionStartupFilter : IStartupFilter
{
    private const string ScriptPath = "/RatingDistribution/script";

    private readonly ILogger<ScriptInjectionStartupFilter> _logger;
    private int _loggedOnce;

    public ScriptInjectionStartupFilter(ILogger<ScriptInjectionStartupFilter> logger)
    {
        _logger = logger;
    }

    public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next)
    {
        return app =>
        {
            app.Use(InvokeAsync);
            next(app);
        };
    }

    private async Task InvokeAsync(HttpContext context, Func<Task> nextMw)
    {
        if (!HttpMethods.IsGet(context.Request.Method) || !IsIndexRequest(context.Request.Path.Value))
        {
            await nextMw().ConfigureAwait(false);
            return;
        }

        // Ask for a plain, complete 200 so the body can be rewritten.
        context.Request.Headers.Remove("Accept-Encoding");
        context.Request.Headers.Remove("Range");
        context.Request.Headers.Remove("If-Range");

        Stream originalBody = context.Response.Body;
        using MemoryStream buffer = new MemoryStream();
        context.Response.Body = buffer;
        try
        {
            await nextMw().ConfigureAwait(false);
        }
        finally
        {
            context.Response.Body = originalBody;
        }

        buffer.Seek(0, SeekOrigin.Begin);
        bool isHtml = context.Response.StatusCode == StatusCodes.Status200OK
            && (context.Response.ContentType?.Contains("text/html", StringComparison.OrdinalIgnoreCase) ?? false);
        if (!isHtml)
        {
            await buffer.CopyToAsync(originalBody).ConfigureAwait(false);
            return;
        }

        string html;
        using (StreamReader reader = new StreamReader(buffer, Encoding.UTF8, true, 1024, leaveOpen: true))
        {
            html = await reader.ReadToEndAsync().ConfigureAwait(false);
        }

        try
        {
            int bodyClose = html.LastIndexOf("</body>", StringComparison.OrdinalIgnoreCase);
            bool alreadyInjected = html.Contains(ScriptPath, StringComparison.OrdinalIgnoreCase);
            if (!alreadyInjected && bodyClose >= 0)
            {
                string version = Plugin.Instance?.ScriptVersion ?? "0";
                string tag = $"<script plugin=\"Rating Distribution\" src=\"..{ScriptPath}?v={version}\" defer></script>";
                html = html.Substring(0, bodyClose) + tag + "\n" + html.Substring(bodyClose);
                if (Interlocked.Exchange(ref _loggedOnce, 1) == 0)
                {
                    _logger.LogInformation("Rating Distribution: added the client script to index.html");
                }
            }
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Rating Distribution: script injection failed, serving the original index.html");
        }

        byte[] bytes = Encoding.UTF8.GetBytes(html);
        context.Response.ContentType = "text/html;charset=utf-8";
        context.Response.ContentLength = bytes.Length;
        context.Response.Headers.Remove("ETag");
        context.Response.Headers.Remove("Last-Modified");
        context.Response.Headers.Remove("Accept-Ranges");
        await originalBody.WriteAsync(bytes).ConfigureAwait(false);
    }

    // Matches "/web", "/web/" and "/web/index.html", also under a base-url prefix.
    private static bool IsIndexRequest(string? path)
    {
        if (string.IsNullOrEmpty(path))
        {
            return false;
        }

        return path.EndsWith("/web/index.html", StringComparison.OrdinalIgnoreCase)
            || path.EndsWith("/web/", StringComparison.OrdinalIgnoreCase)
            || path.EndsWith("/web", StringComparison.OrdinalIgnoreCase);
    }
}
