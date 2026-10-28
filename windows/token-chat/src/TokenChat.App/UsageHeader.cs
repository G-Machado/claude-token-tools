using System.ComponentModel;
using System.Globalization;
using System.Text.Json.Nodes;
using System.Windows;
using System.Windows.Media;
using TokenChat.Core;

namespace TokenChat.App;

/// <summary>One plan account as the widget's limits rows draw it: the five-hour and seven-day windows, each a bar, a
/// percentage and the time to its reset.</summary>
public sealed record AccountRow(bool Active, string N, string Email, LimitGauge FiveHour, LimitGauge SevenDay);

public sealed record LimitGauge(double Fill, Brush Brush, string Pct, string ResetsIn);

/// <summary>The sidebar header, off the last collect: the plan limits per account. Replaced whole on every rebuild;
/// nothing in it is selectable.</summary>
public sealed class UsageHeader : INotifyPropertyChanged
{
    static Brush B(string key) => (Brush)Application.Current.Resources[key];

    public IReadOnlyList<AccountRow> Accounts { get; private set; } = [];
    public bool HasAccounts => Accounts.Count > 0;

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>The widget's Limit-Color.</summary>
    static Brush LimitBrush(double pct) => B(pct >= 90 ? "Red" : pct >= 75 ? "Orange" : pct >= 50 ? "Yellow" : "Green");

    internal void Set(FeedSnapshot? feed)
    {
        var accounts = new List<AccountRow>();
        foreach (var a in (feed?.Limits?["accounts"] as JsonArray)?.OfType<JsonObject>() ?? [])
        {
            var active = SidebarItem.Num(a, "active") == 1;
            var email = SidebarItem.Str(a, "email");
            var n = SidebarItem.Num(a, "n");
            accounts.Add(new AccountRow(active, n > 0 ? n.ToString(CultureInfo.InvariantCulture) : "-", email,
                Gauge(a, "five_hour"), Gauge(a, "seven_day")));
        }
        // the active account first
        Accounts = [.. accounts.OrderByDescending(a => a.Active)];

        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null)); // every binding re-reads
    }

    static LimitGauge Gauge(JsonObject a, string window)
    {
        var pct = SidebarItem.Num(a, window + "_pct");
        // "3h 37m" -> "3h37m", as the widget does: four numbers on a row already
        return new LimitGauge(Math.Clamp(pct / 100, 0, 1), LimitBrush(pct), $"{pct:0}%",
            SidebarItem.Str(a, window + "_in").Replace(" ", ""));
    }
}
