using TokenChat.Core;

namespace TokenChat.Core.Tests;

static class Fixture
{
    public static readonly TheoryData<string> All = new("full", "noskills", "perm", "slim", "tools");

    public static IReadOnlyList<string> Lines(string name)
    {
        var lines = File.ReadAllLines(Path.Combine(AppContext.BaseDirectory, "Fixtures", name + ".jsonl"))
            .Where(l => l.Length > 0).ToList();
        Assert.NotEmpty(lines);
        return lines;
    }

    public static ReplayTransport Replay(string name) => new(Lines(name));
}
