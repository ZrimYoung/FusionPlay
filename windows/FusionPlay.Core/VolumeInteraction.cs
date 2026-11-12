namespace FusionPlay.Core;

// One shared draft for the tray and player. Late receiver reports and stale
// command completions cannot replace an active gesture/newer submission.
public sealed class VolumeInteraction
{
    private sealed class Pending(ulong token, uint value, bool acknowledged)
    {
        public ulong Token = token;
        public uint Value = value;
        public bool Acknowledged = acknowledged;
        public bool Completed;
    }
    public double Value { get; private set; } = 50;
    public bool IsEditing { get; private set; }
    private uint remote = 50;
    private ulong sequence;
    private Pending? pending;
    public void Edit(double value) => Value = Math.Clamp(value, 0, 100);
    public void BeginEditing() => IsEditing = true;
    public void Observe(uint value)
    {
        remote = Math.Min(value, 100);
        if (pending?.Value == remote) pending.Acknowledged = true;
        if (pending is { Completed: true, Acknowledged: true }) pending = null;
        if (!IsEditing && pending == null) Value = remote;
    }
    public (ulong Token, uint Value) Submit()
    {
        IsEditing = false; Value = Math.Round(Value);
        pending = new Pending(++sequence, (uint)Value, remote == (uint)Value);
        return (sequence, (uint)Value);
    }
    public bool Complete(ulong token, bool succeeded)
    {
        if (pending?.Token != token) return false;
        if (succeeded) { pending.Completed = true; if (pending.Acknowledged) pending = null; }
        else { pending = null; if (!IsEditing) Value = remote; }
        return true;
    }
    public void Expire(ulong token)
    {
        if (pending?.Token != token || !pending.Completed) return;
        pending = null;
        if (!IsEditing) Value = remote;
    }
}
