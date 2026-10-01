namespace TokenChat.Core.Transcript;

public enum DiffKind { Same, Added, Removed, Gap }

/// <summary>One row of a diff preview. Gap rows stand for lines left out; Text says how many.</summary>
public sealed record DiffLine(DiffKind Kind, string Text);

/// <summary>Line diff for permission previews: common prefix and suffix trimmed, LCS on the middle,
/// unchanged runs folded to <see cref="Context"/> lines either side.</summary>
public static class LineDiff
{
    public const int Context = 3, MaxLines = 400;
    const long MaxCells = 1_000_000; // LCS table size; past it the middle shows as all removed, then all added

    public static List<DiffLine> Compute(string before, string after)
    {
        var a = Split(before);
        var b = Split(after);
        int pre = 0, suf = 0;
        while (pre < a.Length && pre < b.Length && a[pre] == b[pre]) pre++;
        while (suf < a.Length - pre && suf < b.Length - pre && a[^(suf + 1)] == b[^(suf + 1)]) suf++;

        var rows = new List<DiffLine>(a.Length + b.Length);
        rows.AddRange(a[..pre].Select(l => new DiffLine(DiffKind.Same, l)));
        Middle(a[pre..^suf], b[pre..^suf], rows);
        rows.AddRange(a[^suf..].Select(l => new DiffLine(DiffKind.Same, l)));
        return Fold(rows);
    }

    static string[] Split(string s) => s.Length == 0 ? [] : s.ReplaceLineEndings("\n").TrimEnd('\n').Split('\n');

    static void Middle(string[] a, string[] b, List<DiffLine> rows)
    {
        if ((long)a.Length * b.Length > MaxCells)
        {
            rows.AddRange(a.Select(l => new DiffLine(DiffKind.Removed, l)));
            rows.AddRange(b.Select(l => new DiffLine(DiffKind.Added, l)));
            return;
        }
        var lcs = new int[a.Length + 1, b.Length + 1];
        for (var i = a.Length - 1; i >= 0; i--)
            for (var j = b.Length - 1; j >= 0; j--)
                lcs[i, j] = a[i] == b[j] ? lcs[i + 1, j + 1] + 1 : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);
        int x = 0, y = 0;
        while (x < a.Length && y < b.Length)
        {
            if (a[x] == b[y]) { rows.Add(new(DiffKind.Same, a[x])); x++; y++; }
            else if (lcs[x + 1, y] >= lcs[x, y + 1]) rows.Add(new(DiffKind.Removed, a[x++]));
            else rows.Add(new(DiffKind.Added, b[y++]));
        }
        while (x < a.Length) rows.Add(new(DiffKind.Removed, a[x++]));
        while (y < b.Length) rows.Add(new(DiffKind.Added, b[y++]));
    }

    static List<DiffLine> Fold(List<DiffLine> rows)
    {
        var folded = new List<DiffLine>();
        for (var i = 0; i < rows.Count;)
        {
            if (rows[i].Kind != DiffKind.Same) { folded.Add(rows[i++]); continue; }
            var end = i;
            while (end < rows.Count && rows[end].Kind == DiffKind.Same) end++;
            var head = i == 0 ? 0 : Context;            // context after the change above
            var tail = end == rows.Count ? 0 : Context; // context before the change below
            if (end - i <= head + tail + 1) folded.AddRange(rows[i..end]);
            else
            {
                folded.AddRange(rows[i..(i + head)]);
                folded.Add(Gap(end - i - head - tail, "unchanged"));
                folded.AddRange(rows[(end - tail)..end]);
            }
            i = end;
        }
        if (folded.Count > MaxLines)
        {
            var more = folded.Skip(MaxLines).Count(r => r.Kind != DiffKind.Gap);
            folded.RemoveRange(MaxLines, folded.Count - MaxLines);
            folded.Add(Gap(more, "more"));
        }
        return folded;
    }

    static DiffLine Gap(int lines, string what) => new(DiffKind.Gap, $"⋯ {lines} {what} line{(lines == 1 ? "" : "s")}");
}
