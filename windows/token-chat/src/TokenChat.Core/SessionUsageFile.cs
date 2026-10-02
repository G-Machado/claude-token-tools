using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace TokenChat.Core;

/// <summary>~/.claude/session-usage/&lt;sid&gt;.json, which the terminal's status line rewrites and headless
/// claude never writes. token-sessions.sh takes a window's cache expiry and context from it, and pokes
/// (extension marks) only windows that have one; poke_landed watches <c>requests</c> move.
/// Only the fields those readers use, in the status line's shape.</summary>
public sealed class SessionUsageFile(string dir)
{
    public static string DefaultDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "session-usage");

    // The readers are awk regexes: "key":value with no spaces, paths escaped the way the status line does.
    static readonly JsonSerializerOptions Compact = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    public string PathFor(string sessionId) => Path.Combine(dir, sessionId + ".json");

    /// <summary>Called as a main-chain request is first seen: its prompt was cached just now, for an hour
    /// (headless writes are all 1h TTL).</summary>
    public void Write(string sessionId, string cwd, long context, int requests, DateTimeOffset at)
    {
        var json = new JsonObject
        {
            ["session_id"] = sessionId,
            ["cwd"] = cwd,
            ["context_window"] = new JsonObject { ["total_input_tokens"] = context },
            ["prompt_cache"] = new JsonObject
            {
                ["ttl"] = "1h",
                ["expires_at"] = at.ToUnixTimeSeconds() + 3600,
                ["requests"] = requests,
            },
        }.ToJsonString(Compact);

        // Temp file and replace, so a reader never sees half a payload. The temp name stays out of *.json.
        // A reader holding the file can fail the replace; the next request writes it again.
        var path = PathFor(sessionId);
        var tmp = path + ".tc";
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                Directory.CreateDirectory(dir);
                File.WriteAllText(tmp, json);
                File.Move(tmp, path, overwrite: true);
                return;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException && attempt < 2)
            {
                Thread.Sleep(50);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return; }
        }
    }

    /// <summary>The status line rewrites its payload every few seconds while a window is open, and readers take one
    /// untouched for TOKEN_SU_LIVE (120s) as a closed window. Moves only the mtime; no-op before the first request.</summary>
    public void Touch(string sessionId)
    {
        var path = PathFor(sessionId);
        try { if (File.Exists(path)) File.SetLastWriteTimeUtc(path, DateTime.UtcNow); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}
