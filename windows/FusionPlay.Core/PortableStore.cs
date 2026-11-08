using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace FusionPlay.Core;

public sealed class IdentityMigrationRequiredException() : Exception("这份设备数据来自其他电脑或用户。请为本机建立独立身份，避免出现重复投放设备。");

public sealed class PortableStore
{
    private static readonly byte[] OwnerValue = Encoding.UTF8.GetBytes("FusionPlay-Windows-owner-v1");
    public string Root { get; }
    public string Data { get; }
    public string Logs { get; }
    public PortableStore(string programDirectory)
    {
        Root = Path.Combine(Path.GetFullPath(programDirectory), "FusionPlayData");
        Data = Path.Combine(Root, "data"); Logs = Path.Combine(Root, "logs");
    }
    public void Initialize()
    {
        Directory.CreateDirectory(Data); Directory.CreateDirectory(Logs);
        var probe = Path.Combine(Data, $".write-{Guid.NewGuid():N}");
        File.WriteAllBytes(probe, []); File.Delete(probe);
        var path = Path.Combine(Data, "owner.bin");
        if (!File.Exists(path)) { WriteOwner(path); return; }
        try
        {
            var decrypted = ProtectedData.Unprotect(File.ReadAllBytes(path), null, DataProtectionScope.CurrentUser);
            if (!CryptographicOperations.FixedTimeEquals(decrypted, OwnerValue)) throw new IdentityMigrationRequiredException();
        }
        catch (CryptographicException) { throw new IdentityMigrationRequiredException(); }
    }
    // Called only after an explicit migration choice, before a native receiver
    // acquires this directory. Settings survive and the old identity is retained.
    public void MigrateIdentity()
    {
        string backup = Path.Combine(Root, "identity-backups", $"{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(backup);
        foreach (string name in new[] { "identity.json", "owner.bin", "control-port.json" })
        {
            string source = Path.Combine(Data, name);
            if (File.Exists(source)) File.Move(source, Path.Combine(backup, name));
        }
        WriteOwner(Path.Combine(Data, "owner.bin"));
    }
    private static void WriteOwner(string path)
    {
        byte[] protectedValue = ProtectedData.Protect(OwnerValue, null, DataProtectionScope.CurrentUser);
        string temp = path + ".tmp"; File.WriteAllBytes(temp, protectedValue); File.Move(temp, path, true);
    }
    public void ArtworkDiagnostic(string kind, string result, int attempt) => WriteLog("artwork", new { time = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), source_kind = kind, result, attempt }, 50_000);
    public void EventDiagnostic(string code) => WriteLog("application", new { time = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), code }, 500_000);
    private readonly object logGate = new();
    private void WriteLog(string name, object record, long maximum)
    {
        try
        {
            lock (logGate)
            {
                string path = Path.Combine(Logs, name + ".jsonl");
                if (File.Exists(path) && new FileInfo(path).Length > maximum) File.Move(path, Path.Combine(Logs, name + ".previous.jsonl"), true);
                File.AppendAllText(path, JsonSerializer.Serialize(record) + "\n");
            }
        }
        catch (IOException) { /* Diagnostics must not stop audio. */ }
        catch (UnauthorizedAccessException) { }
    }
}
