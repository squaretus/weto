// Привязки к weto_ffi.dll — мосту на Rust, где живёт всё состояние приложения.
//
// Контракт — windows/crates/weto-ffi/src/abi.rs: строки UTF-8 с нулём на конце,
// строки моста освобождает только weto_free_string, ответы — JSON.
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Weto.Bridge;

internal static unsafe partial class Native
{
    private const string Library = "weto_ffi";

    [StructLayout(LayoutKind.Sequential)]
    internal struct Callbacks
    {
        public nint Context;
        public delegate* unmanaged[Cdecl]<nint, byte*, void> Notify;
    }

    [LibraryImport(Library)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    internal static partial nint weto_start(Callbacks callbacks);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    internal static partial nint weto_view(nint weto, string kind);

    [LibraryImport(Library, StringMarshalling = StringMarshalling.Utf8)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    internal static partial nint weto_command(nint weto, string json);

    [LibraryImport(Library)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    internal static partial void weto_free_string(nint text);

    [LibraryImport(Library)]
    [UnmanagedCallConv(CallConvs = new[] { typeof(CallConvCdecl) })]
    internal static partial void weto_stop(nint weto);

    /// <summary>Забрать строку моста и освободить её. Нулевой указатель — null.</summary>
    internal static string? Take(nint text)
    {
        if (text == 0)
        {
            return null;
        }
        try
        {
            return Marshal.PtrToStringUTF8(text);
        }
        finally
        {
            weto_free_string(text);
        }
    }
}
