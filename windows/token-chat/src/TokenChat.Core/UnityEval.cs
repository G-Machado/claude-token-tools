using System.Text.Json.Nodes;

namespace TokenChat.Core;

/// <summary>The Editor tab's side of the unity CLI: which folder is a Unity project, the C# statements
/// <c>unity command eval</c> runs (a snapshot: scene image + hierarchy; an inspect: one object's components), and reading
/// the CLI's output. Read-only on the project: the only Editor state touched is the selection, on a pick.</summary>
public static class UnityEval
{
    /// <summary>The Unity project holding <paramref name="dir"/> (the nearest folder up with Assets/ and ProjectSettings/),
    /// else null.</summary>
    public static string? ProjectRoot(string? dir)
    {
        if (string.IsNullOrWhiteSpace(dir)) return null;
        try
        {
            for (var d = new DirectoryInfo(Path.GetFullPath(dir)); d is not null; d = d.Parent)
                if (Directory.Exists(Path.Combine(d.FullName, "Assets")) && Directory.Exists(Path.Combine(d.FullName, "ProjectSettings")))
                    return Path.TrimEndingDirectorySeparator(d.FullName);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException) { }
        return null;
    }

    /// <summary>The first complete JSON object in <paramref name="s"/>: the CLI can append a second object, or print a
    /// notice before it.</summary>
    public static string? FirstJson(string s)
    {
        var start = s.IndexOf('{');
        if (start < 0) return null;
        int depth = 0;
        bool str = false, esc = false;
        for (var i = start; i < s.Length; i++)
        {
            var c = s[i];
            if (str)
            {
                if (esc) esc = false;
                else if (c == '\\') esc = true;
                else if (c == '"') str = false;
                continue;
            }
            if (c == '"') str = true;
            else if (c == '{') depth++;
            else if (c == '}' && --depth == 0) return s[start..(i + 1)];
        }
        return null;
    }

    /// <summary>An eval's outcome: the statement's returned string, or why there is none.</summary>
    public readonly record struct Outcome(string? Value, string? Error)
    {
        public bool Ok => Error is null;
    }

    /// <summary>Reads <c>unity command eval --format json</c> output, with or without <c>--result-only</c>: the value sits
    /// under nested <c>data</c>/<c>result</c> keys (twice nested in the full envelope), errors under <c>errors</c>,
    /// <c>diagnostics</c> or <c>message</c>.</summary>
    public static Outcome ReadEval(string stdout)
    {
        if (FirstJson(stdout) is not { } json) return new(null, stdout.Trim() is { Length: > 0 } t ? Clip(t) : "no output");
        JsonNode? node;
        try { node = JsonNode.Parse(json); }
        catch (System.Text.Json.JsonException) { return new(null, "unreadable output: " + Clip(json)); }
        string? error = null;
        while (node is JsonObject o)
        {
            error ??= ErrorOf(o);
            if (o["result"] is { } r) node = r;
            else if (o["data"] is { } d) node = d;
            else break;
        }
        if (node is JsonValue v && v.TryGetValue<string>(out var s)) return new(s, null);
        return new(null, error ?? "no result");
    }

    static string? ErrorOf(JsonObject o)
    {
        if (o["errors"] is JsonArray { Count: > 0 } errs) return (string?)errs[0]?["message"] ?? errs[0]?.ToJsonString();
        if (o["diagnostics"] is JsonArray { Count: > 0 } diags) return string.Join("; ", diags.Select(x => x is JsonValue ? (string?)x : (string?)x?["message"] ?? x?.ToJsonString()));
        if (o["success"] is JsonValue sv && sv.TryGetValue<bool>(out var ok) && !ok && o["message"] is JsonValue m) return (string?)m;
        return null;
    }

    static string Clip(string s) => s.Length > 300 ? s[..300] + "…" : s;

    /// <summary>The pid of the Editor serving <paramref name="root"/> in <c>unity status --format json</c>: the instance
    /// whose path names the project if one does, else the first; null when none runs. Batch: a -batchmode (headless) Editor.</summary>
    public static (int Pid, string State, bool Batch)? PickInstance(string statusJson, string root)
    {
        if (FirstJson(statusJson) is not { } json) return null;
        JsonNode? node;
        try { node = JsonNode.Parse(json); }
        catch (System.Text.Json.JsonException) { return null; }
        if (node?["data"]?["instances"] is not JsonArray list || list.Count == 0) return null;
        var key = Project.Key(root);
        JsonNode? pick = list.FirstOrDefault(i => i is JsonObject o && o.Any(kv =>
            kv.Value is JsonValue v && v.TryGetValue<string>(out var s) && s.Length > 2 && (s.Contains('/') || s.Contains('\\'))
            && SafeKey(s) == key)) ?? list[0];
        if (pick?["pid"] is not JsonValue p || !p.TryGetValue<int>(out var pid)) return null;
        return (pid, (string?)pick["state"] ?? "", pick["batchmode"] is JsonValue b && b.TryGetValue<bool>(out var batch) && batch);
    }

    static string? SafeKey(string path)
    {
        try { return Project.Key(path); }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException) { return null; }
    }

    static string CsString(string s) => "\"" + s.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";

    const string Esc = """
        System.Func<string, string> esc = t => (t ?? "").Replace("\\", "\\\\").Replace("\"", "\\\"").Replace("\n", "\\n").Replace("\r", "").Replace("\t", " ");

        """;

    /// <summary>One eval for the tab: renders the active scene to a <paramref name="width"/>×<paramref name="height"/>
    /// PNG at <paramref name="png"/> (from the Scene view's camera, else the main camera, else any enabled one, else
    /// framed on the renderers' bounds) and returns the hierarchy as JSON:
    /// <c>{scene, unity, from, sel, nodes:[{id,d,n,a,c}], count, truncated, scenes:[path]}</c>, nodes depth-first,
    /// scenes the enabled build scenes first, then every other scene under Assets.</summary>
    public static string SnapshotScript(string png, int width = 960, int height = 540) =>
        "string outPath = " + CsString(png.Replace('\\', '/')) + "; int W = " + width + ", H = " + height + ";\n" + Esc + """
        var scene = UnityEngine.SceneManagement.SceneManager.GetActiveScene();
        UnityEngine.Camera src = null; string from = "";
        var sv = UnityEditor.SceneView.lastActiveSceneView;
        if (sv != null && sv.camera != null) { src = sv.camera; from = "scene view"; }
        if (src == null && UnityEngine.Camera.main != null) { src = UnityEngine.Camera.main; from = src.name; }
        if (src == null) foreach (var c in UnityEngine.Object.FindObjectsByType<UnityEngine.Camera>(UnityEngine.FindObjectsSortMode.None))
            if (c.enabled && c.gameObject.activeInHierarchy && c.targetTexture == null) { src = c; from = c.name; break; }
        var go = new UnityEngine.GameObject("__tokenchat_shot"); go.hideFlags = UnityEngine.HideFlags.HideAndDontSave;
        var cam = go.AddComponent<UnityEngine.Camera>();
        if (src != null) cam.CopyFrom(src);
        else {
            var b = new UnityEngine.Bounds(); bool has = false;
            foreach (var r in UnityEngine.Object.FindObjectsByType<UnityEngine.Renderer>(UnityEngine.FindObjectsSortMode.None)) {
                if (!r.enabled || !r.gameObject.activeInHierarchy) continue;
                if (!has) { b = r.bounds; has = true; } else b.Encapsulate(r.bounds);
            }
            cam.fieldOfView = 50f; cam.nearClipPlane = 0.1f;
            var dir = new UnityEngine.Vector3(-1f, 0.8f, -1f).normalized;
            float dist = UnityEngine.Mathf.Max(b.extents.magnitude, 1f) / UnityEngine.Mathf.Sin(25f * UnityEngine.Mathf.Deg2Rad);
            cam.farClipPlane = dist * 4f;
            go.transform.position = b.center + dir * dist; go.transform.LookAt(b.center);
            from = "framed";
        }
        cam.cameraType = UnityEngine.CameraType.Game; cam.stereoTargetEye = UnityEngine.StereoTargetEyeMask.None;
        var rt = new UnityEngine.RenderTexture(W, H, 24);
        cam.targetTexture = rt; cam.aspect = (float)W / H;
        cam.Render();
        var prev = UnityEngine.RenderTexture.active; UnityEngine.RenderTexture.active = rt;
        var tex = new UnityEngine.Texture2D(W, H, UnityEngine.TextureFormat.RGB24, false);
        tex.ReadPixels(new UnityEngine.Rect(0, 0, W, H), 0, 0); tex.Apply();
        UnityEngine.RenderTexture.active = prev;
        System.IO.Directory.CreateDirectory(System.IO.Path.GetDirectoryName(outPath));
        System.IO.File.WriteAllBytes(outPath + ".tmp", UnityEngine.ImageConversion.EncodeToPNG(tex));
        if (System.IO.File.Exists(outPath)) System.IO.File.Delete(outPath);
        System.IO.File.Move(outPath + ".tmp", outPath);
        cam.targetTexture = null;
        UnityEngine.Object.DestroyImmediate(tex); UnityEngine.Object.DestroyImmediate(go); rt.Release(); UnityEngine.Object.DestroyImmediate(rt);
        var sb = new System.Text.StringBuilder();
        sb.Append("{\"scene\":\"").Append(esc(scene.path)).Append("\",\"unity\":\"").Append(UnityEngine.Application.unityVersion)
          .Append("\",\"from\":\"").Append(esc(from)).Append("\",\"sel\":").Append(UnityEditor.Selection.activeInstanceID).Append(",\"nodes\":[");
        var stack = new System.Collections.Generic.Stack<System.Tuple<UnityEngine.Transform, int>>();
        var roots = scene.GetRootGameObjects();
        for (int i = roots.Length - 1; i >= 0; i--) stack.Push(System.Tuple.Create(roots[i].transform, 0));
        int n = 0;
        while (stack.Count > 0 && n < 5000) {
            var e = stack.Pop(); var t = e.Item1;
            if (n++ > 0) sb.Append(',');
            sb.Append("{\"id\":").Append(t.gameObject.GetInstanceID()).Append(",\"d\":").Append(e.Item2)
              .Append(",\"n\":\"").Append(esc(t.name)).Append("\",\"a\":").Append(t.gameObject.activeInHierarchy ? "1" : "0")
              .Append(",\"c\":").Append(t.childCount).Append('}');
            for (int c = t.childCount - 1; c >= 0; c--) stack.Push(System.Tuple.Create(t.GetChild(c), e.Item2 + 1));
        }
        sb.Append("],\"count\":").Append(n).Append(",\"truncated\":").Append(stack.Count > 0 ? "true" : "false").Append(",\"scenes\":[");
        var scenes = new System.Collections.Generic.List<string>();
        foreach (var s in UnityEditor.EditorBuildSettings.scenes) if (s.enabled && !scenes.Contains(s.path)) scenes.Add(s.path);
        foreach (var g in UnityEditor.AssetDatabase.FindAssets("t:Scene", new[] { "Assets" })) {
            var p = UnityEditor.AssetDatabase.GUIDToAssetPath(g);
            if (!scenes.Contains(p)) scenes.Add(p);
        }
        for (int i = 0; i < scenes.Count; i++) { if (i > 0) sb.Append(','); sb.Append('"').Append(esc(scenes[i])).Append('"'); }
        sb.Append("]}");
        return sb.ToString();
        """;

    /// <summary>Opens a scene in the Editor without saving anything; refuses while a loaded scene has unsaved changes,
    /// so a windowed Editor never loses work. Returns "ok" or the reason.</summary>
    public static string OpenSceneScript(string path) => "string path = " + CsString(path) + ";\n" + """
        for (int i = 0; i < UnityEngine.SceneManagement.SceneManager.sceneCount; i++)
            if (UnityEngine.SceneManagement.SceneManager.GetSceneAt(i).isDirty) return "the Editor has unsaved changes: save or discard them there first";
        if (UnityEditor.AssetDatabase.LoadAssetAtPath<UnityEditor.SceneAsset>(path) == null) return "no scene at " + path;
        UnityEditor.SceneManagement.EditorSceneManager.OpenScene(path, UnityEditor.SceneManagement.OpenSceneMode.Single);
        return "ok";
        """;

    /// <summary>One object's inspector, read-only, as JSON: <c>{id, n, tag, layer, a, comps:[{t, en, p:[{n, v}]}]}</c>
    /// (<c>en</c> -1 for a component with no enabled flag). Also selects it in the Editor.</summary>
    public static string InspectScript(int id) => "int id = " + id + ";\n" + Esc + """
        var go = UnityEditor.EditorUtility.InstanceIDToObject(id) as UnityEngine.GameObject;
        if (go == null) return "{\"error\":\"that object is gone\"}";
        UnityEditor.Selection.activeInstanceID = id;
        var sb = new System.Text.StringBuilder();
        sb.Append("{\"id\":").Append(id).Append(",\"n\":\"").Append(esc(go.name)).Append("\",\"tag\":\"").Append(esc(go.tag))
          .Append("\",\"layer\":\"").Append(esc(UnityEngine.LayerMask.LayerToName(go.layer))).Append("\",\"a\":").Append(go.activeSelf ? "1" : "0").Append(",\"comps\":[");
        int ci = 0;
        foreach (var comp in go.GetComponents<UnityEngine.Component>()) {
            if (ci++ > 0) sb.Append(',');
            if (comp == null) { sb.Append("{\"t\":\"(Missing script)\",\"en\":-1,\"p\":[]}"); continue; }
            var beh = comp as UnityEngine.Behaviour;
            sb.Append("{\"t\":\"").Append(esc(comp.GetType().Name)).Append("\",\"en\":").Append(beh == null ? "-1" : (beh.enabled ? "1" : "0")).Append(",\"p\":[");
            var so = new UnityEditor.SerializedObject(comp);
            var it = so.GetIterator();
            int pi = 0; bool enter = true;
            while (it.NextVisible(enter) && pi < 80) {
                enter = false;
                if (it.name == "m_Script") continue;
                string v;
                switch (it.propertyType) {
                    case UnityEditor.SerializedPropertyType.Integer: v = it.longValue.ToString(); break;
                    case UnityEditor.SerializedPropertyType.Boolean: v = it.boolValue ? "true" : "false"; break;
                    case UnityEditor.SerializedPropertyType.Float: v = it.floatValue.ToString("G5"); break;
                    case UnityEditor.SerializedPropertyType.String: v = it.stringValue; break;
                    case UnityEditor.SerializedPropertyType.Color: v = it.colorValue.ToString(); break;
                    case UnityEditor.SerializedPropertyType.ObjectReference: v = it.objectReferenceValue == null ? "None" : it.objectReferenceValue.name + " (" + it.objectReferenceValue.GetType().Name + ")"; break;
                    case UnityEditor.SerializedPropertyType.LayerMask: v = it.intValue.ToString(); break;
                    case UnityEditor.SerializedPropertyType.Enum: v = it.enumValueIndex >= 0 && it.enumValueIndex < it.enumDisplayNames.Length ? it.enumDisplayNames[it.enumValueIndex] : it.intValue.ToString(); break;
                    case UnityEditor.SerializedPropertyType.Vector2: v = it.vector2Value.ToString(); break;
                    case UnityEditor.SerializedPropertyType.Vector3: v = it.vector3Value.ToString(); break;
                    case UnityEditor.SerializedPropertyType.Vector4: v = it.vector4Value.ToString(); break;
                    case UnityEditor.SerializedPropertyType.Quaternion: v = it.quaternionValue.eulerAngles.ToString(); break;
                    case UnityEditor.SerializedPropertyType.Rect: v = it.rectValue.ToString(); break;
                    case UnityEditor.SerializedPropertyType.Bounds: v = it.boundsValue.ToString(); break;
                    default: v = it.isArray ? "[" + it.arraySize + "]" : "(" + it.propertyType + ")"; break;
                }
                if (pi++ > 0) sb.Append(',');
                sb.Append("{\"n\":\"").Append(esc(it.displayName)).Append("\",\"v\":\"").Append(esc(v)).Append("\"}");
            }
            sb.Append("]}");
        }
        sb.Append("]}");
        return sb.ToString();
        """;
}
