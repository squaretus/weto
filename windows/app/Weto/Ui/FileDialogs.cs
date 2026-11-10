// Системные диалоги выбора и сохранения файла (Common Item Dialog) через COM.
//
// Не FileOpenPicker из Windows App SDK: тот разыменовывает ярлыки и вместо
// выбранного .lnk отдаёт путь к программе. Цель же хранится ярлыком, как
// .desktop на Linux: по нему ядро отличает приложение от команды, плашка берёт
// значок, а версионный путь программы, сменившийся с обновлением, ярлык
// переживает. Для этого нужен флаг FOS_NODEREFERENCELINKS, а он есть только
// у самого IFileOpenDialog.
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Weto.Ui;

public static class FileDialogs
{
    /// <summary>
    /// Выбрать файлы (несколько) в каталоге <paramref name="folder"/>. Пустой
    /// список — отмена.
    /// </summary>
    public static IReadOnlyList<string> Open(nint owner, string title, string folder, IReadOnlyList<(string Name, string Spec)> filters)
    {
        var dialog = (IFileOpenDialog)new FileOpenDialogClass();
        try
        {
            dialog.GetOptions(out var options);
            dialog.SetOptions(options | FOS_NODEREFERENCELINKS | FOS_ALLOWMULTISELECT | FOS_FORCEFILESYSTEM
                | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST);
            dialog.SetTitle(title);
            var specs = new COMDLG_FILTERSPEC[filters.Count];
            for (var i = 0; i < filters.Count; i++)
            {
                specs[i] = new COMDLG_FILTERSPEC { pszName = filters[i].Name, pszSpec = filters[i].Spec };
            }
            dialog.SetFileTypes((uint)specs.Length, specs);
            if (Folder(folder) is { } start)
            {
                dialog.SetFolder(start);
            }
            if (dialog.Show(owner) != 0)
            {
                return [];
            }
            dialog.GetResults(out var items);
            items.GetCount(out var count);
            var paths = new List<string>();
            for (uint i = 0; i < count; i++)
            {
                items.GetItemAt(i, out var item);
                if (PathOf(item) is { } path)
                {
                    paths.Add(path);
                }
            }
            return paths;
        }
        finally
        {
            Marshal.FinalReleaseComObject(dialog);
        }
    }

    /// <summary>Спросить, куда сохранить файл; null — отмена.</summary>
    public static string? Save(nint owner, string title, string fileName, (string Name, string Spec) filter, string extension)
    {
        var dialog = (IFileSaveDialog)new FileSaveDialogClass();
        try
        {
            dialog.GetOptions(out var options);
            dialog.SetOptions(options | FOS_FORCEFILESYSTEM | FOS_OVERWRITEPROMPT | FOS_PATHMUSTEXIST);
            dialog.SetTitle(title);
            dialog.SetFileTypes(1, [new COMDLG_FILTERSPEC { pszName = filter.Name, pszSpec = filter.Spec }]);
            dialog.SetDefaultExtension(extension);
            dialog.SetFileName(fileName);
            if (dialog.Show(owner) != 0)
            {
                return null;
            }
            dialog.GetResult(out var item);
            return PathOf(item);
        }
        finally
        {
            Marshal.FinalReleaseComObject(dialog);
        }
    }

    private static IShellItem? Folder(string path)
    {
        var iid = typeof(IShellItem).GUID;
        return SHCreateItemFromParsingName(path, 0, ref iid, out var item) == 0 ? item : null;
    }

    private static string? PathOf(IShellItem item)
    {
        if (item.GetDisplayName(SIGDN_FILESYSPATH, out var name) != 0 || name == 0)
        {
            return null;
        }
        try
        {
            return Marshal.PtrToStringUni(name);
        }
        finally
        {
            Marshal.FreeCoTaskMem(name);
        }
    }

    private const uint FOS_OVERWRITEPROMPT = 0x2;
    private const uint FOS_FORCEFILESYSTEM = 0x40;
    private const uint FOS_ALLOWMULTISELECT = 0x200;
    private const uint FOS_PATHMUSTEXIST = 0x800;
    private const uint FOS_FILEMUSTEXIST = 0x1000;
    private const uint FOS_NODEREFERENCELINKS = 0x100000;
    private const uint SIGDN_FILESYSPATH = 0x80058000;

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
    private static extern int SHCreateItemFromParsingName(string path, nint bindContext, ref Guid iid, out IShellItem item);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct COMDLG_FILTERSPEC
    {
        [MarshalAs(UnmanagedType.LPWStr)] public string pszName;
        [MarshalAs(UnmanagedType.LPWStr)] public string pszSpec;
    }

    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    private class FileOpenDialogClass;

    [ComImport, Guid("C0B4E2F3-BA21-4773-8DBA-335EC946EB8B")]
    private class FileSaveDialogClass;

    // Порядок методов — порядок vtable: IModalWindow (Show) → IFileDialog →
    // наследник. Методы базовых интерфейсов повторены: COM-интерфейс .NET
    // наследования vtable не знает.
    [ComImport, Guid("d57c7288-d4ad-4768-be02-9d969532d960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileOpenDialog
    {
        [PreserveSig] int Show(nint owner);
        void SetFileTypes(uint count, [MarshalAs(UnmanagedType.LPArray)] COMDLG_FILTERSPEC[] filters);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(nint events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void GetResult(out IShellItem item);
        void AddPlace(IShellItem item, int place);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
        void Close(int result);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(nint filter);
        void GetResults(out IShellItemArray items);
        void GetSelectedItems(out IShellItemArray items);
    }

    [ComImport, Guid("84bccd23-5fde-4cdb-aea4-af64b83d78ab"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IFileSaveDialog
    {
        [PreserveSig] int Show(nint owner);
        void SetFileTypes(uint count, [MarshalAs(UnmanagedType.LPArray)] COMDLG_FILTERSPEC[] filters);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(nint events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem item);
        void SetFolder(IShellItem item);
        void GetFolder(out IShellItem item);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string text);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void GetResult(out IShellItem item);
        void AddPlace(IShellItem item, int place);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
        void Close(int result);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(nint filter);
        void SetSaveAsItem(IShellItem item);
        void SetProperties(nint store);
        void SetCollectedProperties(nint list, int appendDefault);
        void GetProperties(out nint store);
        void ApplyProperties(IShellItem item, nint store, nint owner, nint sink);
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItem
    {
        void BindToHandler(nint context, ref Guid handler, ref Guid iid, out nint result);
        void GetParent(out IShellItem parent);
        [PreserveSig] int GetDisplayName(uint kind, out nint name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }

    [ComImport, Guid("b63ea76d-1f85-456f-a19c-48159efa858b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemArray
    {
        void BindToHandler(nint context, ref Guid handler, ref Guid iid, out nint result);
        void GetPropertyStore(int flags, ref Guid iid, out nint store);
        void GetPropertyDescriptionList(nint key, ref Guid iid, out nint list);
        void GetAttributes(int flags, uint mask, out uint attributes);
        void GetCount(out uint count);
        void GetItemAt(uint index, out IShellItem item);
        void EnumItems(out nint items);
    }
}
