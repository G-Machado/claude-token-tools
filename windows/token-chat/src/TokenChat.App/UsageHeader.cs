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

/// <summary>The sidebar header, off the last collect: the plan limits per account and today's spend against
/// TOKEN_DAY_CAP. Replaced whole on every rebuild; nothing in it is selectable.</summary>
public sealed class UsageHeader : INotifyPropertyChanged
{
    static Brush B(string key) => (Brush)Application.Current.Resources[key];

    public IReadOnlyList<AccountRow> Accounts { get; private set; } = [];
    public bool HasAccounts => Accounts.Count > 0;
    /// <summary>The active account's name, the part before the @.</summary>
    public string Account { get; private set; } = "";
    public double DayFill { get; private set; }
    public Brush DayBrush { get; private set; } = Brushes.Transparent;
    public string DayText { get; private set; } = "";
    public string DayTip { get; private set; } = "";
    public bool HasDay { get; private set; }

    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>The widget's Limit-Color.</summary>
    static Brush LimitBrush(double pct) => B(pct >= 90 ? "Red" : pct >= 75 ? "Orange" : pct >= 50 ? "Yellow" : "Green");

    /// <summary>The ramp --stats colours its day bars with: green under 60% of the cap, red past it.</summary>
    static Brush DayColor(double ratio) => B(ratio > 1 ? "Red" : ratio >= 0.8 ? "Orange" : ratio >= 0.6 ? "Yellow" : "Green");

    /// <summary>Thousands of weighted tokens as the widget writes them: 820k, 7.9M.</summary>
    static string K(double k) => k >= 1000 ? (k / 1000).ToString("0.0", CultureInfo.InvariantCulture) + "M" : $"{k:0}k";

    internal void Set(FeedSnapshot? feed)
    {
        var accounts = new List<AccountRow>();
        Account = "";
        foreach (var a in (feed?.Limits?["accounts"] as JsonArray)?.OfType<JsonObject>() ?? [])
        {
            var active = SidebarItem.Num(a, "active") == 1;
            var email = SidebarItem.Str(a, "email");
            if (active) Account = email.Split('@')[0];
            var n = SidebarItem.Num(a, "n");
            accounts.Add(new AccountRow(active, n > 0 ? n.ToString(CultureInfo.InvariantCulture) : "-", email,
                Gauge(a, "five_hour"), Gauge(a, "seven_day")));
        }
        // the active account first
        Accounts = [.. accounts.OrderByDescending(a => a.Active)];

        var cap = SidebarItem.Num(feed?.Constants, "day_cap") / 1000;
        var day = SidebarItem.Num(feed?.Overall, "spend_day");
        HasDay = cap > 0 && feed?.Overall?["spend_day"] is not null;
        DayFill = HasDay ? Math.Clamp(day / cap, 0, 1) : 0;
        DayBrush = DayColor(HasDay ? day / cap : 0);
        DayText = $"{K(day)} of {K(cap)}";
        DayTip = "weighted tokens since midnight, against TOKEN_DAY_CAP";
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
