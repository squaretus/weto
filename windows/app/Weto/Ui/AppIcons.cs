// Значки приложений для плашек целей — аналог Icon= ярлыка .desktop на Linux.
//
// Значок есть только у цели, добавленной ярлыком из меню «Пуск» (.lnk): по одной
// команде или пути, как и на Linux, приложение от инструмента не отличить.
// Картинку отдаёт оболочка (StorageFile.GetThumbnailAsync) — тот же значок,
// что в меню «Пуск», без стрелки ярлыка. Кэш по записи: такт перерисовывает
// попап раз в секунду, а файл ярлыка за это время не меняется.
using System;
using System.Collections.Generic;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage;
using Windows.Storage.FileProperties;

namespace Weto.Ui;

public static class AppIcons
{
    private const uint Size = 32;

    /// <summary>Загруженные значки; null — у ярлыка значка нет, спрашивать снова незачем.</summary>
    private static readonly Dictionary<string, BitmapImage?> Cache = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Отдать значок записи в <paramref name="apply"/> — сразу из кэша или после загрузки.</summary>
    public static void Load(string entry, Action<Image> apply)
    {
        if (Cache.TryGetValue(entry, out var cached))
        {
            if (cached is not null)
            {
                apply(Picture(cached));
            }
            return;
        }
        _ = LoadAsync(entry, apply);
    }

    private static async System.Threading.Tasks.Task LoadAsync(string entry, Action<Image> apply)
    {
        BitmapImage? bitmap = null;
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(entry);
            using var thumbnail = await file.GetThumbnailAsync(ThumbnailMode.SingleItem, Size, ThumbnailOptions.UseCurrentScale);
            if (thumbnail is not null)
            {
                bitmap = new BitmapImage();
                await bitmap.SetSourceAsync(thumbnail);
            }
        }
        catch (Exception)
        {
            // Ярлыка нет или оболочка не отдала значок — остаётся значок терминала.
            bitmap = null;
        }
        Cache[entry] = bitmap;
        if (bitmap is not null)
        {
            apply(Picture(bitmap));
        }
    }

    private static Image Picture(BitmapImage bitmap) => new()
    {
        Source = bitmap,
        Width = 24,
        Height = 24,
    };
}
