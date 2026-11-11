// Значки приложений для плашек целей — аналог Icon= ярлыка .desktop на Linux.
//
// Значок есть только у цели, добавленной ярлыком из меню «Пуск» (.lnk): по одной
// команде или пути, как и на Linux, приложение от инструмента не отличить.
// Файл и индекс значка называет мост (shortcut::icon): IconLocation ярлыка, а без
// него — программа ярлыка. Сам .lnk не годится: оболочка накладывает на его
// значок стрелку. Значок достаёт ExtractIconExW, синхронно: StorageFile.
// GetThumbnailAsync на раннере молча не отдавал ничего. Кэш по файлу и индексу:
// попап перерисовывается раз в секунду, а значок за это время не меняется.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Weto.Bridge;

namespace Weto.Ui;

public static class AppIcons
{
    /// <summary>Готовые картинки; null — у ярлыка значка нет, спрашивать снова незачем.</summary>
    private static readonly Dictionary<string, (int Size, byte[] Pixels)?> Cache = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Значок в <paramref name="apply"/>; нет значка — <paramref name="apply"/> не зовётся.</summary>
    public static void Load(IconRef source, Action<Image> apply)
    {
        var key = $"{source.Path}|{source.Index}";
        if (!Cache.TryGetValue(key, out var pixels))
        {
            pixels = Read(source);
            Cache[key] = pixels;
        }
        if (pixels is not { } icon)
        {
            return;
        }
        var bitmap = new WriteableBitmap(icon.Size, icon.Size);
        using (var stream = System.Runtime.InteropServices.WindowsRuntime.WindowsRuntimeBufferExtensions.AsStream(bitmap.PixelBuffer))
        {
            stream.Write(icon.Pixels, 0, icon.Pixels.Length);
        }
        bitmap.Invalidate();
        apply(new Image { Source = bitmap, Width = 24, Height = 24 });
    }

    /// <summary>Пиксели BGRA (с предумножением альфы, как ждёт WriteableBitmap).</summary>
    private static (int Size, byte[] Pixels)? Read(IconRef source)
    {
        nint icon = 0;
        if (ExtractIconExW(source.Path, source.Index, out var large, 0, 1) > 0)
        {
            icon = large;
        }
        if (icon == 0)
        {
            // Значка с этим индексом нет — значок файла от оболочки.
            var info = new SHFILEINFOW();
            if (SHGetFileInfoW(source.Path, 0, ref info, (uint)Marshal.SizeOf<SHFILEINFOW>(), SHGFI_ICON | SHGFI_LARGEICON) != 0)
            {
                icon = info.hIcon;
            }
        }
        if (icon == 0)
        {
            return null;
        }
        try
        {
            if (!GetIconInfo(icon, out var iconInfo))
            {
                return null;
            }
            try
            {
                return Pixels(iconInfo.hbmColor);
            }
            finally
            {
                DeleteObject(iconInfo.hbmColor);
                DeleteObject(iconInfo.hbmMask);
            }
        }
        finally
        {
            DestroyIcon(icon);
        }
    }

    private static (int Size, byte[] Pixels)? Pixels(nint colorBitmap)
    {
        if (colorBitmap == 0 || GetObjectW(colorBitmap, Marshal.SizeOf<BITMAP>(), out var bitmap) == 0)
        {
            return null;
        }
        var size = bitmap.bmWidth;
        var header = new BITMAPINFOHEADER
        {
            biSize = (uint)Marshal.SizeOf<BITMAPINFOHEADER>(),
            biWidth = size,
            biHeight = -size, // сверху вниз
            biPlanes = 1,
            biBitCount = 32,
        };
        var pixels = new byte[size * size * 4];
        var screen = GetDC(0);
        try
        {
            if (GetDIBits(screen, colorBitmap, 0, (uint)size, pixels, ref header, 0) == 0)
            {
                return null;
            }
        }
        finally
        {
            ReleaseDC(0, screen);
        }
        for (var i = 0; i < pixels.Length; i += 4)
        {
            var alpha = pixels[i + 3];
            pixels[i] = (byte)(pixels[i] * alpha / 255);
            pixels[i + 1] = (byte)(pixels[i + 1] * alpha / 255);
            pixels[i + 2] = (byte)(pixels[i + 2] * alpha / 255);
        }
        return (size, pixels);
    }

    private const uint SHGFI_ICON = 0x100;
    private const uint SHGFI_LARGEICON = 0x0;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct SHFILEINFOW
    {
        public nint hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO
    {
        public int fIcon;
        public int xHotspot;
        public int yHotspot;
        public nint hbmMask;
        public nint hbmColor;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAP
    {
        public int bmType;
        public int bmWidth;
        public int bmHeight;
        public int bmWidthBytes;
        public ushort bmPlanes;
        public ushort bmBitsPixel;
        public nint bmBits;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public uint biSize;
        public int biWidth;
        public int biHeight;
        public ushort biPlanes;
        public ushort biBitCount;
        public uint biCompression;
        public uint biSizeImage;
        public int biXPelsPerMeter;
        public int biYPelsPerMeter;
        public uint biClrUsed;
        public uint biClrImportant;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern nint SHGetFileInfoW(string path, uint attributes, ref SHFILEINFOW info, uint size, uint flags);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern uint ExtractIconExW(string file, int index, out nint large, nint small, uint count);

    [DllImport("user32.dll")]
    private static extern bool GetIconInfo(nint icon, out ICONINFO info);

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(nint icon);

    [DllImport("user32.dll")]
    private static extern nint GetDC(nint window);

    [DllImport("user32.dll")]
    private static extern int ReleaseDC(nint window, nint dc);

    [DllImport("gdi32.dll")]
    private static extern int GetObjectW(nint handle, int size, out BITMAP bitmap);

    [DllImport("gdi32.dll")]
    private static extern int GetDIBits(nint dc, nint bitmap, uint start, uint lines, byte[] bits, ref BITMAPINFOHEADER info, uint usage);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(nint handle);
}
