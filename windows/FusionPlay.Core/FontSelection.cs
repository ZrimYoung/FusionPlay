namespace FusionPlay.Core;

public static class FontSelection
{
    // Keep a portable preference even if that face is absent on another PC.
    // Resolve to an installed weight only when presenting/drawing it.
    public static int NearestWeight(IEnumerable<int> available, int requested) => available
        .Where(weight => weight is >= 1 and <= 999).Distinct()
        .OrderBy(weight => Math.Abs(weight - requested)).ThenBy(weight => weight)
        .FirstOrDefault(400);

    public static int HeadingWeight(IEnumerable<int> available, int bodyWeight) =>
        NearestWeight(available, Math.Min(900, bodyWeight + 200));
}
