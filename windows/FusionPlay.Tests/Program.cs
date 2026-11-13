using FusionPlay.Core;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

if (args.Contains("--devices"))
{
    Console.WriteLine(JsonSerializer.Serialize(new { networks = NativeReceiver.Networks(), outputs = NativeReceiver.Outputs() }, WireJson.Options));
    return 0;
}

var tests = new List<(string Name, Func<Task> Run)>();
void Check(string name, Action test) => tests.Add((name, () => { test(); return Task.CompletedTask; }));
void AsyncCheck(string name, Func<Task> test) => tests.Add((name, test));
void Assert(bool condition, string message) { if (!condition) throw new InvalidOperationException(message); }
void Throws<T>(Action test) where T : Exception
{
    try { test(); } catch (T) { return; }
    throw new InvalidOperationException("Expected " + typeof(T).Name);
}
async Task ArtworkError(string code, Func<Task<byte[]>> action)
{
    try { await action(); } catch (ArtworkException e) { Assert(e.Code == code, $"Expected {code}, got {e.Code}"); return; }
    throw new InvalidOperationException("Expected artwork rejection: " + code);
}
Check("volume: stale report cannot replace a drag or pending submission", () =>
{
    var v = new VolumeInteraction(); v.Observe(50); v.BeginEditing(); v.Edit(83); v.Observe(30);
    Assert(v.Value == 83, "drag overwritten");
    var pending = v.Submit(); v.Observe(30); Assert(v.Value == 83, "pending overwritten");
    v.Complete(pending.Token, true); v.Observe(83); v.Observe(42);
    Assert(v.Value == 42, "feedback not restored");
});
Check("volume: late completion and expiry cannot replace a newer gesture", () =>
{
    var v = new VolumeInteraction(); v.BeginEditing(); v.Edit(20); var a = v.Submit();
    v.BeginEditing(); v.Edit(70); var b = v.Submit(); Assert(!v.Complete(a.Token, true), "stale completion accepted");
    v.Complete(b.Token, true); v.BeginEditing(); v.Edit(91); v.Expire(b.Token);
    Assert(v.Value == 91 && v.IsEditing, "expiry replaced gesture");
});
Check("volume: failure and lost acknowledgement recover", () =>
{
    var v = new VolumeInteraction(); v.Observe(37); v.Edit(99); var a = v.Submit(); v.Complete(a.Token, false);
    Assert(v.Value == 37, "failed value retained");
    v.Edit(10); var b = v.Submit(); v.Complete(b.Token, true); v.Expire(b.Token);
    v.Observe(65); Assert(v.Value == 65, "timeout kept slider locked");
});
Check("volume: values are clamped", () =>
{
    var v = new VolumeInteraction(); v.Edit(-1); Assert(v.Value == 0, "negative value");
    v.Edit(200); Assert(v.Value == 100, "overflow value"); v.Observe(200); Assert(v.Value == 100, "remote overflow");
});
byte[] png = Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aZYkAAAAASUVORK5CYII=");
string encoded = Convert.ToBase64String(png);
AsyncCheck("artwork: inline and raw phone cover formats", async () =>
{
    foreach (string source in new[] { encoded, "data:image/png;base64," + encoded, JsonSerializer.Serialize(encoded), "\n" + encoded + "\n" })
        Assert((await ArtworkLoader.LoadAsync(source, default)).SequenceEqual(png), "cover bytes changed");
});
Check("artwork: format classification and URL normalization", () =>
{
    Assert(ArtworkLoader.Kind(encoded) == "raw_base64", "raw encoding not classified");
    Assert(ArtworkLoader.Kind("data:image/png;base64," + encoded) == "inline", "inline not classified");
    Assert(ArtworkLoader.Normalize("//example.test/a.png") == "https://example.test/a.png", "scheme-relative URL");
    Assert(!ArtworkLoader.IsNetworkUrl(new Uri("https://u:p@example.test/a.png")), "credentials accepted");
});
AsyncCheck("artwork: files and phone content paths never become desktop reads", async () =>
{
    foreach (string source in new[] { "file:///C:/Windows/win.ini", "content://media/a", "android.resource://a", "https://u:p@example.test/a", @"C:\Windows\win.ini" })
        await ArtworkError("unsupported_source", () => ArtworkLoader.LoadAsync(source, default));
});
AsyncCheck("artwork: invalid inline and oversized input are rejected", async () =>
{
    await ArtworkError("invalid_inline_data", () => ArtworkLoader.LoadAsync("data:image/png;base64,invalid", default));
    await ArtworkError("size_limit", () => ArtworkLoader.LoadAsync(new string('A', 5_400_000), default));
});
AsyncCheck("artwork: real HTTP downloads, redirects and limits", async () =>
{
    await using var server = new ImageServer(png);
    Assert((await ArtworkLoader.LoadAsync(server.Url + "image", default)).SequenceEqual(png), "HTTP image corrupted");
    Assert((await ArtworkLoader.LoadAsync(server.Url + "redirect", default)).SequenceEqual(png), "HTTP redirect broken");
    await ArtworkError("size_limit", () => ArtworkLoader.LoadAsync(server.Url + "large", default));
    await ArtworkError("unsupported_source", () => ArtworkLoader.LoadAsync(server.Url + "file", default));
    await ArtworkError("unsupported_source", () => ArtworkLoader.LoadAsync(server.Url + "credentials", default));
    try { await ArtworkLoader.LoadAsync(server.Url + "unavailable", default); throw new Exception("503 accepted"); }
    catch (ArtworkException e) { Assert(e.Code == "http_503" && e.Retryable, "503 not retryable"); }
    await ArtworkError("http_404", () => ArtworkLoader.LoadAsync(server.Url + "missing", default));
});
AsyncCheck("artwork: cancellation interrupts a real pending download", async () =>
{
    await using var server = new ImageServer(png);
    using var cancellation = new CancellationTokenSource(100);
    try { await ArtworkLoader.LoadAsync(server.Url + "slow", cancellation.Token); throw new Exception("cancellation ignored"); }
    catch (OperationCanceledException) { }
});
Check("portable data: ownership, Chinese paths, settings and migration backup", () =>
{
    using var temporary = new TemporaryDirectory();
    var store = new PortableStore(Path.Combine(temporary.Path, "中文 程序"));
    store.Initialize();
    File.WriteAllText(Path.Combine(store.Data, "settings.json"), "{\"name\":\"我的电脑\"}");
    File.WriteAllText(Path.Combine(store.Data, "identity.json"), "{\"idm\":\"old\"}");
    store.Initialize();
    File.WriteAllBytes(Path.Combine(store.Data, "owner.bin"), [0, 1, 2]);
    Throws<IdentityMigrationRequiredException>(store.Initialize);
    Assert(File.ReadAllText(Path.Combine(store.Data, "identity.json")).Contains("old"), "identity silently changed");
    store.MigrateIdentity(); store.Initialize();
    Assert(File.ReadAllText(Path.Combine(store.Data, "settings.json")).Contains("我的电脑"), "settings lost");
    Assert(!File.Exists(Path.Combine(store.Data, "identity.json")), "copied identity reused");
    Assert(Directory.GetFiles(Path.Combine(store.Root, "identity-backups"), "identity.json", SearchOption.AllDirectories).Length == 1, "old identity not backed up");
});
Check("portable data: artwork diagnostics never include source or track metadata", () =>
{
    using var temporary = new TemporaryDirectory(); var store = new PortableStore(temporary.Path); store.Initialize();
    store.ArtworkDiagnostic("raw_base64", "loaded", 1);
    using var log = JsonDocument.Parse(File.ReadAllText(Path.Combine(store.Logs, "artwork.jsonl")));
    Assert(log.RootElement.EnumerateObject().Select(p => p.Name).Order().SequenceEqual(new[] { "attempt", "result", "source_kind", "time" }), "diagnostics contract expanded");
});
Check("wire: snapshot enums and missing progress round trip", () =>
{
    var state = JsonSerializer.Deserialize<ReceiverSnapshot>("{\"phase\":\"Playing\",\"title\":\"音乐\",\"controls_available\":true,\"duration_ms\":null,\"position_ms\":null,\"volume\":23}", WireJson.Options)!;
    Assert(state.HasMedia && state.Phase == ReceiverPhase.Playing && state.DurationMs == null, "snapshot contract mismatch");
    Assert(JsonSerializer.Serialize(PlaybackCommand.Next, WireJson.Options) == "\"Next\"", "command wire mismatch");
});

if (args.Contains("--native") || args.Contains("--network"))
{
    AsyncCheck("native DLL: 10 managed create/GC/dispose cycles preserve identity and settings", async () =>
    {
        using var temporary = new TemporaryDirectory();
        string directory = Path.Combine(temporary.Path, "原生 数据"); string? identity = null;
        for (int index = 0; index < 10; index++)
        {
            using (var receiver = new NativeReceiver(directory))
            {
                identity ??= File.ReadAllText(Path.Combine(directory, "identity.json"));
                Assert(File.ReadAllText(Path.Combine(directory, "identity.json")) == identity, "identity changed");
                Throws<ReceiverException>(() => { using var other = new NativeReceiver(directory); });
                Throws<ReceiverException>(() => receiver.Control(PlaybackCommand.Next));
                Throws<ReceiverException>(() => receiver.SetVolume(101));
                receiver.SetVolume(23);
                Assert(receiver.Settings().Volume == 23, "setting was not persisted");
                var state = receiver.Poll(); Assert(state.Snapshot != null, "initial state missing");
                Assert(receiver.Poll(state.Revision).Snapshot == null, "unchanged state repeated");
                receiver.Stop(); receiver.Stop();
            }
            GC.Collect(); GC.WaitForPendingFinalizers(); await Task.Yield();
        }
    });
    Check("native DLL: Windows adapter and sound output enumeration", () =>
    {
        var networks = NativeReceiver.Networks(); var outputs = NativeReceiver.Outputs();
        Assert(networks.Select(n => n.Name + n.Address).Distinct().Count() == networks.Length, "duplicate interface rows");
        Assert(outputs.Select(o => o.Id).Distinct().Count() == outputs.Length, "duplicate output IDs");
        Console.WriteLine($"  Available interfaces: {networks.Length}; output endpoints: {outputs.Length}");
    });
    Check("native DLL: output calibration survives reopen and rejects a stale endpoint", () =>
    {
        using var temporary = new TemporaryDirectory();
        string directory = Path.Combine(temporary.Path, "校准 数据");
        OutputCalibration saved;
        using (var receiver = new NativeReceiver(directory))
        {
            var initial = receiver.Calibration();
            Assert(initial.OffsetMs == 0, "default calibration changed");
            if (initial.OutputDeviceId.Length == 0) return; // A machine without sound cannot calibrate an endpoint.
            Throws<ReceiverException>(() => receiver.SetCalibration(initial with { OffsetMs = 501 }));
            Throws<ReceiverException>(() => receiver.SetCalibration(initial with { OffsetMs = -501 }));
            Throws<ReceiverException>(() => receiver.SetCalibration(initial with { OutputDeviceId = "stale-endpoint" }));
            foreach (int offset in new[] { -500, -125, 0, 500 })
            {
                receiver.SetCalibration(initial with { OffsetMs = offset });
                Assert(receiver.Calibration().OffsetMs == offset, "signed direction or boundary changed");
            }
            saved = initial with { OffsetMs = 125 };
            receiver.SetCalibration(saved);
            Assert(receiver.Calibration() == saved, "calibration not applied to the selected endpoint");
        }
        using var reopened = new NativeReceiver(directory);
        Assert(reopened.Calibration() == saved, "calibration lost on reopen");
    });
    Check("native DLL: legacy advance migrates without reversing playback direction", () =>
    {
        using var temporary = new TemporaryDirectory();
        string directory = Path.Combine(temporary.Path, "legacy-calibration");
        string endpoint;
        using (var receiver = new NativeReceiver(directory)) endpoint = receiver.Calibration().OutputDeviceId;
        if (endpoint.Length == 0) return;
        File.WriteAllText(Path.Combine(directory, "output-calibration.json"), JsonSerializer.Serialize(new { outputs = new Dictionary<string, uint> { [endpoint] = 500, ["other-endpoint"] = 90 } }));
        using (var receiver = new NativeReceiver(directory))
        {
            Assert(receiver.Calibration().OffsetMs == -500, "legacy advance direction changed");
            receiver.SetCalibration(new(endpoint, 40));
        }
        using var reopened = new NativeReceiver(directory);
        Assert(reopened.Calibration().OffsetMs == 40, "signed delay did not persist after migration");
        using var saved = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, "output-calibration.json")));
        Assert(saved.RootElement.GetProperty("outputs").GetProperty("other-endpoint").GetInt32() == 90, "another endpoint was lost during migration");
    });
}
if (args.Contains("--network"))
{
    AsyncCheck("native LAN: start/stop/restart and malformed control isolation", async () =>
    {
        using var temporary = new TemporaryDirectory();
        using var receiver = new NativeReceiver(Path.Combine(temporary.Path, "data"));
        for (int run = 0; run < 3; run++)
        {
            receiver.Start(receiver.Settings() with { Name = "FusionPlay-Windows-Diagnostic" });
            ReceiverSnapshot? snapshot = null;
            for (int count = 0; count < 100; count++)
            {
                snapshot = receiver.Poll().Snapshot;
                if (snapshot?.Phase == ReceiverPhase.Ready) break;
                await Task.Delay(50);
            }
            Assert(snapshot?.Phase == ReceiverPhase.Ready, "LAN receiver did not become ready");
            ushort port = JsonSerializer.Deserialize<ushort>(File.ReadAllText(Path.Combine(temporary.Path, "data", "control-port.json")));
            using (var socket = new TcpClient())
            {
                await socket.ConnectAsync(IPAddress.Parse(snapshot!.Address), port);
                await socket.GetStream().WriteAsync("BADHEADER"u8.ToArray());
            }
            await Task.Delay(400);
            Assert(receiver.Poll().Snapshot!.Phase == ReceiverPhase.Ready, "control error destroyed listener");
            receiver.Stop();
            Assert(receiver.Poll().Snapshot!.Phase == ReceiverPhase.Stopped, "stop did not release state");
        }
    });
}
Check("appearance preferences: portable defaults, persistence and invalid-input isolation", () =>
{
    using var temporary = new TemporaryDirectory();
    var preferences = new UiPreferencesStore(temporary.Path);
    Assert(preferences.Value.ShowTransport && preferences.Value.ShowTaskbarIcon && preferences.Value.ShowTrayIcon, "unsafe default entry visibility");
    Assert(preferences.Value.ProgressColorMode == "system" && preferences.Value.ProgressCustomColor == "#FFFFFF", "progress color defaults changed");
    int changes = 0; preferences.Changed += () => changes++;
    var expected = preferences.Value with { Language = "en", Pinned = true, ShowPinButton = true, AlwaysShowControls = true, ShowTaskbarIcon = false, ShowTrayIcon = false };
    preferences.Update(expected); preferences.Update(expected);
    Assert(changes == 1, "unchanged preferences notified twice");
    Assert(new UiPreferencesStore(temporary.Path).Value == expected, "portable UI state lost on reopen");
    Throws<ArgumentException>(() => preferences.Update(expected with { Language = "invalid" }));
    Assert(new UiPreferencesStore(temporary.Path).Value == expected, "invalid language modified saved state");
});
Check("appearance preferences: progress choices persist and invalid colors leave saved and active values intact", () =>
{
    using var temporary = new TemporaryDirectory();
    var preferences = new UiPreferencesStore(temporary.Path);
    foreach (string mode in new[] { "white", "custom", "system" })
    {
        var expected = preferences.Value with { ProgressColorMode = mode, ProgressCustomColor = "#a0B1c2" };
        preferences.Update(expected);
        Assert(new UiPreferencesStore(temporary.Path).Value == expected, "progress choice or custom color was lost on reopen");
    }
    var saved = preferences.Value;
    string file = Path.Combine(temporary.Path, "ui-preferences.json"), savedJson = File.ReadAllText(file);
    int changes = 0; preferences.Changed += () => changes++;
    var invalidChoices = new[]
    {
        saved with { ProgressColorMode = "accent" },
        saved with { ProgressCustomColor = "#80FFFFFF" }, // An alpha channel is not supported.
        saved with { ProgressCustomColor = "#FFF" },
        saved with { ProgressCustomColor = "#12345G" },
        saved with { ProgressCustomColor = "FFFFFF" },
        saved with { ProgressCustomColor = null! }
    };
    foreach (var invalid in invalidChoices)
    {
        Throws<ArgumentException>(() => preferences.Update(invalid));
        Assert(preferences.Value == saved && File.ReadAllText(file) == savedJson, "invalid progress choice modified active or saved appearance");
    }
    Assert(changes == 0, "invalid progress choice notified listeners");
    Assert(new UiPreferencesStore(temporary.Path).Value == saved, "invalid progress choice affected reopened preferences");
});
Check("appearance preferences: failed persistence leaves the active value unchanged", () =>
{
    using var temporary = new TemporaryDirectory();
    var preferences = new UiPreferencesStore(temporary.Path);
    Directory.CreateDirectory(Path.Combine(temporary.Path, "ui-preferences.json"));
    bool rejected = false;
    try { preferences.Update(preferences.Value with { Language = "en" }); }
    catch (Exception e) when (e is IOException or UnauthorizedAccessException) { rejected = true; }
    Assert(rejected, "non-file destination unexpectedly accepted");
    Assert(preferences.Value == new UiPreferences(), "failed write changed active appearance");
    Assert(Directory.GetFiles(temporary.Path, "*.tmp-*").Length == 0, "failed atomic save left temporary data");
});
Check("appearance preferences: malformed originals retained and partial older settings get defaults", () =>
{
    using var temporary = new TemporaryDirectory();
    string file = Path.Combine(temporary.Path, "ui-preferences.json");
    File.WriteAllText(file, "{broken");
    var recovered = new UiPreferencesStore(temporary.Path);
    Assert(recovered.Value == new UiPreferences() && recovered.LoadError.Length > 0, "corruption did not recover");
    string backup = Directory.GetFiles(temporary.Path, "ui-preferences.json.invalid-*").Single();
    Assert(File.ReadAllText(backup) == "{broken", "invalid preferences discarded");
    File.WriteAllText(file, "{\"language\":\"en\"}");
    var legacy = new UiPreferencesStore(temporary.Path).Value;
    Assert(legacy.Language == "en" && legacy.ShowTransport && legacy.ShowTrayIcon && legacy.ShowTaskbarIcon, "missing fields lost defaults");
    Assert(legacy.ProgressColorMode == "system" && legacy.ProgressCustomColor == "#FFFFFF", "older preferences did not receive progress defaults");
    const string invalidColor = "{\"progress_color_mode\":\"custom\",\"progress_custom_color\":\"#80FF0000\"}";
    File.WriteAllText(file, invalidColor);
    var invalidProgress = new UiPreferencesStore(temporary.Path);
    Assert(invalidProgress.Value == new UiPreferences() && invalidProgress.LoadError.Length > 0, "invalid stored progress color did not recover safely");
    Assert(Directory.GetFiles(temporary.Path, "ui-preferences.json.invalid-*").Any(path => File.ReadAllText(path) == invalidColor), "invalid stored progress color was not retained");
});
Check("artwork: disconnect and metadata gaps can cancel repeatedly before reconnect", () =>
{
    using var lifetime = new CancellationTokenSource();
    using var requests = new ArtworkRequestScope();
    for (int cycle = 0; cycle < 30; cycle++)
    {
        var load = requests.Start(lifetime.Token);
        Assert(!load.IsCancellationRequested, "new cover request already cancelled");
        requests.Cancel(); requests.Cancel();
        Assert(load.IsCancellationRequested, "disconnect did not cancel old cover request");
        var reconnected = requests.Start(lifetime.Token);
        var replacement = requests.Start(lifetime.Token);
        Assert(reconnected.IsCancellationRequested && !replacement.IsCancellationRequested, "new metadata did not replace the old request");
    }
    var final = requests.Start(lifetime.Token); lifetime.Cancel();
    Assert(final.IsCancellationRequested, "application shutdown did not cancel cover loading");
    requests.Dispose(); requests.Cancel();
});
int passed = 0, failed = 0;
foreach (var (name, run) in tests)
{
    try { await run(); passed++; Console.WriteLine("PASS " + name); }
    catch (Exception e) { failed++; Console.WriteLine("FAIL " + name + ": " + e.Message); }
}
Console.WriteLine($"{passed} passed; {failed} failed. Phone playback and acoustic synchronization are not covered by this runner.");
return failed == 0 ? 0 : 1;

sealed class TemporaryDirectory : IDisposable
{
    private readonly string boundary = System.IO.Path.GetFullPath(System.IO.Path.GetTempPath());
    public string Path { get; }
    public TemporaryDirectory() { Path = System.IO.Path.Combine(boundary, "fusionplay-tests-" + Guid.NewGuid().ToString("N")); Directory.CreateDirectory(Path); }
    public void Dispose()
    {
        string resolved = System.IO.Path.GetFullPath(Path);
        if (!resolved.StartsWith(boundary, StringComparison.OrdinalIgnoreCase) || !System.IO.Path.GetFileName(resolved).StartsWith("fusionplay-tests-", StringComparison.Ordinal))
            throw new InvalidOperationException("Refused unsafe temporary-directory cleanup");
        Directory.Delete(resolved, recursive: true);
    }
}

sealed class ImageServer : IAsyncDisposable
{
    private readonly TcpListener listener = new(IPAddress.Loopback, 0);
    private readonly CancellationTokenSource cancellation = new();
    private readonly Task server;
    public string Url { get; }
    public ImageServer(byte[] image)
    {
        listener.Start(); Url = $"http://127.0.0.1:{((IPEndPoint)listener.LocalEndpoint).Port}/";
        server = Task.Run(async () =>
        {
            while (!cancellation.IsCancellationRequested)
            {
                try
                {
                    using var client = await listener.AcceptTcpClientAsync(cancellation.Token);
                    using var stream = client.GetStream();
                    using var reader = new StreamReader(stream, leaveOpen: true);
                    string? line = await reader.ReadLineAsync(cancellation.Token);
                    string route = line?.Split(' ').ElementAtOrDefault(1) ?? "";
                    while (!string.IsNullOrEmpty(await reader.ReadLineAsync(cancellation.Token))) { }
                    if (route == "/slow") { await Task.Delay(500, cancellation.Token); continue; }
                    string header = route switch
                    {
                        "/image" => $"200 OK\r\nContent-Type: image/png\r\nContent-Length: {image.Length}",
                        "/redirect" => "302 Found\r\nLocation: /image\r\nContent-Length: 0",
                        "/large" => "200 OK\r\nContent-Length: 4000001",
                        "/file" => "302 Found\r\nLocation: file:///C:/Windows/win.ini\r\nContent-Length: 0",
                        "/credentials" => "302 Found\r\nLocation: http://u:p@127.0.0.1/a\r\nContent-Length: 0",
                        "/unavailable" => "503 Service Unavailable\r\nContent-Length: 0",
                        _ => "404 Not Found\r\nContent-Length: 0"
                    };
                    await stream.WriteAsync(Encoding.ASCII.GetBytes("HTTP/1.1 " + header + "\r\nConnection: close\r\n\r\n"), cancellation.Token);
                    if (route == "/image") await stream.WriteAsync(image, cancellation.Token);
                }
                catch (OperationCanceledException) { break; }
                catch (IOException) { }
                catch (SocketException) when (cancellation.IsCancellationRequested) { break; }
            }
        });
    }
    public async ValueTask DisposeAsync() { cancellation.Cancel(); listener.Stop(); await server; cancellation.Dispose(); }
}
