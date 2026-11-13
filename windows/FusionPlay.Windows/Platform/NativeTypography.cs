using System.Runtime.InteropServices;
using Microsoft.Graphics.Canvas;

namespace FusionPlay.Windows.Platform;

internal sealed record InstalledFontFamily(string Name, string ChineseName, int[] Weights)
{
    public string Label => L.Language == "en" ? Name : ChineseName;
}

/// <summary>DirectWrite font-family enumeration and scoped Direct2D rendering parameters.
/// The ABI slots below follow the Windows SDK dwrite.h/dwrite_2.h/d2d1.h and
/// Win2D's Microsoft.Graphics.Canvas.native.h, not the WinRT IInspectable ABI.</summary>
internal static unsafe class NativeTypography
{
    internal sealed record RenderingParameters(int Antialiasing, float Gamma, float Contrast, int Mode)
    {
        public bool ExternalOverride => Antialiasing != 2 || Math.Abs(Gamma - 1.8f) > 0.001f || Math.Abs(Contrast - 0.35f) > 0.001f || Mode != 5;
    }
    private static readonly Lazy<nint> Factory = new(() =>
    {
        Guid iid = new("0439fc60-ca44-4994-8dee-3a9af7b732ec"); // IDWriteFactory2
        Marshal.ThrowExceptionForHR(DWriteCreateFactory(0, in iid, out nint factory));
        return factory; // Shared, thread-safe factory lives for the application lifetime.
    });
    private static readonly Lazy<nint> Parameters = new(() =>
    {
        nint factory = Factory.Value, parameters = 0;
        var create = (delegate* unmanaged[Stdcall]<nint, float, float, float, float, int, int, int, nint*, int>)Vtable(factory)[29];
        // Grayscale is intentional: these glyphs are composited over transparent
        // artwork/acrylic. RGB ClearType coverage cannot be stored in one alpha.
        Marshal.ThrowExceptionForHR(create(factory, 1.8f, 0, 0.35f, 0, 0, 5, 2, &parameters));
        return parameters;
    });
    private static nint* Vtable(nint instance) => *(nint**)instance;
    private static void Release(nint instance) { if (instance != 0) Marshal.Release(instance); }
    private static nint Collection(bool update = false)
    {
        nint factory = Factory.Value, collection = 0;
        Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint*, int, int>)Vtable(factory)[3])(factory, &collection, update ? 1 : 0));
        return collection;
    }
    public static InstalledFontFamily[] GetFamilies()
    {
        nint collection = Collection(update: true);
        try
        {
            uint count = ((delegate* unmanaged[Stdcall]<nint, uint>)Vtable(collection)[3])(collection);
            var families = new List<InstalledFontFamily>();
            for (uint index = 0; index < count; index++) families.Add(ReadFamily(collection, index));
            return families.Where(f => f.Name.Length > 0 && !f.Name.StartsWith('@'))
                .DistinctBy(f => f.Name, StringComparer.OrdinalIgnoreCase).OrderBy(f => f.Name, StringComparer.OrdinalIgnoreCase).ToArray();
        }
        finally { Release(collection); }
    }
    public static InstalledFontFamily? FindFamily(string name)
    {
        nint collection = Collection();
        try
        {
            uint index = 0; int exists = 0;
            fixed (char* text = name)
                Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, char*, uint*, int*, int>)Vtable(collection)[5])(collection, text, &index, &exists));
            return exists != 0 ? ReadFamily(collection, index) : null;
        }
        finally { Release(collection); }
    }
    public static InstalledFontFamily SystemFamily => FindFamily("Segoe UI Variable Text")
        ?? FindFamily("Segoe UI Variable") ?? FindFamily("Segoe UI")
        ?? new("Segoe UI", "Segoe UI", [400, 600, 700]);
    private static InstalledFontFamily ReadFamily(nint collection, uint index)
    {
        nint family = 0, names = 0;
        try
        {
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)Vtable(collection)[4])(collection, index, &family));
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint*, int>)Vtable(family)[6])(family, &names));
            string canonical = LocalizedName(names, "en-us"), chinese = LocalizedName(names, "zh-cn");
            uint count = ((delegate* unmanaged[Stdcall]<nint, uint>)Vtable(family)[4])(family);
            var regular = new SortedSet<int>(); var all = new SortedSet<int>();
            for (uint i = 0; i < count; i++)
            {
                nint font = 0;
                try
                {
                    Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, nint*, int>)Vtable(family)[5])(family, i, &font));
                    int weight = ((delegate* unmanaged[Stdcall]<nint, int>)Vtable(font)[4])(font);
                    int style = ((delegate* unmanaged[Stdcall]<nint, int>)Vtable(font)[6])(font);
                    if (weight is >= 1 and <= 999) { all.Add(weight); if (style == 0) regular.Add(weight); }
                }
                finally { Release(font); }
            }
            int[] weights = (regular.Count > 0 ? regular : all).ToArray();
            return new(canonical, chinese, weights.Length > 0 ? weights : [400]);
        }
        finally { Release(names); Release(family); }
    }
    private static string LocalizedName(nint names, string locale)
    {
        uint index = 0, length = 0; int exists = 0;
        fixed (char* text = locale)
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, char*, uint*, int*, int>)Vtable(names)[4])(names, text, &index, &exists));
        if (exists == 0 && locale != "en-us") return LocalizedName(names, "en-us");
        if (exists == 0) index = 0;
        Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, uint*, int>)Vtable(names)[7])(names, index, &length));
        char[] buffer = new char[length + 1];
        fixed (char* text = buffer)
            Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, uint, char*, uint, int>)Vtable(names)[8])(names, index, text, length + 1));
        return new string(buffer, 0, (int)length);
    }
    public static RenderingScope Enhance(CanvasDrawingSession session) => new(session);
    internal sealed class RenderingScope : IDisposable
    {
        private nint context, previousParameters;
        private readonly int previousAntialiasing;
        internal RenderingParameters Inspect()
        {
            nint parameters = 0;
            ((delegate* unmanaged[Stdcall]<nint, nint*, void>)Vtable(context)[37])(context, &parameters);
            try
            {
                return new(((delegate* unmanaged[Stdcall]<nint, int>)Vtable(context)[35])(context),
                    ((delegate* unmanaged[Stdcall]<nint, float>)Vtable(parameters)[3])(parameters),
                    ((delegate* unmanaged[Stdcall]<nint, float>)Vtable(parameters)[8])(parameters),
                    ((delegate* unmanaged[Stdcall]<nint, int>)Vtable(parameters)[7])(parameters));
            }
            finally { Release(parameters); }
        }
        public RenderingScope(CanvasDrawingSession session)
        {
            nint inspectable = WinRT.MarshalInspectable<object>.FromManaged(session), wrapper = 0;
            try
            {
                Guid wrapperId = new("5F10688D-EA55-4D55-A3B0-4DDB55C0C20A");
                Guid contextId = new("d37f57e4-6908-459f-a199-e72f24f79987"); // ID2D1DeviceContext1
                Marshal.ThrowExceptionForHR(Marshal.QueryInterface(inspectable, in wrapperId, out wrapper));
                nint native = 0;
                Marshal.ThrowExceptionForHR(((delegate* unmanaged[Stdcall]<nint, nint, float, Guid*, nint*, int>)Vtable(wrapper)[3])(wrapper, 0, 0, &contextId, &native));
                context = native;
                previousAntialiasing = ((delegate* unmanaged[Stdcall]<nint, int>)Vtable(context)[35])(context);
                nint previous = 0;
                ((delegate* unmanaged[Stdcall]<nint, nint*, void>)Vtable(context)[37])(context, &previous);
                previousParameters = previous;
                nint parameters = Parameters.Value;
                ((delegate* unmanaged[Stdcall]<nint, int, void>)Vtable(context)[34])(context, 2); // Grayscale
                ((delegate* unmanaged[Stdcall]<nint, nint, void>)Vtable(context)[36])(context, parameters);
            }
            catch { Dispose(); throw; }
            finally { Release(wrapper); Release(inspectable); }
        }
        public void Dispose()
        {
            if (context == 0) return;
            ((delegate* unmanaged[Stdcall]<nint, nint, void>)Vtable(context)[36])(context, previousParameters);
            ((delegate* unmanaged[Stdcall]<nint, int, void>)Vtable(context)[34])(context, previousAntialiasing);
            Release(previousParameters); Release(context); context = previousParameters = 0;
        }
    }
    [DllImport("dwrite.dll", ExactSpelling = true)]
    private static extern int DWriteCreateFactory(int type, in Guid iid, out nint factory);
}
