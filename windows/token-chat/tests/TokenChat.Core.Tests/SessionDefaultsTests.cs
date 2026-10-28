namespace TokenChat.Core.Tests;

public class SessionDefaultsTests
{
    [Fact]
    public void RoundTripsAndABrokenFileIsNoDefaults()
    {
        var path = Path.Combine(Path.GetTempPath(), $"tc-defaults-{Guid.NewGuid():N}.json");
        try
        {
            Assert.Null(SessionDefaults.Load(path).Model);
            new SessionDefaults { Model = "sonnet", Effort = "high" }.Save(path);
            var d = SessionDefaults.Load(path);
            Assert.Equal("sonnet", d.Model);
            Assert.Equal("high", d.Effort);
            File.WriteAllText(path, "{not json");
            Assert.Null(SessionDefaults.Load(path).Effort);
        }
        finally { File.Delete(path); }
    }
}
