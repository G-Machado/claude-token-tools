namespace TokenChat.Core.Tests;

public class UnityEvalTests
{
    [Fact]
    public void AProjectIsTheNearestFolderUpWithAssetsAndProjectSettings()
    {
        var root = Directory.CreateTempSubdirectory("tc-unity-").FullName;
        try
        {
            Directory.CreateDirectory(Path.Combine(root, "Assets", "Scripts"));
            Assert.Null(UnityEval.ProjectRoot(root));
            Directory.CreateDirectory(Path.Combine(root, "ProjectSettings"));
            Assert.Equal(Path.TrimEndingDirectorySeparator(root), UnityEval.ProjectRoot(Path.Combine(root, "Assets", "Scripts")));
            Assert.Equal(Path.TrimEndingDirectorySeparator(root), UnityEval.ProjectRoot(root + "\\"));
        }
        finally { Directory.Delete(root, true); }
    }

    [Fact]
    public void NoFolderIsNoProject()
    {
        Assert.Null(UnityEval.ProjectRoot(null));
        Assert.Null(UnityEval.ProjectRoot(""));
    }

    [Fact]
    public void FirstJsonSkipsANoticeAndATrailingObjectAndBracesInStrings()
    {
        const string s = "notice: update available\n{\"a\":\"}{\\\"\",\"b\":{\"c\":1}}\n{\"second\":true}";
        Assert.Equal("{\"a\":\"}{\\\"\",\"b\":{\"c\":1}}", UnityEval.FirstJson(s));
        Assert.Null(UnityEval.FirstJson("no json"));
        Assert.Null(UnityEval.FirstJson("{\"open\":"));
    }

    [Fact]
    public void ReadsTheValueFromTheFullEnvelope()
    {
        // as the CLI printed it on FlightLander, 2026-11-05: data.result.result
        const string s = """{"success":true,"command":"command eval","data":{"command":"eval","parameters":{"code":"return 1;"},"result":{"output":null,"diagnostics":[],"success":true,"result":"{\"x\":1}"}}}""";
        var o = UnityEval.ReadEval(s);
        Assert.True(o.Ok);
        Assert.Equal("{\"x\":1}", o.Value);
    }

    [Fact]
    public void ReadsTheValueFromAResultOnlyPrint()
    {
        var o = UnityEval.ReadEval("""{"output":null,"diagnostics":[],"success":true,"result":"42"}""");
        Assert.Equal("42", o.Value);
    }

    [Fact]
    public void ACompileErrorIsTheError()
    {
        var o = UnityEval.ReadEval("""{"output":null,"diagnostics":[{"message":"(1,5): error CS1002: ; expected"}],"success":false,"result":null}""");
        Assert.False(o.Ok);
        Assert.Contains("CS1002", o.Error);
    }

    [Fact]
    public void ACliErrorIsTheError()
    {
        var o = UnityEval.ReadEval("""{"success":false,"command":"status","data":{"count":0,"instances":[]},"errors":[{"code":"STATUS_NO_INSTANCES","message":"No Unity Editor instances found"}]}""");
        Assert.Equal("No Unity Editor instances found", o.Error);
    }

    [Fact]
    public void PicksTheInstanceWhosePathIsTheProject()
    {
        const string s = """{"success":true,"data":{"count":2,"instances":[{"pid":11,"state":"ready","projectPath":"C:/Other"},{"pid":22,"state":"ready","projectPath":"c:\\work\\Game","batchmode":true}]}}""";
        Assert.Equal((22, "ready", true), UnityEval.PickInstance(s, @"C:\Work\Game"));
    }

    [Fact]
    public void WithNoPathToMatchTheFirstInstanceServes()
    {
        Assert.Equal((7, "busy", false), UnityEval.PickInstance("""{"data":{"instances":[{"pid":7,"state":"busy"}]}}""", @"C:\Work\Game"));
        Assert.Null(UnityEval.PickInstance("""{"data":{"instances":[]}}""", @"C:\Work\Game"));
    }

    [Fact]
    public void ScriptsCarryTheirArgumentsAsCSharp()
    {
        Assert.Contains("string outPath = \"C:/Users/x/a \\\"b\\\".png\";", UnityEval.SnapshotScript(@"C:\Users\x\a ""b"".png"));
        Assert.StartsWith("int id = -2268;", UnityEval.InspectScript(-2268));
        Assert.EndsWith("return sb.ToString();", UnityEval.InspectScript(1));
        Assert.StartsWith("string path = \"Assets/A \\\"x\\\".unity\";", UnityEval.OpenSceneScript("Assets/A \"x\".unity"));
    }
}
