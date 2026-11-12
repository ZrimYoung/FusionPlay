using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace FusionPlay.Windows.Platform;

internal sealed class SingleInstance : IDisposable
{
    private readonly Mutex mutex;
    private readonly string pipeName;
    private readonly CancellationTokenSource lifetime = new();
    private Task? listener;
    public bool IsPrimary { get; }
    public SingleInstance()
    {
        string user = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
        string suffix = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(user)))[..20];
        pipeName = "FusionPlay.Windows." + suffix;
        mutex = new Mutex(true, @"Local\" + pipeName, out bool created);
        IsPrimary = created;
    }
    public async Task NotifyPrimaryAsync()
    {
        try
        {
            await using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.Out, PipeOptions.Asynchronous);
            await client.ConnectAsync(2000);
            await client.WriteAsync(new byte[] { 1 });
        }
        catch (Exception e) when (e is IOException or TimeoutException or OperationCanceledException) { }
    }
    public void Listen(Action show)
    {
        listener = Task.Run(async () =>
        {
            while (!lifetime.IsCancellationRequested)
            {
                try
                {
                    await using var pipe = new NamedPipeServerStream(pipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    await pipe.WaitForConnectionAsync(lifetime.Token);
                    var buffer = new byte[1];
                    if (await pipe.ReadAsync(buffer, lifetime.Token) == 1 && buffer[0] == 1) show();
                }
                catch (OperationCanceledException) { break; }
                catch (IOException) { await Task.Delay(200, lifetime.Token); }
            }
        }, lifetime.Token);
    }
    public void Dispose()
    {
        lifetime.Cancel();
        if (IsPrimary) mutex.ReleaseMutex();
        mutex.Dispose(); lifetime.Dispose();
    }
}
