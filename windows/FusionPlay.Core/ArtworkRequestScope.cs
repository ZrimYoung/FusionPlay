namespace FusionPlay.Core;

/// <summary>Owns the current artwork request across metadata gaps, disconnects and reconnects.</summary>
public sealed class ArtworkRequestScope : IDisposable
{
    private CancellationTokenSource? source;

    public CancellationToken Start(CancellationToken lifetime)
    {
        Cancel();
        source = CancellationTokenSource.CreateLinkedTokenSource(lifetime);
        return source.Token;
    }

    public void Cancel()
    {
        // Publish the empty state first: a disconnect may be followed by another
        // disconnect or an immediate reconnect before the old load completes.
        var previous = source; source = null;
        if (previous == null) return;
        try { previous.Cancel(); }
        finally { previous.Dispose(); }
    }

    public void Dispose() => Cancel();
}
